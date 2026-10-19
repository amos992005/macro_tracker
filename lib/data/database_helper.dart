import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'models/food.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'macro_tracker.db');
    return await openDatabase(
      path,
      version: 5, // <-- העלנו ל-5 כדי להפעיל את ה-_onUpgrade
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  // פונקציה שרצה כשיש עדכון גרסה (כדי לא לאבד נתונים)
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE foods ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 5) {
      // הוספת האינדקס למסד קיים
      await db.execute('CREATE INDEX IF NOT EXISTS idx_food_name ON foods(name)');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
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

    // הוספת האינדקס למסד חדש
    await db.execute('CREATE INDEX IF NOT EXISTS idx_food_name ON foods(name)');

    // טעינת קובץ המאכלים (אם קיים)
    try {
      String jsonString = await rootBundle.loadString('assets/foods_full_all.json'); // שים לב לשם הקובץ!
      List<dynamic> jsonList = jsonDecode(jsonString);

      Batch batch = db.batch();
      for (var json in jsonList) {
        batch.insert('foods', {
          'name': json['name'],
          'calories_per_100g': (json['calories_per_100g'] as num).toDouble(),
          'protein_per_100g': (json['protein_per_100g'] as num).toDouble(),
          'carbs_per_100g': (json['carbs_per_100g'] as num).toDouble(),
          'fat_per_100g': (json['fat_per_100g'] as num).toDouble(),
          'is_liquid': json['is_liquid'] ?? 0,
          'is_recipe': json['is_recipe'] ?? 0,
          'servings': (json['servings'] as num?)?.toDouble() ?? 1.0,
          'is_favorite': 0,
        });
      }
      await batch.commit(noResult: true);
    } catch (e) {
      print('שגיאה בטעינת קובץ המאכלים: $e');
    }
  }

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

  Future<Map<String, dynamic>?> getTargetsForDate(String date) async {
    final db = await database;
    final maps = await db.query('daily_targets', where: 'date = ?', whereArgs: [date]);
    if (maps.isNotEmpty) return maps.first;
    return null;
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