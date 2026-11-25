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

  group('conversational meal correction', () {
    test('builds a correction payload from the current editable meal', () {
      final payload = buildMealCorrectionPayload(
        mealTitle: '  ארוחת צהריים  ',
        correctionPrompt: '  הוסף כף טחינה  ',
        pro: true,
        items: [
          {
            'name': 'אורז',
            'search_query': 'אורז מבושל',
            'grams': 150.0,
            'count': 3.0,
            'grams_per_unit': 50.0,
            'calories_per_100g': 130.0,
            'protein_per_100g': 2.7,
            'carbs_per_100g': 28.0,
            'fat_per_100g': 0.3,
            'is_liquid': false,
            'is_assumed_addition': false,
            'ui_only_field': 'not sent',
          },
        ],
      );

      expect(payload['correction_prompt'], 'הוסף כף טחינה');
      expect(payload['pro'], isTrue);
      final meal = payload['current_meal'] as Map<String, dynamic>;
      expect(meal['meal_title'], 'ארוחת צהריים');
      final item = (meal['items'] as List).single as Map<String, dynamic>;
      expect(item['grams'], 150.0);
      expect(item['count'], 3.0);
      expect(item['grams_per_unit'], 50.0);
      expect(item['calories_per_100'], 130.0);
      expect(item['protein_per_100'], 2.7);
      expect(item.containsKey('calories_per_100g'), isFalse);
      expect(item.containsKey('ui_only_field'), isFalse);
    });

    test('preserves linked catalog nutrition but keeps corrected quantity', () {
      final selected = Food(
        name: 'לחם כוסמין',
        caloriesPer100g: 245,
        proteinPer100g: 9,
        carbsPer100g: 43,
        fatPer100g: 3.5,
        isLiquid: false,
      );
      final merged = mergeAiMealCorrectionItems(
        previousItems: [
          {
            'name': 'לחם כוסמין',
            'search_query': 'לחם כוסמין מלא',
            'grams': 30.0,
            'is_liquid': false,
            'calories_per_100g': 999.0,
            'protein_per_100g': 99.0,
            'carbs_per_100g': 99.0,
            'fat_per_100g': 99.0,
          },
        ],
        matchedFoodsByName: {'לחם כוסמין': selected},
        correctedItems: [
          {
            'name': ' לחם   כוסמין ',
            'search_query': 'other query',
            'grams': 45.0,
            'count': 3.0,
            'grams_per_unit': 15.0,
            'is_liquid': true,
            'calories_per_100g': 500.0,
            'protein_per_100g': 50.0,
            'carbs_per_100g': 50.0,
            'fat_per_100g': 50.0,
          },
          {
            'name': 'טחינה',
            'search_query': 'טחינה',
            'grams': 15.0,
            'is_liquid': false,
            'calories_per_100g': 600.0,
            'protein_per_100g': 17.0,
            'carbs_per_100g': 20.0,
            'fat_per_100g': 53.0,
          },
        ],
      );

      final bread = merged.first;
      expect(bread['name'], 'לחם כוסמין');
      expect(bread['search_query'], 'לחם כוסמין מלא');
      expect(bread['grams'], 45.0);
      expect(bread['count'], 3.0);
      expect(bread['grams_per_unit'], 15.0);
      expect(bread['calories_per_100g'], selected.caloriesPer100g);
      expect(bread['protein_per_100g'], selected.proteinPer100g);
      expect(bread['carbs_per_100g'], selected.carbsPer100g);
      expect(bread['fat_per_100g'], selected.fatPer100g);
      expect(bread['is_liquid'], selected.isLiquid);
      expect(merged.last['calories_per_100g'], 600.0);
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
