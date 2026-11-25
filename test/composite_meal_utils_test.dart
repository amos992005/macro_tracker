import 'package:flutter_test/flutter_test.dart';
import 'package:macro_tracker/core/composite_meal_utils.dart';
import 'package:macro_tracker/data/models/food.dart';

void main() {
  test('optimizer weights become composite components with catalog nutrition', () {
    final rice = Food(
      id: 1,
      name: 'אורז מבושל',
      caloriesPer100g: 130,
      proteinPer100g: 2.7,
      carbsPer100g: 28,
      fatPer100g: 0.3,
    );
    final milk = Food(
      id: 2,
      name: 'חלב',
      caloriesPer100g: 62,
      proteinPer100g: 3.2,
      carbsPer100g: 4.8,
      fatPer100g: 3.4,
      isLiquid: true,
    );
    final omitted = Food(
      id: 3,
      name: 'מאכל שלא נבחר בפועל',
      caloriesPer100g: 200,
      proteinPer100g: 10,
      carbsPer100g: 20,
      fatPer100g: 5,
    );

    final components = buildCompositeMealComponents(
      foods: [rice, milk, omitted],
      weights: {1: 175.5, 2: 80, 3: 0},
    );

    expect(mealBuilderCompositeTitle, 'ארוחה מבונה הארוחות');
    expect(components, hasLength(2));
    expect(components[0], {
      'name': 'אורז מבושל',
      'search_query': 'אורז מבושל',
      'grams': 175.5,
      'is_liquid': false,
      'is_assumed_addition': false,
      'calories_per_100g': 130,
      'protein_per_100g': 2.7,
      'carbs_per_100g': 28,
      'fat_per_100g': 0.3,
    });
    expect(components[1]['grams'], 80);
    expect(components[1]['is_liquid'], isTrue);
    expect(components[1]['calories_per_100g'], 62);
  });
}
