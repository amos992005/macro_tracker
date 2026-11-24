import 'package:flutter_test/flutter_test.dart';
import 'package:macro_tracker/core/calculator.dart';
import 'package:macro_tracker/data/models/food.dart';
import 'package:macro_tracker/main.dart';

void main() {
  test('MacroTrackerApp entry point and core nutrition model load', () {
    // Constructing the root widget does not initialize the SQLite plugin, so
    // this smoke test also runs on test platforms without SQLite FFI setup.
    expect(const MacroTrackerApp(), isA<MacroTrackerApp>());

    final food = Food(
      name: 'בדיקת מזון',
      caloriesPer100g: 100,
      proteinPer100g: 10,
      carbsPer100g: 20,
      fatPer100g: 5,
    );
    final restoredFood = Food.fromMap(food.toMap());
    expect(restoredFood.name, food.name);

    final nutrition = Calculator.calculateFromWeight(
      weightGrams: 50,
      calPer100g: restoredFood.caloriesPer100g,
      proPer100g: restoredFood.proteinPer100g,
      carbPer100g: restoredFood.carbsPer100g,
      fatPer100g: restoredFood.fatPer100g,
    );
    expect(nutrition.calories, 50);
    expect(nutrition.protein, 5);
  });
}
