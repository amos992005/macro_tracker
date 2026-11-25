import 'package:flutter_test/flutter_test.dart';
import 'package:macro_tracker/core/meal_optimizer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:macro_tracker/data/database_helper.dart';
import 'package:macro_tracker/data/models/food.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper();

  setUpAll(() async {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await helper.activateProfile('ai-food-save-test-${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDownAll(() async {
    await helper.deactivateProfile();
  });

  test('saving the same AI food twice reuses the existing local row', () async {
    const name = 'מזון בדיקת שמירה כפולה';
    final first = await helper.insertFoodIfAbsent(
      Food(
        name: name,
        caloriesPer100g: 123,
        proteinPer100g: 4,
        carbsPer100g: 20,
        fatPer100g: 2,
        isLiquid: true,
      ),
    );
    final second = await helper.insertFoodIfAbsent(
      Food(
        name: name,
        caloriesPer100g: 999,
        proteinPer100g: 99,
        carbsPer100g: 99,
        fatPer100g: 99,
      ),
    );

    expect(first.inserted, isTrue);
    expect(second.inserted, isFalse);
    expect(second.food.id, first.food.id);
    expect(second.food.caloriesPer100g, 123);
    expect(second.food.isLiquid, isTrue);

    final db = await helper.database;
    final rows = await db.query(
      'foods',
      where: 'name = ? AND is_deleted = 0',
      whereArgs: [name],
    );
    expect(rows, hasLength(1));
  });

  const settings = <String, dynamic>{
    'cal_mode': 'both', 'cal_pct': 2.5,
    'pro_mode': 'both', 'pro_pct': 3.5,
    'carb_mode': 'both', 'carb_pct': 4.5,
    'fat_mode': 'both', 'fat_pct': 5.5,
  };

  test('saving and loading preserves each tolerance setting', () async {
    await helper.saveSettings(settings);
    final loaded = await helper.getSettings();
    final mismatches = settings.entries
        .where((entry) => loaded[entry.key] != entry.value)
        .map((entry) => '${entry.key}: expected ${entry.value}, got ${loaded[entry.key]}')
        .toList();
    if (mismatches.isNotEmpty) {
      throw StateError('Tolerance settings did not persist: ${mismatches.join('; ')}');
    }
  });

  test('reloaded tolerance settings are accepted by MealOptimizer', () async {
    await helper.saveSettings(settings);
    final loaded = await helper.getSettings();
    final food = Food(
      id: 701,
      name: 'בדיקת יחס מאקרו',
      caloriesPer100g: 100,
      proteinPer100g: 10,
      carbsPer100g: 20,
      fatPer100g: 5,
    );
    final result = MealOptimizer.findOptimalWeights(
      selectedFoods: [food],
      targets: const [100, 10, 20, 5],
      preferences: const [3],
      settings: loaded,
    );
    if (result == null) {
      throw StateError('Optimizer rejected the reloaded tolerances: ${MealOptimizer.lastErrorMessage}');
    }
  });
}
