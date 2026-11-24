import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'models/food.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  // === V1.3: העלינו מ-5 ל-6 כדי להפעיל מיגרציה של ה-seed החדש ===
  static const int _dbVersion = 6;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'macro_tracker.db');
    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE foods ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 5) {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_food_name ON foods(name)');
    }
    if (oldVersion < 6) {
      // V1.3: מיגרציה — מוסיפים רק מוצרים חדשים לפי שם.
      // מוצרים קיימים (כולל מועדפים ומתכונים אישיים) לא נגעים בהם.
      debugPrint('🔄 DatabaseHelper: Migration 5→6 — importing new seed foods (skip existing)...');
      await _importSeedFoods(db, skipExisting: true);
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    // ==================== יצירת טבלאות ====================
    await db.execute('''
      CREATE TABLE foods(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        calories_per_100g REAL NOT NULL,
        protein_per_100g REAL NOT NULL,
        carbs_per_100g REAL NOT NULL,
        fat_per_100g REAL NOT NULL,
        is_liquid INTEGER NOT NULL DEFAULT 0,
        is_recipe INTEGER NOT NULL DEFAULT 0,
        servings REAL NOT NULL DEFAULT 1.0,
        is_favorite INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE meal_entries(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        food_id INTEGER NOT NULL,
        weight_grams REAL NOT NULL,
        meal_date TEXT NOT NULL,
        FOREIGN KEY (food_id) REFERENCES foods (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE daily_targets(
        date TEXT PRIMARY KEY,
        calories REAL NOT NULL,
        protein REAL NOT NULL,
        carbs REAL NOT NULL,
        fat REAL NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE app_settings(
        id INTEGER PRIMARY KEY CHECK (id = 1),
        cal_mode TEXT NOT NULL DEFAULT 'down', 
        cal_pct REAL NOT NULL DEFAULT 10.0,
        pro_mode TEXT NOT NULL DEFAULT 'up', 
        pro_pct REAL NOT NULL DEFAULT 10.0,
        carb_mode TEXT NOT NULL DEFAULT 'both', 
        carb_pct REAL NOT NULL DEFAULT 10.0,
        fat_mode TEXT NOT NULL DEFAULT 'free', 
        fat_pct REAL NOT NULL DEFAULT 0.0
      )
    ''');

    await db.insert('app_settings', {'id': 1});
    await db.execute('CREATE INDEX IF NOT EXISTS idx_food_name ON foods(name)');

    // ==================== ייבוא ה-seed הראשוני ====================
    // V1.2: ID מוקצה אוטומטית, is_favorite תמיד 0, התחלה נקייה.
    debugPrint('🌱 DatabaseHelper: Fresh install — loading full seed...');
    await _importSeedFoods(db, skipExisting: false);
  }

  // ==================== לוגיקת ייבוא ה-seed (משותפת ל-onCreate ול-onUpgrade) ====================
  Future<void> _importSeedFoods(dynamic db, {required bool skipExisting}) async {
    final stopwatch = Stopwatch()..start();
    try {
      final String jsonString = await rootBundle.loadString('assets/foods_full_all.json');
      final List<dynamic> jsonList = jsonDecode(jsonString);

      // אם במצב מיגרציה — שולפים את כל השמות הקיימים מה-DB כדי לדלג עליהם.
      final Set<String> existingNames = {};
      if (skipExisting) {
        final rows = await db.query('foods', columns: ['name']);
        for (final row in rows) {
          existingNames.add((row['name'] as String).trim());
        }
      }

      final batch = db.batch();
      int loaded = 0;
      int skippedInvalid = 0;
      int skippedExisting = 0;

      // מגן כפילויות פנימיות בקובץ ה-JSON (שמות זהים בתוך ה-asset).
      final Set<String> batchNames = {};

      for (final json in jsonList) {
        // הגנה 1: רשומה חייבת להיות Map
        if (json is! Map<String, dynamic>) {
          skippedInvalid++;
          continue;
        }

        // הגנה 2: שם חייב להיות קיים ולא ריק
        final String name = (json['name'] as String?)?.trim() ?? '';
        if (name.isEmpty) {
          skippedInvalid++;
          continue;
        }

        // הגנה 3: במצב מיגרציה — דלג אם השם כבר קיים ב-DB
        if (skipExisting && existingNames.contains(name)) {
          skippedExisting++;
          continue;
        }

        // הגנה 4: כפילות פנימית בקובץ
        if (batchNames.contains(name)) {
          skippedExisting++;
          continue;
        }
        batchNames.add(name);

        // הגנה 5: ארבעת הערכים התזונתיים חייבים להיות מספרים
        final double? cal = (json['calories_per_100g'] as num?)?.toDouble();
        final double? pro = (json['protein_per_100g'] as num?)?.toDouble();
        final double? carb = (json['carbs_per_100g'] as num?)?.toDouble();
        final double? fat = (json['fat_per_100g'] as num?)?.toDouble();

        if (cal == null || pro == null || carb == null || fat == null) {
          skippedInvalid++;
          continue;
        }

        batch.insert('foods', {
          'name': name,
          'calories_per_100g': cal,
          'protein_per_100g': pro,
          'carbs_per_100g': carb,
          'fat_per_100g': fat,
          'is_liquid': (json['is_liquid'] as num?)?.toInt() ?? 0,
          'is_recipe': (json['is_recipe'] as num?)?.toInt() ?? 0,
          'servings': (json['servings'] as num?)?.toDouble() ?? 1.0,
          'is_favorite': 0,
        });
        loaded++;
      }

      await batch.commit(noResult: true);
      stopwatch.stop();

      debugPrint(
        '✅ Seed import done in ${stopwatch.elapsedMilliseconds}ms — '
            'loaded=$loaded, skippedInvalid=$skippedInvalid, skippedExisting=$skippedExisting',
      );
    } catch (e, st) {
      stopwatch.stop();
      debugPrint('❌ Seed import failed after ${stopwatch.elapsedMilliseconds}ms: $e');
      debugPrint('$st');
    }
  }

  // ==================== שאר הפונקציות — ללא שינוי ====================

  Future<void> insertFoodsBatch(List<Food> foods) async {
    final db = await database;
    Batch batch = db.batch();
    for (var food in foods) {
      batch.insert('foods', food.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<int> insertFood(Food food) async {
    final db = await database;
    return await db.insert('foods', food.toMap());
  }

  Future<int> updateFood(Food food) async {
    final db = await database;
    return await db.update('foods', food.toMap(), where: 'id = ?', whereArgs: [food.id]);
  }

  Future<List<Food>> getAllFoods() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('foods');
    return List.generate(maps.length, (i) => Food.fromMap(maps[i]));
  }

  Future<void> toggleFavorite(int id, bool isFavorite) async {
    final db = await database;
    await db.update('foods', {'is_favorite': isFavorite ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> insertMealEntry(int foodId, double weightGrams, String date) async {
    final db = await database;
    return await db.insert('meal_entries', {'food_id': foodId, 'weight_grams': weightGrams, 'meal_date': date});
  }

  Future<void> deleteMealEntry(int entryId) async {
    final db = await database;
    await db.delete('meal_entries', where: 'id = ?', whereArgs: [entryId]);
  }

  Future<List<Map<String, dynamic>>> getMealsForDate(String date) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT m.id as entry_id, m.weight_grams, m.meal_date, 
             f.name as food_name, f.calories_per_100g, f.protein_per_100g, f.carbs_per_100g, f.fat_per_100g, f.is_liquid, f.is_recipe, f.servings
      FROM meal_entries m
      JOIN foods f ON m.food_id = f.id
      WHERE m.meal_date = ?
    ''', [date]);
  }

  static const String _defaultTargetsDate = 'default';
  static const double _initialCaloriesTarget = 2000;
  static const double _initialProteinTarget = 150;
  static const double _initialCarbsTarget = 200;
  static const double _initialFatTarget = 60;

  Future<Map<String, dynamic>?> getTargetsForDate(String date) async {
    final db = await database;
    final maps = await db.query('daily_targets', where: 'date = ?', whereArgs: [date]);
    if (maps.isNotEmpty) return maps.first;
    return null;
  }

  /// Returns the user's persistent daily defaults, creating the initial row
  /// on first use. The existing daily_targets table stores this at date='default'.
  Future<Map<String, dynamic>> getDefaultTargets() async {
    final savedTargets = await getTargetsForDate(_defaultTargetsDate);
    if (savedTargets != null) return savedTargets;

    await saveTargetsForDate(
      _defaultTargetsDate,
      _initialCaloriesTarget,
      _initialProteinTarget,
      _initialCarbsTarget,
      _initialFatTarget,
    );
    return (await getTargetsForDate(_defaultTargetsDate))!;
  }

  Future<void> saveDefaultTargets(
    double calories,
    double protein,
    double carbs,
    double fat,
  ) async {
    await saveTargetsForDate(
      _defaultTargetsDate,
      calories,
      protein,
      carbs,
      fat,
    );
  }

  Future<void> saveTargetsForDate(String date, double cal, double pro, double carb, double fat) async {
    final db = await database;
    await db.insert('daily_targets', {'date': date, 'calories': cal, 'protein': pro, 'carbs': carb, 'fat': fat}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteFood(int id) async {
    final db = await database;
    await db.delete('meal_entries', where: 'food_id = ?', whereArgs: [id]);
    await db.delete('foods', where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, dynamic>> getSettings() async {
    final db = await database;
    final maps = await db.query('app_settings', where: 'id = 1');
    if (maps.isEmpty) {
      await db.insert('app_settings', {'id': 1});
      final newMaps = await db.query('app_settings', where: 'id = 1');
      return newMaps.first;
    }
    return maps.first;
  }

  Future<void> saveSettings(Map<String, dynamic> settings) async {
    final db = await database;
    await db.update('app_settings', settings, where: 'id = 1');
  }
}