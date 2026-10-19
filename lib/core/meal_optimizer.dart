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
  static String? lastErrorMessage;
  static String? _lastConstraintFailed; // <-- משתנה חדש לשמירת סיבת הפסילה

  static OptimizationResult? findOptimalWeights({
    required List<Food> selectedFoods,
    required List<double> targets,
    required List<int> preferences,
    required Map<String, dynamic> settings,
  }) {
    if (selectedFoods.isEmpty) return null;
    return optimizeWithFixed(
      allFoods: selectedFoods,
      fixedWeights: {},
      targets: targets,
      preferences: preferences,
      settings: settings,
    );
  }

  static OptimizationResult? optimizeWithFixed({
    required List<Food> allFoods,
    required Map<int, double> fixedWeights,
    required List<double> targets,
    required List<int> preferences,
    required Map<String, dynamic> settings,
    Map<int, double>? initialWeights,
  }) {
    lastErrorMessage = null;
    _lastConstraintFailed = null; // איפוס סיבת הפסילה

    if (allFoods.isEmpty) {
      lastErrorMessage = 'לא נבחרו מוצרים.';
      return null;
    }

    List<Food> freeFoods = [];
    List<int> freePrefs = [];
    double fixedCal = 0, fixedPro = 0, fixedCarb = 0, fixedFat = 0;

    for (int i = 0; i < allFoods.length; i++) {
      Food food = allFoods[i];
      double w = fixedWeights[food.id] ?? 0.0;

      fixedCal += food.caloriesPer100g / 100 * w;
      fixedPro += food.proteinPer100g / 100 * w;
      fixedCarb += food.carbsPer100g / 100 * w;
      fixedFat += food.fatPer100g / 100 * w;

      if (!fixedWeights.containsKey(food.id)) {
        freeFoods.add(food);
        freePrefs.add(preferences[i]);
      }
    }

    double tCal = targets[0], tPro = targets[1], tCarb = targets[2], tFat = targets[3];

    double calMin = 0, calMax = double.infinity;
    if (settings['cal_mode'] == 'down') { calMin = tCal * (1 - (settings['cal_pct'] ?? 10.0)/100); calMax = tCal; }
    else if (settings['cal_mode'] == 'up') { calMin = tCal; calMax = tCal * (1 + (settings['cal_pct'] ?? 10.0)/100); }
    else if (settings['cal_mode'] == 'both') { calMin = tCal * (1 - (settings['cal_pct'] ?? 10.0)/100); calMax = tCal * (1 + (settings['cal_pct'] ?? 10.0)/100); }

    double proMin = 0, proMax = double.infinity;
    if (settings['pro_mode'] == 'down') { proMin = tPro * (1 - (settings['pro_pct'] ?? 10.0)/100); proMax = tPro; }
    else if (settings['pro_mode'] == 'up') { proMin = tPro; proMax = tPro * (1 + (settings['pro_pct'] ?? 10.0)/100); }
    else if (settings['pro_mode'] == 'both') { proMin = tPro * (1 - (settings['pro_pct'] ?? 10.0)/100); proMax = tPro * (1 + (settings['pro_pct'] ?? 10.0)/100); }

    double carbMin = 0, carbMax = double.infinity;
    if (settings['carb_mode'] == 'down') { carbMin = tCarb * (1 - (settings['carb_pct'] ?? 10.0)/100); carbMax = tCarb; }
    else if (settings['carb_mode'] == 'up') { carbMin = tCarb; carbMax = tCarb * (1 + (settings['carb_pct'] ?? 10.0)/100); }
    else if (settings['carb_mode'] == 'both') { carbMin = tCarb * (1 - (settings['carb_pct'] ?? 10.0)/100); carbMax = tCarb * (1 + (settings['carb_pct'] ?? 10.0)/100); }

    double fatMin = 0, fatMax = double.infinity;
    if (settings['fat_mode'] == 'down') { fatMin = tFat * (1 - (settings['fat_pct'] ?? 10.0)/100); fatMax = tFat; }
    else if (settings['fat_mode'] == 'up') { fatMin = tFat; fatMax = tFat * (1 + (settings['fat_pct'] ?? 10.0)/100); }
    else if (settings['fat_mode'] == 'both') { fatMin = tFat * (1 - (settings['fat_pct'] ?? 10.0)/100); fatMax = tFat * (1 + (settings['fat_pct'] ?? 10.0)/100); }

    double remCalMax = calMax - fixedCal;
    double remProMax = proMax - fixedPro;
    double remCarbMax = carbMax - fixedCarb;
    double remFatMax = fatMax - fixedFat;

    if (remCalMax < -0.5) { lastErrorMessage = 'המוצר הזה חורג מיעד הקלוריות המקסימלי.'; return null; }
    if (remProMax < -0.5) { lastErrorMessage = 'המוצר הזה חורג מיעד החלבון המקסימלי.'; return null; }
    if (remCarbMax < -0.5) { lastErrorMessage = 'המוצר הזה חורג מיעד הפחמימות המקסימלי.'; return null; }
    if (remFatMax < -0.5) { lastErrorMessage = 'המוצר הזה חורג מיעד השומן המקסימלי.'; return null; }

    double maxPossibleCal = 0, maxPossiblePro = 0, maxPossibleCarb = 0, maxPossibleFat = 0;
    for (int i = 0; i < freeFoods.length; i++) {
      maxPossibleCal += freeFoods[i].caloriesPer100g / 100 * 2000;
      maxPossiblePro += freeFoods[i].proteinPer100g / 100 * 2000;
      maxPossibleCarb += freeFoods[i].carbsPer100g / 100 * 2000;
      maxPossibleFat += freeFoods[i].fatPer100g / 100 * 2000;
    }

    if (fixedCal + maxPossibleCal < calMin - 1.0) { lastErrorMessage = 'לא ניתן להגיע למינימום הקלוריות עם המוצרים הנוכחיים.'; return null; }
    if (fixedPro + maxPossiblePro < proMin - 1.0) { lastErrorMessage = 'לא ניתן להגיע למינימום החלבון עם המוצרים הנוכחיים.'; return null; }
    if (fixedCarb + maxPossibleCarb < carbMin - 1.0) { lastErrorMessage = 'לא ניתן להגיע למינימום הפחמימות עם המוצרים הנוכחיים.'; return null; }
    if (fixedFat + maxPossibleFat < fatMin - 1.0) { lastErrorMessage = 'לא ניתן להגיע למינימום השומן עם המוצרים הנוכחיים.'; return null; }

    if (calMin > calMax || proMin > proMax || carbMin > carbMax || fatMin > fatMax) {
      lastErrorMessage = 'לא ניתן למצוא שילוב חוקי עם המוצר הנוכחי.';
      return null;
    }

    calMin = max(0.0, calMin - fixedCal); calMax = calMax - fixedCal;
    proMin = max(0.0, proMin - fixedPro); proMax = proMax - fixedPro;
    carbMin = max(0.0, carbMin - fixedCarb); carbMax = carbMax - fixedCarb;
    fatMin = max(0.0, fatMin - fixedFat); fatMax = fatMax - fixedFat;

    int n = freeFoods.length;
    if (n == 0) {
      List<double> testWeights = allFoods.map((f) => fixedWeights[f.id] ?? 0.0).toList();
      final res = _evaluate(testWeights, allFoods, targets, preferences, settings, initialWeights);
      if (res != null) {
        return OptimizationResult(
          weights: Map.from(fixedWeights),
          totalCalories: res.cal, totalProtein: res.pro, totalCarbs: res.carb, totalFat: res.fat,
        );
      }
      lastErrorMessage = 'אין מספיק מוצרים חופשיים כדי לאזן את הארוחה.';
      return null;
    }

    List<double> calCoeffs = freeFoods.map((f) => f.caloriesPer100g / 100).toList();
    List<double> proCoeffs = freeFoods.map((f) => f.proteinPer100g / 100).toList();
    List<double> carbCoeffs = freeFoods.map((f) => f.carbsPer100g / 100).toList();
    List<double> fatCoeffs = freeFoods.map((f) => f.fatPer100g / 100).toList();

    int populationSize = 150;
    int generations = 100;
    List<List<double>> population = [];

    for (int i = 0; i < populationSize; i++) {
      List<double> x = List.filled(n, 0.0);
      for (int j = 0; j < n; j++) {
        int foodId = freeFoods[j].id!;
        if (initialWeights != null && initialWeights.containsKey(foodId)) {
          x[j] = (initialWeights[foodId]! + (_random.nextDouble() - 0.5) * 30).clamp(0, 2000);
        } else {
          x[j] = _random.nextDouble() * 300;
        }
      }
      _applyPOCS(x, calCoeffs, proCoeffs, carbCoeffs, fatCoeffs, calMin, calMax, proMin, proMax, carbMin, carbMax, fatMin, fatMax);
      population.add(x);
    }

    List<double>? bestFreeWeights;
    double bestScore = -double.infinity;
    double bestCal = 0, bestPro = 0, bestCarb = 0, bestFat = 0;

    for (int gen = 0; gen < generations; gen++) {
      List<MapEntry<List<double>, _EvalResult?>> scored = [];

      for (var freeInd in population) {
        List<double> fullWeights = allFoods.map((f) => fixedWeights[f.id] ?? 0.0).toList();
        int idx = 0;
        for(int i=0; i<allFoods.length; i++) {
          if(!fixedWeights.containsKey(allFoods[i].id)) fullWeights[i] = freeInd[idx++];
        }
        final res = _evaluate(fullWeights, allFoods, targets, preferences, settings, initialWeights);
        scored.add(MapEntry(freeInd, res));

        if (res != null && res.score > bestScore) {
          bestScore = res.score;
          bestFreeWeights = List.from(freeInd);
          bestCal = res.cal; bestPro = res.pro; bestCarb = res.carb; bestFat = res.fat;
        }
      }

      scored.sort((a, b) {
        if (a.value == null && b.value == null) return 0;
        if (a.value == null) return 1;
        if (b.value == null) return -1;
        return b.value!.score.compareTo(a.value!.score);
      });

      List<List<double>> newPop = [];
      int eliteCount = (populationSize * 0.15).round();
      for (int i = 0; i < eliteCount; i++) {
        newPop.add(List.from(scored[i].key));
      }

      while (newPop.length < populationSize) {
        List<double> p1 = _tournament(scored);
        List<double> p2 = _tournament(scored);

        List<double> child = [];
        for (int i = 0; i < n; i++) {
          double val = _random.nextBool() ? p1[i] : p2[i];
          if (_random.nextDouble() < 0.2) {
            val += (_random.nextDouble() - 0.5) * 60;
          }
          child.add(val);
        }
        _applyPOCS(child, calCoeffs, proCoeffs, carbCoeffs, fatCoeffs, calMin, calMax, proMin, proMax, carbMin, carbMax, fatMin, fatMax);
        newPop.add(child);
      }
      population = newPop;
    }

    if (bestFreeWeights == null) {
      if (_lastConstraintFailed != null) {
        lastErrorMessage = 'לא ניתן לאזן את הארוחה: חריגה ב-$_lastConstraintFailed.';
      } else {
        lastErrorMessage = 'לא נמצא שילוב חוקי שעומד ביעדים.';
      }
      return null;
    }

    Map<int, double> finalWeights = Map.from(fixedWeights);
    int idx = 0;
    for (int j = 0; j < allFoods.length; j++) {
      if (!fixedWeights.containsKey(allFoods[j].id)) {
        if (bestFreeWeights[idx] > 0.5) {
          finalWeights[allFoods[j].id!] = bestFreeWeights[idx];
        }
        idx++;
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

  static void _applyPOCS(List<double> x, List<double> calC, List<double> proC, List<double> carbC, List<double> fatC,
      double calMin, double calMax, double proMin, double proMax, double carbMin, double carbMax, double fatMin, double fatMax) {
    for (int iter = 0; iter < 100; iter++) {
      double currCal = _dot(calC, x);
      if (currCal < calMin) _project(x, calC, calMin);
      else if (currCal > calMax) _project(x, calC, calMax);

      double currPro = _dot(proC, x);
      if (currPro < proMin) _project(x, proC, proMin);
      else if (currPro > proMax) _project(x, proC, proMax);

      double currCarb = _dot(carbC, x);
      if (currCarb < carbMin) _project(x, carbC, carbMin);
      else if (currCarb > carbMax) _project(x, carbC, carbMax);

      double currFat = _dot(fatC, x);
      if (currFat < fatMin) _project(x, fatC, fatMin);
      else if (currFat > fatMax) _project(x, fatC, fatMax);

      for (int i = 0; i < x.length; i++) {
        if (x[i] < 0) x[i] = 0;
      }
    }
  }

  static double _dot(List<double> a, List<double> b) {
    double sum = 0;
    for (int i = 0; i < a.length; i++) sum += a[i] * b[i];
    return sum;
  }

  static void _project(List<double> x, List<double> a, double b) {
    double currentVal = _dot(a, x);
    double diff = b - currentVal;
    double normSq = _dot(a, a);
    if (normSq == 0) return;
    double alpha = diff / normSq;
    for (int i = 0; i < x.length; i++) {
      x[i] += alpha * a[i];
    }
  }

  static List<double> _tournament(List<MapEntry<List<double>, _EvalResult?>> scored) {
    List<double>? best;
    double bestScore = -double.infinity;
    for (int i = 0; i < 3; i++) {
      var entry = scored[_random.nextInt(scored.length)];
      double s = entry.value?.score ?? -double.infinity;
      if (s > bestScore) {
        bestScore = s;
        best = entry.key;
      }
    }
    return best ?? scored.first.key;
  }

  static OptimizationResult? adjustWeight({
    required List<Food> selectedFoods,
    required List<double> targets,
    required List<int> preferences,
    required Map<String, dynamic> settings,
    required Map<int, double> lockedWeights,
    required Map<int, double> currentWeights,
    required int adjustedFoodId,
    required double changeAmount,
  }) {
    double newTargetWeight = (currentWeights[adjustedFoodId] ?? 0) + changeAmount;
    newTargetWeight = newTargetWeight.clamp(0, 2000);

    Map<int, double> fixed = Map.from(lockedWeights);
    fixed[adjustedFoodId] = newTargetWeight;

    List<int> newPrefs = List.from(preferences);
    int idx = selectedFoods.indexWhere((f) => f.id == adjustedFoodId);
    if (idx != -1) {
      newPrefs[idx] = 100;
    }

    return optimizeWithFixed(
      allFoods: selectedFoods,
      fixedWeights: fixed,
      targets: targets,
      preferences: newPrefs,
      settings: settings,
      initialWeights: currentWeights,
    );
  }

  static _EvalResult? _evaluate(List<double> weights, List<Food> foods, List<double> targets, List<int> prefs, Map<String, dynamic> settings, [Map<int, double>? initialWeights]) {
    double cal = 0, pro = 0, carb = 0, fat = 0;

    for (int i = 0; i < foods.length; i++) {
      double w = weights[i];
      if (w < -0.1) {
        _lastConstraintFailed = 'משקל שלילי';
        return null;
      }
      w = max(0.0, w);
      cal += foods[i].caloriesPer100g / 100 * w;
      pro += foods[i].proteinPer100g / 100 * w;
      carb += foods[i].carbsPer100g / 100 * w;
      fat += foods[i].fatPer100g / 100 * w;
    }

    double tCal = targets[0], tPro = targets[1], tCarb = targets[2], tFat = targets[3];

    double calMin = 0, calMax = double.infinity;
    if (settings['cal_mode'] == 'down') { calMin = tCal * (1 - (settings['cal_pct'] ?? 10.0)/100); calMax = tCal; }
    else if (settings['cal_mode'] == 'up') { calMin = tCal; calMax = tCal * (1 + (settings['cal_pct'] ?? 10.0)/100); }
    else if (settings['cal_mode'] == 'both') { calMin = tCal * (1 - (settings['cal_pct'] ?? 10.0)/100); calMax = tCal * (1 + (settings['cal_pct'] ?? 10.0)/100); }

    double proMin = 0, proMax = double.infinity;
    if (settings['pro_mode'] == 'down') { proMin = tPro * (1 - (settings['pro_pct'] ?? 10.0)/100); proMax = tPro; }
    else if (settings['pro_mode'] == 'up') { proMin = tPro; proMax = tPro * (1 + (settings['pro_pct'] ?? 10.0)/100); }
    else if (settings['pro_mode'] == 'both') { proMin = tPro * (1 - (settings['pro_pct'] ?? 10.0)/100); proMax = tPro * (1 + (settings['pro_pct'] ?? 10.0)/100); }

    double carbMin = 0, carbMax = double.infinity;
    if (settings['carb_mode'] == 'down') { carbMin = tCarb * (1 - (settings['carb_pct'] ?? 10.0)/100); carbMax = tCarb; }
    else if (settings['carb_mode'] == 'up') { carbMin = tCarb; carbMax = tCarb * (1 + (settings['carb_pct'] ?? 10.0)/100); }
    else if (settings['carb_mode'] == 'both') { carbMin = tCarb * (1 - (settings['carb_pct'] ?? 10.0)/100); carbMax = tCarb * (1 + (settings['carb_pct'] ?? 10.0)/100); }

    double fatMin = 0, fatMax = double.infinity;
    if (settings['fat_mode'] == 'down') { fatMin = tFat * (1 - (settings['fat_pct'] ?? 10.0)/100); fatMax = tFat; }
    else if (settings['fat_mode'] == 'up') { fatMin = tFat; fatMax = tFat * (1 + (settings['fat_pct'] ?? 10.0)/100); }
    else if (settings['fat_mode'] == 'both') { fatMin = tFat * (1 - (settings['fat_pct'] ?? 10.0)/100); fatMax = tFat * (1 + (settings['fat_pct'] ?? 10.0)/100); }

    if (cal < calMin - 0.5) { _lastConstraintFailed = 'קלוריות (מתחת למינימום)'; return null; }
    if (cal > calMax + 0.5) { _lastConstraintFailed = 'קלוריות (מעל למקסימום)'; return null; }
    if (pro < proMin - 0.5) { _lastConstraintFailed = 'חלבון (מתחת למינימום)'; return null; }
    if (pro > proMax + 0.5) { _lastConstraintFailed = 'חלבון (מעל למקסימום)'; return null; }
    if (carb < carbMin - 0.5) { _lastConstraintFailed = 'פחמימות (מתחת למינימום)'; return null; }
    if (carb > carbMax + 0.5) { _lastConstraintFailed = 'פחמימות (מעל למקסימום)'; return null; }
    if (fat < fatMin - 0.5) { _lastConstraintFailed = 'שומן (מתחת למינימום)'; return null; }
    if (fat > fatMax + 0.5) { _lastConstraintFailed = 'שומן (מעל למקסימום)'; return null; }

    double preferenceScore = 0;
    for (int i = 0; i < foods.length; i++) {
      preferenceScore += weights[i] * prefs[i];
    }

    double efficiencyScore = 0;
    for (int i = 0; i < foods.length; i++) {
      efficiencyScore += weights[i] * foods[i].proteinPer100g * 0.1;
      efficiencyScore += weights[i] * foods[i].carbsPer100g * 0.1;
    }

    double continuityPenalty = 0;
    if (initialWeights != null) {
      for (int i = 0; i < foods.length; i++) {
        int foodId = foods[i].id!;
        if (initialWeights.containsKey(foodId)) {
          double diff = (weights[i] - initialWeights[foodId]!).abs();
          continuityPenalty += diff * 10.0;
        }
      }
    }

    return _EvalResult(preferenceScore + efficiencyScore - continuityPenalty, cal, pro, carb, fat);
  }
}

class _EvalResult {
  final double score;
  final double cal, pro, carb, fat;
  _EvalResult(this.score, this.cal, this.pro, this.carb, this.fat);
}
