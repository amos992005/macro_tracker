class NutritionResult {
  final double calories;
  final double protein;
  final double carbs;
  final double fat;

  NutritionResult(this.calories, this.protein, this.carbs, this.fat);

  String get calDisplay => calories.toStringAsFixed(1);
  String get proDisplay => protein.toStringAsFixed(1);
  String get carbDisplay => carbs.toStringAsFixed(1);
  String get fatDisplay => fat.toStringAsFixed(1);
}

class Calculator {
  static NutritionResult calculateFromWeight({
    required double weightGrams,
    required double calPer100g,
    required double proPer100g,
    required double carbPer100g,
    required double fatPer100g,
  }) {
    return NutritionResult(
      calPer100g / 100.0 * weightGrams,
      proPer100g / 100.0 * weightGrams,
      carbPer100g / 100.0 * weightGrams,
      fatPer100g / 100.0 * weightGrams,
    );
  }
}