import '../data/models/food.dart';

/// Finds a database entry only when the AI's name or search query matches it
/// exactly after whitespace/case normalization. Approximate matches are unsafe
/// for choosing a unit or replacing nutrition values.
Food? findExactAiFoodMatch({
  required Iterable<Food> foods,
  required String name,
  required String searchQuery,
}) {
  final candidates = {
    _normalizeFoodName(name),
    _normalizeFoodName(searchQuery),
  }..remove('');
  if (candidates.isEmpty) return null;

  for (final food in foods) {
    if (candidates.contains(_normalizeFoodName(food.name))) return food;
  }
  return null;
}

/// Database classification is authoritative for AI item units. An AI-provided
/// liquid flag is only a hint and never turns an unknown/solid food into mL.
bool shouldUseMilliliters({
  required bool aiSaysLiquid,
  required bool? matchedFoodIsLiquid,
}) {
  if (aiSaysLiquid && matchedFoodIsLiquid != true) return false;
  return matchedFoodIsLiquid == true;
}

/// Converts a count-based portion assumption into the total amount used by
/// the existing nutrition calculation (which treats mL and grams 1:1).
double gramsFromUnitCount({
  required double count,
  required double gramsPerUnit,
}) => count * gramsPerUnit;

String _normalizeFoodName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
