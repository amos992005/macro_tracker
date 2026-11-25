import '../data/models/food.dart';

const mealBuilderCompositeTitle = 'ארוחה מבונה הארוחות';

/// Builds the component payload used by the composite-meal diary flow.
/// Nutrient values and liquid classification come directly from the catalog;
/// the amount comes from the optimizer's solved weights.
List<Map<String, dynamic>> buildCompositeMealComponents({
  required Iterable<Food> foods,
  required Map<int, double> weights,
}) {
  return foods.where((food) {
    final id = food.id;
    return id != null && (weights[id] ?? 0) > 0.1;
  }).map((food) {
    final grams = weights[food.id]!;
    return <String, dynamic>{
      'name': food.name,
      'search_query': food.name,
      'grams': grams,
      'is_liquid': food.isLiquid,
      'is_assumed_addition': false,
      'calories_per_100g': food.caloriesPer100g,
      'protein_per_100g': food.proteinPer100g,
      'carbs_per_100g': food.carbsPer100g,
      'fat_per_100g': food.fatPer100g,
    };
  }).toList();
}
