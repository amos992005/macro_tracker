import 'package:flutter_test/flutter_test.dart';
import 'package:macro_tracker/core/meal_optimizer.dart';
import 'package:macro_tracker/core/meal_rule_settings.dart';
import 'package:macro_tracker/data/database_helper.dart';
import 'package:macro_tracker/data/models/food.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final database = DatabaseHelper();

  setUpAll(() async {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await database.activateProfile('meal-rule-settings-test');
  });

  tearDownAll(() async {
    await database.deactivateProfile();
  });

  test('parses integer and decimal tolerances with whitespace', () {
    expect(MealRuleSettings.parsePercent('  12  ', fallback: 4), 12);
    expect(MealRuleSettings.parsePercent(' 2.75 ', fallback: 4), 2.75);
    expect(MealRuleSettings.parsePercent(' 2,75 ', fallback: 4), 2.75);
    expect(MealRuleSettings.parsePercent(' ', fallback: 4), 4);
    expect(MealRuleSettings.parsePercent('-1', fallback: 4), 4);
  });

  test('saves and reloads every tolerance and passes them to MealOptimizer', () async {
    const settings = <String, dynamic>{
      'cal_mode': 'both', 'cal_pct': 2.5,
      'pro_mode': 'both', 'pro_pct': 3.5,
      'carb_mode': 'both', 'carb_pct': 4.5,
      'fat_mode': 'both', 'fat_pct': 5.5,
    };

    await database.saveSettings(settings);
    final loaded = await database.getSettings();
    for (final entry in settings.entries) {
      expect(loaded[entry.key], entry.value);
    }

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

    expect(result, isNotNull);
    expect(result!.weights[food.id], closeTo(100, 3));
    expect(result.totalCalories, inInclusiveRange(97.5, 102.5));
    expect(result.totalProtein, inInclusiveRange(9.65, 10.35));
    expect(result.totalCarbs, inInclusiveRange(19.1, 20.9));
    expect(result.totalFat, inInclusiveRange(4.725, 5.275));
  });
}
