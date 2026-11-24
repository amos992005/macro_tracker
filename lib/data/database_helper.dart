import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart';

import 'macro_sync_service.dart';
import 'models/food.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;
  static String? _profileId;
  static const int _dbVersion = 8;

  /// Each authenticated profile gets a separate local cache/database.
  Future<void> deactivateProfile() async {
    if (_database?.isOpen ?? false) await _database!.close();
    _database = null;
    _profileId = null;
  }

  Future<void> activateProfile(String profileId) async {
    final safeId = profileId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    if (_profileId == safeId && _database != null) return;
    if (_database?.isOpen ?? false) await _database!.close();
    _database = null;
    _profileId = safeId;
    await database;
    await _importLegacyDataForFirstProfile(safeId);
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final databaseName = _profileId == null ? 'macro_tracker.db' : 'macro_tracker_$_profileId.db';
    final path = join(await getDatabasesPath(), databaseName);
    return openDatabase(path, version: _dbVersion, onCreate: _onCreate, onUpgrade: _onUpgrade);
  }

  /// Preserve existing SQLite data on the first profile login. The legacy
  /// database is retained; only its records are copied into the owner's cache.
  Future<void> _importLegacyDataForFirstProfile(String profileId) async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('macro.legacy.imported_by') != null) return;
    final legacyPath = join(await getDatabasesPath(), 'macro_tracker.db');
    if (!await databaseFactory.databaseExists(legacyPath)) return;

    Database? legacy;
    try {
      legacy = await openDatabase(legacyPath, readOnly: true, singleInstance: false);
      final tables = await legacy.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
      if (!tables.any((row) => row['name'] == 'foods')) return;
      final seedJson = jsonDecode(await rootBundle.loadString('assets/foods_full_all.json')) as List<dynamic>;
      final seedNames = seedJson.whereType<Map<String, dynamic>>().map((row) => (row['name'] as String? ?? '').trim()).toSet();
      final target = await database;
      final idMap = <int, int>{};

      for (final oldRow in await legacy.query('foods')) {
        final name = (oldRow['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        final existing = await target.query('foods', where: 'name = ?', whereArgs: [name], limit: 1);
        final isSeed = seedNames.contains(name);
        final values = <String, Object?>{
          'name': name,
          'calories_per_100g': oldRow['calories_per_100g'],
          'protein_per_100g': oldRow['protein_per_100g'],
          'carbs_per_100g': oldRow['carbs_per_100g'],
          'fat_per_100g': oldRow['fat_per_100g'],
          'is_liquid': oldRow['is_liquid'] ?? 0,
          'is_recipe': oldRow['is_recipe'] ?? 0,
          'servings': oldRow['servings'] ?? 1.0,
          'is_favorite': oldRow['is_favorite'] ?? 0,
          'is_custom': isSeed ? 0 : 1,
          'is_deleted': 0,
        };
        final newId = existing.isEmpty
            ? await target.insert('foods', values)
            : existing.first['id'] as int;
        if (!isSeed && existing.isNotEmpty) {
          await target.update('foods', values, where: 'id = ?', whereArgs: [newId]);
        } else if (existing.isNotEmpty && (oldRow['is_favorite'] as int? ?? 0) == 1) {
          await target.update('foods', {'is_favorite': 1}, where: 'id = ?', whereArgs: [newId]);
        }
        idMap[oldRow['id'] as int] = newId;
      }

      if (tables.any((row) => row['name'] == 'meal_entries')) {
        for (final meal in await legacy.query('meal_entries')) {
          final oldFoodId = meal['food_id'] as int;
          final newFoodId = idMap[oldFoodId];
          if (newFoodId == null) continue;
          final oldMealId = meal['id'];
          await target.insert('meal_entries', {
            'food_id': newFoodId,
            'weight_grams': meal['weight_grams'],
            'meal_date': meal['meal_date'],
            'client_id': 'legacy-$profileId-$oldMealId',
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      if (tables.any((row) => row['name'] == 'daily_targets')) {
        for (final row in await legacy.query('daily_targets')) {
          await target.insert('daily_targets', row, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      if (tables.any((row) => row['name'] == 'app_settings')) {
        final rows = await legacy.query('app_settings', where: 'id = 1');
        if (rows.isNotEmpty) await target.update('app_settings', rows.first, where: 'id = 1');
      }
      await prefs.setString('macro.legacy.imported_by', profileId);
    } catch (error) {
      debugPrint('Could not import previous local profile data: $error');
    } finally {
      if (legacy?.isOpen ?? false) await legacy!.close();
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 4) await db.execute('ALTER TABLE foods ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0');
    if (oldVersion < 5) await db.execute('CREATE INDEX IF NOT EXISTS idx_food_name ON foods(name)');
    if (oldVersion < 7) {
      await db.execute('ALTER TABLE foods ADD COLUMN is_custom INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE foods ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE meal_entries ADD COLUMN client_id TEXT');
      await db.execute("UPDATE meal_entries SET client_id = 'legacy-' || id WHERE client_id IS NULL");
      await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_meal_client_id ON meal_entries(client_id)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_food_custom ON foods(is_custom, is_deleted)');
      await _classifyLegacyCustomFoods(db);
    }
    if (oldVersion < 6) await _importSeedFoods(db, skipExisting: true);
    if (oldVersion < 8) await db.execute('ALTER TABLE meal_entries ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0');
  }

  Future<void> _classifyLegacyCustomFoods(DatabaseExecutor db) async {
    try {
      final source = jsonDecode(await rootBundle.loadString('assets/foods_full_all.json')) as List<dynamic>;
      final seedNames = source.whereType<Map<String, dynamic>>().map((row) => (row['name'] as String? ?? '').trim()).toSet();
      final rows = await db.query('foods', columns: ['id', 'name']);
      final batch = db.batch();
      for (final row in rows) {
        if (!seedNames.contains((row['name'] as String).trim())) {
          batch.update('foods', {'is_custom': 1}, where: 'id = ?', whereArgs: [row['id']]);
        }
      }
      await batch.commit(noResult: true);
    } catch (error) {
      debugPrint('Could not classify legacy custom foods: $error');
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
        is_favorite INTEGER NOT NULL DEFAULT 0,
        is_custom INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE meal_entries(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        food_id INTEGER NOT NULL,
        weight_grams REAL NOT NULL,
        meal_date TEXT NOT NULL,
        client_id TEXT NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
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
    await db.execute('CREATE INDEX IF NOT EXISTS idx_food_custom ON foods(is_custom, is_deleted)');
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_meal_client_id ON meal_entries(client_id)');
    debugPrint('🌱 Creating local food catalog for profile database…');
    await _importSeedFoods(db, skipExisting: false);
  }

  Future<void> _importSeedFoods(dynamic db, {required bool skipExisting}) async {
    final stopwatch = Stopwatch()..start();
    try {
      final jsonList = jsonDecode(await rootBundle.loadString('assets/foods_full_all.json')) as List<dynamic>;
      final existingNames = <String>{};
      if (skipExisting) {
        for (final row in await db.query('foods', columns: ['name'])) existingNames.add((row['name'] as String).trim());
      }
      final batch = db.batch();
      final batchNames = <String>{};
      var loaded = 0;
      for (final item in jsonList) {
        if (item is! Map<String, dynamic>) continue;
        final name = (item['name'] as String? ?? '').trim();
        if (name.isEmpty || existingNames.contains(name) || !batchNames.add(name)) continue;
        final cal = (item['calories_per_100g'] as num?)?.toDouble();
        final pro = (item['protein_per_100g'] as num?)?.toDouble();
        final carb = (item['carbs_per_100g'] as num?)?.toDouble();
        final fat = (item['fat_per_100g'] as num?)?.toDouble();
        if (cal == null || pro == null || carb == null || fat == null) continue;
        batch.insert('foods', {
          'name': name,
          'calories_per_100g': cal,
          'protein_per_100g': pro,
          'carbs_per_100g': carb,
          'fat_per_100g': fat,
          'is_liquid': (item['is_liquid'] as num?)?.toInt() ?? 0,
          'is_recipe': (item['is_recipe'] as num?)?.toInt() ?? 0,
          'servings': (item['servings'] as num?)?.toDouble() ?? 1.0,
          'is_favorite': 0,
          'is_custom': 0,
          'is_deleted': 0,
        });
        loaded++;
      }
      await batch.commit(noResult: true);
      stopwatch.stop();
      debugPrint('✅ Local seed import: $loaded foods in ${stopwatch.elapsedMilliseconds}ms.');
    } catch (error, stack) {
      stopwatch.stop();
      debugPrint('❌ Seed import failed: $error\n$stack');
    }
  }

  String _newClientId() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  Future<void> _sync(Future<void> Function() operation) async {
    if (!MacroSyncService.instance.isSignedIn) return;
    try {
      await operation();
    } catch (error) {
      debugPrint('Cloud sync deferred/failed: $error');
    }
  }

  Map<String, dynamic> _remoteFood(Food food, {bool deleted = false}) => {
        'name': food.name.trim(),
        'calories': food.caloriesPer100g,
        'protein': food.proteinPer100g,
        'carbs': food.carbsPer100g,
        'fat': food.fatPer100g,
        'is_liquid': food.isLiquid,
        'is_recipe': food.isRecipe,
        'servings': food.servings,
        'is_favorite': food.isFavorite,
        'is_deleted': deleted,
      };

  Future<void> _upsertFood(Food food, {bool deleted = false}) => _sync(() async {
        await MacroSyncService.instance.mutate(entity: 'user_foods', operation: 'upsert', row: _remoteFood(food, deleted: deleted));
      });

  Map<String, dynamic> _remoteMeal({
    required String clientId,
    required Food food,
    required double grams,
    required String date,
    bool deleted = false,
  }) => {
        'client_id': clientId,
        'food_name': food.name,
        'grams': grams,
        'date': date,
        'calories': food.caloriesPer100g,
        'protein': food.proteinPer100g,
        'carbs': food.carbsPer100g,
        'fat': food.fatPer100g,
        'is_liquid': food.isLiquid,
        'is_recipe': food.isRecipe,
        'servings': food.servings,
        'is_deleted': deleted,
      };

  Future<void> insertFoodsBatch(List<Food> foods) async {
    final db = await database;
    final batch = db.batch();
    for (final food in foods) batch.insert('foods', {...food.toMap(), 'is_custom': 1, 'is_deleted': 0});
    await batch.commit(noResult: true);
    await _uploadRows('user_foods', foods.map((food) => _remoteFood(food)).toList());
    final favorites = foods.where((food) => food.isFavorite).map((food) => <String, dynamic>{'food_name': food.name, 'is_favorite': true}).toList();
    await _uploadRows('favorites', favorites);
  }

  Future<int> insertFood(Food food) async {
    final db = await database;
    final id = await db.insert('foods', {...food.toMap(), 'is_custom': 1, 'is_deleted': 0});
    await _upsertFood(Food(id: id, name: food.name, caloriesPer100g: food.caloriesPer100g, proteinPer100g: food.proteinPer100g, carbsPer100g: food.carbsPer100g, fatPer100g: food.fatPer100g, isLiquid: food.isLiquid, isRecipe: food.isRecipe, servings: food.servings, isFavorite: food.isFavorite));
    return id;
  }

  Future<int> updateFood(Food food) async {
    final db = await database;
    final updated = await db.update('foods', {...food.toMap(), 'is_custom': 1, 'is_deleted': 0}, where: 'id = ?', whereArgs: [food.id]);
    await _upsertFood(food);
    return updated;
  }

  Future<List<Food>> getAllFoods() async {
    final db = await database;
    final rows = await db.query('foods', where: 'is_deleted = 0');
    return rows.map(Food.fromMap).toList();
  }

  Future<void> toggleFavorite(int id, bool isFavorite) async {
    final db = await database;
    await db.update('foods', {'is_favorite': isFavorite ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
    final rows = await db.query('foods', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isNotEmpty) {
      final name = rows.first['name'] as String;
      await _sync(() async => MacroSyncService.instance.mutate(entity: 'favorites', operation: 'upsert', row: {'food_name': name, 'is_favorite': isFavorite}));
      if ((rows.first['is_custom'] as int? ?? 0) == 1) await _upsertFood(Food.fromMap(rows.first));
    }
  }

  Future<int> insertMealEntry(int foodId, double weightGrams, String date) async {
    final db = await database;
    final foods = await db.query('foods', where: 'id = ?', whereArgs: [foodId], limit: 1);
    if (foods.isEmpty) throw StateError('Food not found');
    final food = Food.fromMap(foods.first);
    final clientId = _newClientId();
    final id = await db.insert('meal_entries', {'food_id': foodId, 'weight_grams': weightGrams, 'meal_date': date, 'client_id': clientId, 'is_deleted': 0});
    await _sync(() async {
      await MacroSyncService.instance.mutate(entity: 'meals', operation: 'upsert', row: _remoteMeal(clientId: clientId, food: food, grams: weightGrams, date: date));
    });
    return id;
  }

  Future<void> deleteMealEntry(int entryId) async {
    final db = await database;
    final rows = await db.query('meal_entries', where: 'id = ?', whereArgs: [entryId], limit: 1);
    if (rows.isEmpty) return;
    final meal = rows.first;
    final foodRows = await db.query('foods', where: 'id = ?', whereArgs: [meal['food_id']], limit: 1);
    final clientId = meal['client_id'] as String?;
    if (clientId != null && foodRows.isNotEmpty) {
      await _sync(() async => MacroSyncService.instance.mutate(
            entity: 'meals',
            operation: 'upsert',
            row: _remoteMeal(
              clientId: clientId,
              food: Food.fromMap(foodRows.first),
              grams: (meal['weight_grams'] as num).toDouble(),
              date: meal['meal_date'] as String,
              deleted: true,
            ),
          ));
    }
    await db.update('meal_entries', {'is_deleted': 1}, where: 'id = ?', whereArgs: [entryId]);
  }

  Future<List<Map<String, dynamic>>> getMealsForDate(String date) async {
    final db = await database;
    return db.rawQuery('''
      SELECT m.id as entry_id, m.client_id, m.weight_grams, m.meal_date,
             f.name as food_name, f.calories_per_100g, f.protein_per_100g, f.carbs_per_100g, f.fat_per_100g, f.is_liquid, f.is_recipe, f.servings
      FROM meal_entries m JOIN foods f ON m.food_id = f.id
      WHERE m.meal_date = ? AND m.is_deleted = 0 ORDER BY m.id
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
    return maps.isEmpty ? null : maps.first;
  }

  Future<Map<String, dynamic>> getDefaultTargets() async {
    final saved = await getTargetsForDate(_defaultTargetsDate);
    if (saved != null) return saved;
    await saveTargetsForDate(_defaultTargetsDate, _initialCaloriesTarget, _initialProteinTarget, _initialCarbsTarget, _initialFatTarget);
    return (await getTargetsForDate(_defaultTargetsDate))!;
  }

  Future<void> saveDefaultTargets(double calories, double protein, double carbs, double fat) =>
      saveTargetsForDate(_defaultTargetsDate, calories, protein, carbs, fat);

  Future<void> saveTargetsForDate(String date, double cal, double pro, double carb, double fat) async {
    final db = await database;
    final row = {'date': date, 'calories': cal, 'protein': pro, 'carbs': carb, 'fat': fat};
    await db.insert('daily_targets', row, conflictAlgorithm: ConflictAlgorithm.replace);
    await _sync(() async => MacroSyncService.instance.mutate(entity: 'targets', operation: 'upsert', row: row));
  }

  Future<void> deleteFood(int id) async {
    final db = await database;
    final foods = await db.query('foods', where: 'id = ?', whereArgs: [id], limit: 1);
    if (foods.isEmpty) return;
    final food = Food.fromMap(foods.first);
    final meals = await db.query('meal_entries', where: 'food_id = ? AND is_deleted = 0', whereArgs: [id]);
    for (final meal in meals) {
      final clientId = meal['client_id'] as String?;
      if (clientId != null) {
        await _sync(() async => MacroSyncService.instance.mutate(
              entity: 'meals',
              operation: 'upsert',
              row: _remoteMeal(
                clientId: clientId,
                food: food,
                grams: (meal['weight_grams'] as num).toDouble(),
                date: meal['meal_date'] as String,
                deleted: true,
              ),
            ));
      }
    }
    await _upsertFood(food, deleted: true);
    await db.update('meal_entries', {'is_deleted': 1}, where: 'food_id = ?', whereArgs: [id]);
    await db.update('foods', {'is_custom': 1, 'is_deleted': 1}, where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, dynamic>> getSettings() async {
    final db = await database;
    final maps = await db.query('app_settings', where: 'id = 1');
    if (maps.isEmpty) {
      await db.insert('app_settings', {'id': 1});
      return (await db.query('app_settings', where: 'id = 1')).first;
    }
    return maps.first;
  }

  Future<void> saveSettings(Map<String, dynamic> settings) async {
    final db = await database;
    await db.update('app_settings', settings, where: 'id = 1');
    final row = await getSettings()..remove('id');
    await _sync(() async => MacroSyncService.instance.mutate(entity: 'settings', operation: 'upsert', row: row));
  }

  /// Fetch profile data while keeping the 9,240 item base catalog in the local asset.
  Future<void> synchronizeFromRemote() async {
    final snapshot = await MacroSyncService.instance.snapshot();
    final data = Map<String, dynamic>.from(snapshot['data'] as Map);
    final db = await database;
    final userFoods = (data['user_foods'] as List? ?? []).cast<Map>();
    for (final raw in userFoods) {
      final row = Map<String, dynamic>.from(raw);
      final name = row['name'] as String;
      final local = await db.query('foods', where: 'name = ?', whereArgs: [name], limit: 1);
      if (row['is_deleted'] == true) {
        if (local.isNotEmpty) await db.update('foods', {'is_deleted': 1, 'is_custom': 1}, where: 'name = ?', whereArgs: [name]);
        continue;
      }
      final values = {
        'name': name,
        'calories_per_100g': (row['calories'] as num).toDouble(), 'protein_per_100g': (row['protein'] as num).toDouble(),
        'carbs_per_100g': (row['carbs'] as num).toDouble(), 'fat_per_100g': (row['fat'] as num).toDouble(),
        'is_liquid': row['is_liquid'] == true ? 1 : 0, 'is_recipe': row['is_recipe'] == true ? 1 : 0,
        'servings': (row['servings'] as num?)?.toDouble() ?? 1.0, 'is_favorite': row['is_favorite'] == true ? 1 : 0,
        'is_custom': 1, 'is_deleted': 0,
      };
      if (local.isEmpty) {
        await db.insert('foods', values, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        await db.update('foods', values, where: 'name = ?', whereArgs: [name]);
      }
    }

    await db.update('foods', {'is_favorite': 0});
    final favoriteNames = <String>{};
    for (final raw in (data['favorites'] as List? ?? []).cast<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      if (row['is_favorite'] == true) favoriteNames.add(row['food_name'] as String);
    }
    for (final raw in userFoods) {
      final row = Map<String, dynamic>.from(raw);
      if (row['is_favorite'] == true && row['is_deleted'] != true) favoriteNames.add(row['name'] as String);
    }
    for (final name in favoriteNames) await db.update('foods', {'is_favorite': 1}, where: 'name = ?', whereArgs: [name]);

    for (final raw in (data['meals'] as List? ?? []).cast<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final clientId = row['client_id'] as String;
      final existing = await db.query('meal_entries', where: 'client_id = ?', whereArgs: [clientId], limit: 1);
      if (row['is_deleted'] == true) {
        if (existing.isNotEmpty) await db.update('meal_entries', {'is_deleted': 1}, where: 'client_id = ?', whereArgs: [clientId]);
        continue;
      }
      var foodRows = await db.query('foods', where: 'name = ?', whereArgs: [row['food_name']], limit: 1);
      if (foodRows.isEmpty) {
        await db.insert('foods', {
          'name': row['food_name'], 'calories_per_100g': row['calories'], 'protein_per_100g': row['protein'],
          'carbs_per_100g': row['carbs'], 'fat_per_100g': row['fat'], 'is_liquid': row['is_liquid'] == true ? 1 : 0,
          'is_recipe': row['is_recipe'] == true ? 1 : 0, 'servings': row['servings'] ?? 1, 'is_custom': 1,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        foodRows = await db.query('foods', where: 'name = ?', whereArgs: [row['food_name']], limit: 1);
      }
      if (foodRows.isEmpty) continue;
      final meal = {
        'food_id': foodRows.first['id'], 'weight_grams': (row['grams'] as num).toDouble(), 'meal_date': row['date'], 'client_id': clientId, 'is_deleted': 0,
      };
      if (existing.isEmpty) {
        await db.insert('meal_entries', meal, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        await db.update('meal_entries', meal, where: 'client_id = ?', whereArgs: [clientId]);
      }
    }

    for (final raw in (data['targets'] as List? ?? []).cast<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      await db.insert('daily_targets', {'date': row['date'], 'calories': row['calories'], 'protein': row['protein'], 'carbs': row['carbs'], 'fat': row['fat']}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final remoteSettings = (data['settings'] as List? ?? []).cast<Map>();
    if (remoteSettings.isNotEmpty) {
      final row = Map<String, dynamic>.from(remoteSettings.first)..remove('user_id')..remove('updated_at');
      await db.update('app_settings', row, where: 'id = 1');
    }
    await _uploadLocalSnapshot(db);
  }

  Future<void> _uploadRows(String entity, List<Map<String, dynamic>> rows) async {
    if (!MacroSyncService.instance.isSignedIn) return;
    try {
      for (var offset = 0; offset < rows.length; offset += 200) {
        final end = min(offset + 200, rows.length);
        await MacroSyncService.instance.mutateBatch(entity: entity, rows: rows.sublist(offset, end));
      }
    } catch (error) {
      debugPrint('Cloud batch sync deferred for $entity: $error');
    }
  }

  Future<void> _uploadLocalSnapshot(Database db) async {
    final customFoods = await db.query('foods', where: 'is_custom = 1');
    await _uploadRows('user_foods', customFoods.map((row) => _remoteFood(Food.fromMap(row), deleted: row['is_deleted'] == 1)).toList());
    final favorites = await db.query('foods', where: 'is_favorite = 1');
    await _uploadRows('favorites', favorites.map((row) => <String, dynamic>{'food_name': row['name'], 'is_favorite': true}).toList());
    final mealRows = await db.rawQuery('''SELECT m.client_id, m.weight_grams, m.meal_date, m.is_deleted AS meal_is_deleted, f.* FROM meal_entries m JOIN foods f ON f.id=m.food_id''');
    final meals = mealRows.map((row) => <String, dynamic>{
      'client_id': row['client_id'], 'food_name': row['name'], 'grams': row['weight_grams'], 'date': row['meal_date'],
      'calories': row['calories_per_100g'], 'protein': row['protein_per_100g'], 'carbs': row['carbs_per_100g'], 'fat': row['fat_per_100g'],
      'is_liquid': row['is_liquid'] == 1, 'is_recipe': row['is_recipe'] == 1, 'servings': row['servings'], 'is_deleted': row['meal_is_deleted'] == 1,
    }).toList();
    await _uploadRows('meals', meals);
    final targets = (await db.query('daily_targets')).map((row) => Map<String, dynamic>.from(row)).toList();
    await _uploadRows('targets', targets);
    final settings = await getSettings()..remove('id');
    await _uploadRows('settings', [settings]);
  }
}
