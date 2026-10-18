import 'dart:math';
import '../data/models/food.dart';

class OptimizationResult {
  final Map<int, double> weights;
  final double totalCalories;
  final double totalProtein;
  final double totalCarbs;
  final double totalFat;

  OptimizationResult({
    required this.weights,
    required this.totalCalories,
    required this.totalProtein,
    required this.totalCarbs,
    required this.totalFat,
  });
}

class MealOptimizer {
  static final Random _random = Random();

  static OptimizationResult? findOptimalWeights({
    required List<Food> selectedFoods,
    required List<double> targets,
    required List<int> preferences,
    required Map<String, dynamic> settings, // מקבל את ההגדרות
  }) {
    if (selectedFoods.isEmpty) return null;

    double bestScore = -double.infinity;
    List<double>? bestWeights;
    double bestCal = 0, bestPro = 0, bestCarb = 0, bestFat = 0;

    for (int i = 0; i < 5000; i++) {
      List<double> testWeights = List.generate(selectedFoods.length, (_) => _random.nextDouble() * 400);

      for (int step = 0; step < 20; step++) {
        int idx = _random.nextInt(selectedFoods.length);
        double change = (_random.nextDouble() - 0.5) * 100;
        testWeights[idx] = (testWeights[idx] + change).clamp(0, 1000);
      }

      final res = _evaluate(testWeights, selectedFoods, targets, preferences.map((e) => e.toDouble()).toList(), settings);

      if (res != null && res.score > bestScore) {
        bestScore = res.score;
        bestWeights = List.from(testWeights);
        bestCal = res.cal; bestPro = res.pro; bestCarb = res.carb; bestFat = res.fat;
      }
    }

    if (bestWeights != null) {
      for (int iter = 0; iter < 100; iter++) {
        for (int i = 0; i < selectedFoods.length; i++) {
          List<double> testW = List.from(bestWeights!);
          testW[i] = (testW[i] + (_random.nextDouble() - 0.5) * 10).clamp(0, 1000);
          final res = _evaluate(testW, selectedFoods, targets, preferences.map((e) => e.toDouble()).toList(), settings);
          if (res != null && res.score > bestScore) {
            bestScore = res.score;
            bestWeights = List.from(testW);
            bestCal = res.cal; bestPro = res.pro; bestCarb = res.carb; bestFat = res.fat;
          }
        }
      }
    }

    if (bestWeights == null) return null;

    Map<int, double> finalWeights = {};
    for (int i = 0; i < selectedFoods.length; i++) {
      if (bestWeights[i] > 0.1) {
        finalWeights[selectedFoods[i].id!] = bestWeights[i];
      }
    }

    return OptimizationResult(
      weights: finalWeights,
      totalCalories: bestCal,
      totalProtein: bestPro,
      totalCarbs: bestCarb,
      totalFat: bestFat,
    );
  }

  static OptimizationResult? adjustWeight({
    required List<Food> selectedFoods,
    required List<double> targets,
    required List<int> preferences,
    required Map<String, dynamic> settings,
    required int lockedFoodId,
    required double currentWeight,
    required double changeAmount,
  }) {
    double newTargetWeight = (currentWeight + changeAmount).clamp(0, 2000);
    int lockedIndex = selectedFoods.indexWhere((f) => f.id == lockedFoodId);
    if (lockedIndex == -1) return null;

    double bestScore = -double.infinity;
    List<double>? bestWeights;
    double bestCal = 0, bestPro = 0, bestCarb = 0, bestFat = 0;

    for (int i = 0; i < 3000; i++) {
      List<double> testWeights = List.filled(selectedFoods.length, 0);
      testWeights[lockedIndex] = newTargetWeight;

      for (int j = 0; j < selectedFoods.length; j++) {
        if (j != lockedIndex) {
          testWeights[j] = _random.nextDouble() * 400;
        }
      }

      final res = _evaluate(testWeights, selectedFoods, targets, preferences.map((e) => e.toDouble()).toList(), settings);
      if (res != null && res.score > bestScore) {
        bestScore = res.score;
        bestWeights = List.from(testWeights);
        bestCal = res.cal; bestPro = res.pro; bestCarb = res.carb; bestFat = res.fat;
      }
    }

    if (bestWeights == null) return null;

    Map<int, double> finalWeights = {};
    for (int i = 0; i < selectedFoods.length; i++) {
      if (bestWeights[i] > 0.1) {
        finalWeights[selectedFoods[i].id!] = bestWeights[i];
      }
    }

    return OptimizationResult(
      weights: finalWeights,
      totalCalories: bestCal,
      totalProtein: bestPro,
      totalCarbs: bestCarb,
      totalFat: bestFat,
    );
  }

  // הפונקציה החכמה - קוראת את החוקים מההגדרות
  static _EvalResult? _evaluate(List<double> weights, List<Food> foods, List<double> targets, List<double> prefs, Map<String, dynamic> settings) {
    double cal = 0, pro = 0, carb = 0, fat = 0;

    for (int i = 0; i < foods.length; i++) {
      cal += foods[i].caloriesPer100g / 100 * weights[i];
      pro += foods[i].proteinPer100g / 100 * weights[i];
      carb += foods[i].carbsPer100g / 100 * weights[i];
      fat += foods[i].fatPer100g / 100 * weights[i];
    }

    double tCal = targets[0], tPro = targets[1], tCarb = targets[2], tFat = targets[3];

    // פונקציית עזר שבודקת את החוקים
    bool checkRule(String mode, double pct, double actual, double target) {
      if (mode == 'free') return true; // גמיש
      if (mode == 'up') return actual >= target - 0.1; // רק למעלה (או בדיוק)
      if (mode == 'down') return actual <= target + 0.1; // רק למטה (או בדיוק)
      // both
      return actual >= target * (1 - pct/100) && actual <= target * (1 + pct/100);
    }

    // בדיקת החוקים של כל פרמטר
    if (!checkRule(settings['pro_mode'] ?? 'up', settings['pro_pct'] ?? 10.0, pro, tPro)) return null;
    if (!checkRule(settings['carb_mode'] ?? 'both', settings['carb_pct'] ?? 10.0, carb, tCarb)) return null;
    if (!checkRule(settings['cal_mode'] ?? 'down', settings['cal_pct'] ?? 10.0, cal, tCal)) return null;
    if (!checkRule(settings['fat_mode'] ?? 'free', settings['fat_pct'] ?? 0.0, fat, tFat)) return null;

    double preferenceScore = 0;
    for (int i = 0; i < foods.length; i++) {
      preferenceScore += weights[i] * prefs[i];
    }

    double accuracyBonus = 0;
    accuracyBonus -= (tCal - cal).abs() * 2.0;
    accuracyBonus -= (tPro - pro).abs() * 10.0;
    accuracyBonus -= (tCarb - carb).abs() * 2.0;

    return _EvalResult(preferenceScore + accuracyBonus, cal, pro, carb, fat);
  }
}

class _EvalResult {
  final double score;
  final double cal, pro, carb, fat;
  _EvalResult(this.score, this.cal, this.pro, this.carb, this.fat);
}