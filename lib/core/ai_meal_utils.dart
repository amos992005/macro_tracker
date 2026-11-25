import '../data/models/food.dart';
import 'search_utils.dart';

/// Uses a Hebrew name as the fallback for searches when the AI sends a
/// non-Hebrew query. Hebrew queries from the AI are preserved as-is.
String effectiveAiSearchQuery({
  required String name,
  required String searchQuery,
}) {
  final query = searchQuery.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (_containsHebrew(query)) return query;

  final hebrewName = RegExp(r'[\u05D0-\u05EA]+')
      .allMatches(name)
      .map((match) => match.group(0)!)
      .join(' ');
  return hebrewName.isNotEmpty ? hebrewName : query;
}

/// Finds exact local database entries, preferring the effective search query
/// and then trying the Hebrew item name. No approximate brand matching is used.
Food? findExactAiFoodMatch({
  required Iterable<Food> foods,
  required String name,
  required String searchQuery,
}) {
  final queries = <String>[
    _normalizeFoodName(
      effectiveAiSearchQuery(name: name, searchQuery: searchQuery),
    ),
    _normalizeFoodName(name),
  ].where((value) => value.isNotEmpty).toSet();

  for (final query in queries) {
    for (final food in foods) {
      if (_normalizeFoodName(food.name) == query) return food;
    }
  }
  return null;
}

/// Returns a few nearby catalog choices for an unmatched AI item. Search is
/// intentionally performed by the caller during item initialization or after
/// a replacement—not from a widget build method.
List<Food> suggestAiFoodMatches({
  required Iterable<Food> foods,
  required String name,
  required String searchQuery,
  int limit = 3,
}) {
  final maximum = limit > 3 ? 3 : limit;
  final catalog = foods.toList();
  if (maximum <= 0 ||
      findExactAiFoodMatch(
            foods: catalog,
            name: name,
            searchQuery: searchQuery,
          ) !=
          null) {
    return const [];
  }

  final effectiveQuery = effectiveAiSearchQuery(
    name: name,
    searchQuery: searchQuery,
  );
  final queries = <String>{
    effectiveQuery,
    name,
    ...SearchUtils.normalize(effectiveQuery).split(' '),
  }.where((query) => query.trim().isNotEmpty);
  final seen = <String>{};
  final suggestions = <Food>[];
  for (final query in queries) {
    for (final food in SearchUtils.filterAndSortFoods(catalog, query)) {
      if (food.name.trim() == name.trim()) continue;
      final key = SearchUtils.normalize(food.name);
      if (!seen.add(key)) continue;
      suggestions.add(food);
      if (suggestions.length == maximum) return suggestions;
    }
  }
  return suggestions;
}

bool hasExactFoodName(Iterable<Food> foods, String name) =>
    foods.any((food) => food.name.trim() == name.trim());

bool shouldOfferAiFoodSave({
  required String name,
  required Food? matchedFood,
  required Iterable<Food> foods,
}) =>
    name.trim().isNotEmpty &&
    matchedFood == null &&
    !hasExactFoodName(foods, name);

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

bool _containsHebrew(String value) =>
    RegExp(r'[\u05D0-\u05EA]').hasMatch(value);

String _normalizeFoodName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
