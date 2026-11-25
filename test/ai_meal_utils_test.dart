import 'package:flutter_test/flutter_test.dart';
import 'package:macro_tracker/core/ai_meal_utils.dart';
import 'package:macro_tracker/core/calculator.dart';
import 'package:macro_tracker/data/models/food.dart';

Food makeFood({required String name, required bool isLiquid}) => Food(
      name: name,
      caloriesPer100g: 320,
      proteinPer100g: 0,
      carbsPer100g: 80,
      fatPer100g: 0,
      isLiquid: isLiquid,
    );

void main() {
  group('AI unit mapping', () {
    test('AI mL hint is ignored when exact database match is not liquid', () {
      final foods = [makeFood(name: 'דבש', isLiquid: false)];
      final match = findExactAiFoodMatch(
        foods: foods,
        name: 'דבש',
        searchQuery: 'דבש',
      );

      expect(
        shouldUseMilliliters(
          aiSaysLiquid: true,
          matchedFoodIsLiquid: match?.isLiquid,
        ),
        isFalse,
      );
    });

    test('a matched database liquid uses mL even without an AI liquid hint', () {
      final foods = [makeFood(name: 'חלב', isLiquid: true)];
      final match = findExactAiFoodMatch(
        foods: foods,
        name: 'חלב',
        searchQuery: 'חלב',
      );

      expect(
        shouldUseMilliliters(
          aiSaysLiquid: false,
          matchedFoodIsLiquid: match?.isLiquid,
        ),
        isTrue,
      );
    });

    test('no exact database match defaults to grams despite an mL hint', () {
      expect(
        findExactAiFoodMatch(
          foods: [makeFood(name: 'דבש', isLiquid: false)],
          name: 'דבש יד מרדכי',
          searchQuery: 'דבש יד מרדכי',
        ),
        isNull,
      );
      expect(
        shouldUseMilliliters(
          aiSaysLiquid: true,
          matchedFoodIsLiquid: null,
        ),
        isFalse,
      );
    });
  });

  test('count times grams per unit updates grams and nutrition totals', () {
    final totalGrams = gramsFromUnitCount(count: 2, gramsPerUnit: 10);
    expect(totalGrams, 20);

    final nutrition = Calculator.calculateFromWeight(
      weightGrams: totalGrams,
      calPer100g: 380,
      proPer100g: 8,
      carbPer100g: 81,
      fatPer100g: 3,
    );
    expect(nutrition.calories, 76);
    expect(nutrition.carbs, 16.2);

    expect(
      gramsFromUnitCount(count: 2.5, gramsPerUnit: 8),
      20,
    );
  });
}
