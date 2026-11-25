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
  group('AI Hebrew search query', () {
    test('English-only query falls back to Hebrew words in the name', () {
      expect(
        effectiveAiSearchQuery(
          name: 'דבש יד מרדכי',
          searchQuery: 'honey',
        ),
        'דבש יד מרדכי',
      );
    });

    test('a valid Hebrew query is preserved', () {
      expect(
        effectiveAiSearchQuery(name: 'דבש יד מרדכי', searchQuery: 'דבש'),
        'דבש',
      );
    });

    test('exact food matching falls back to the Hebrew name', () {
      final honey = makeFood(name: 'דבש יד מרדכי', isLiquid: false);
      expect(
        findExactAiFoodMatch(
          foods: [honey],
          name: 'דבש יד מרדכי',
          searchQuery: 'honey',
        ),
        same(honey),
      );
    });
  });

  group('AI catalog suggestions and save eligibility', () {
    test('unmatched AI foods receive up to three nearby suggestions', () {
      final suggestions = suggestAiFoodMatches(
        foods: [
          makeFood(name: 'דבש טהור מפרחי בר', isLiquid: false),
          makeFood(name: 'דבש', isLiquid: false),
          makeFood(name: 'ריבה', isLiquid: false),
          makeFood(name: 'דבש פרחי בר', isLiquid: false),
        ],
        name: 'דבש יד מרדכי',
        searchQuery: 'דבש יד מרדכי',
      );

      expect(suggestions, hasLength(3));
      expect(suggestions.map((food) => food.name), contains('דבש'));
      expect(
        suggestions.map((food) => food.name),
        contains('דבש טהור מפרחי בר'),
      );
    });

    test('exact existing name blocks saving a duplicate AI food', () {
      final existing = makeFood(name: 'דבש', isLiquid: false);
      expect(
        shouldOfferAiFoodSave(
          name: 'דבש',
          matchedFood: null,
          foods: [existing],
        ),
        isFalse,
      );
      expect(
        shouldOfferAiFoodSave(
          name: 'דבש חדש',
          matchedFood: null,
          foods: [existing],
        ),
        isTrue,
      );
      expect(
        shouldOfferAiFoodSave(
          name: 'דבש חדש',
          matchedFood: existing,
          foods: [],
        ),
        isFalse,
      );
    });
  });

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
    expect(nutrition.carbs, closeTo(16.2, 1e-9));

    expect(
      gramsFromUnitCount(count: 2.5, gramsPerUnit: 8),
      20,
    );
  });
}
