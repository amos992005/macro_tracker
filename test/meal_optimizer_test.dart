import 'package:flutter_test/flutter_test.dart';
import 'package:macro_tracker/core/meal_optimizer.dart';
import 'package:macro_tracker/data/models/food.dart';

void main() {
  group('MealOptimizer Comprehensive & Smart Tests', () {
    // חוקי הברזל הרגילים שלך
    final standardSettings = {
      'cal_mode': 'down', 'cal_pct': 10.0,
      'pro_mode': 'up', 'pro_pct': 10.0,
      'carb_mode': 'both', 'carb_pct': 10.0,
      'fat_mode': 'free', 'fat_pct': 0.0,
    };

    // חוקים נוקשים (סטייה של עד 3%)
    final strictSettings = {
      'cal_mode': 'both', 'cal_pct': 3.0,
      'pro_mode': 'up', 'pro_pct': 3.0,
      'carb_mode': 'both', 'carb_pct': 3.0,
      'fat_mode': 'free', 'fat_pct': 0.0,
    };

    // המוצרים לבדיקה
    final schnitzel = Food(id: 1, name: 'שניצל', caloriesPer100g: 230, proteinPer100g: 22, carbsPer100g: 17, fatPer100g: 10);
    final ptitim = Food(id: 2, name: 'פתיתים', caloriesPer100g: 135, proteinPer100g: 4, carbsPer100g: 25, fatPer100g: 2);
    final hummus = Food(id: 3, name: 'חומוס', caloriesPer100g: 186, proteinPer100g: 8, carbsPer100g: 12, fatPer100g: 11);
    final pita = Food(id: 4, name: 'פיתה', caloriesPer100g: 260, proteinPer100g: 8, carbsPer100g: 50, fatPer100g: 2);
    final cornflakes = Food(id: 5, name: 'קורנפלקס', caloriesPer100g: 380, proteinPer100g: 7, carbsPer100g: 84, fatPer100g: 1);
    final chicken = Food(id: 6, name: 'חזה עוף', caloriesPer100g: 165, proteinPer100g: 31, carbsPer100g: 0, fatPer100g: 3.6);

    test('1. 5 מוצרים - יעילות פחמימה (פיתה > חומוס)', () {
      final result = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel, ptitim, hummus, pita, cornflakes],
        targets: [1916, 135, 171.9, 72.5],
        preferences: [5, 4, 3, 2, 1],
        settings: standardSettings,
      );

      expect(result, isNotNull, reason: 'האלגוריתם אמור למצוא פתרון');
      double pitaWeight = result!.weights[4] ?? 0;
      double ptitimWeight = result.weights[2] ?? 0;
      double hummusWeight = result.weights[3] ?? 0;

      // הפיתה והפתיתים צריכים להיות דומיננטיים יותר מהחומוס להשגת פחמימות
      expect(pitaWeight + ptitimWeight, greaterThan(hummusWeight), reason: 'פיתה ופתיתים עדיפים על חומוס לפחמימות');
    });

    test('2. 5 מוצרים - שמירה על פרופורציות בשינוי (מינוס פיתה)', () {
      final initial = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel, ptitim, hummus, pita, cornflakes],
        targets: [1916, 135, 171.9, 72.5],
        preferences: [5, 4, 3, 2, 1],
        settings: standardSettings,
      );
      expect(initial, isNotNull);

      final adjusted = MealOptimizer.optimizeWithFixed(
        allFoods: [schnitzel, ptitim, hummus, pita, cornflakes],
        fixedWeights: {4: (initial!.weights[4] ?? 0) - 10.0}, // הורדת 10 גרם פיתה
        targets: [1916, 135, 171.9, 72.5],
        preferences: [5, 4, 3, 2, 1],
        settings: standardSettings,
      );

      if (adjusted != null) {
        double newPtitim = adjusted.weights[2] ?? 0;
        double oldPtitim = initial.weights[2] ?? 0;
        expect((newPtitim - oldPtitim).abs(), lessThan(150.0), reason: 'הפתיתים לא אמורים לזנק או לקרוס');
      }
    });

    test('3. 4 מוצרים - חוקי ברזל נוקשים (3% סטייה)', () {
      final result = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel, chicken, pita, cornflakes],
        targets: [1000, 90, 100, 20],
        preferences: [5, 5, 5, 5],
        settings: strictSettings,
      );

      expect(result, isNotNull, reason: 'אמור למצוא פתרון עם סטייה של עד 3%');
      expect(result!.totalProtein, closeTo(90, 3.0), reason: 'חלבון חייב להיות בסביבות 90 (עד 3%)');
    });

    test('4. 3 מוצרים - שינוי חיובי (הוספת שניצל)', () {
      final initial = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel, ptitim, hummus],
        targets: [1500, 90, 150, 40],
        preferences: [5, 4, 3],
        settings: standardSettings,
      );
      expect(initial, isNotNull);

      final adjusted = MealOptimizer.optimizeWithFixed(
        allFoods: [schnitzel, ptitim, hummus],
        fixedWeights: {1: (initial!.weights[1] ?? 0) + 15.0}, // הוספת 15 גרם שניצל
        targets: [1500, 90, 150, 40],
        preferences: [5, 4, 3],
        settings: standardSettings,
      );

      if (adjusted != null) {
        expect(adjusted.weights[1], greaterThan(initial.weights[1] ?? 0), reason: 'השניצל אמור לגדול');
      }
    });

    test('5. 2 מוצרים - יעדים קלים', () {
      final result = MealOptimizer.findOptimalWeights(
        selectedFoods: [chicken, pita],
        targets: [800, 70, 80, 20],
        preferences: [5, 4],
        settings: standardSettings,
      );
      expect(result, isNotNull);
      expect(result!.totalProtein, greaterThanOrEqualTo(70 * 0.99), reason: 'חלבון חייב להיות לפחות 70');
    });

    test('6. מקרה בלתי אפשרי - יותר מדי חלבון, מעט מדי קלוריות', () {
      final result = MealOptimizer.findOptimalWeights(
        selectedFoods: [ptitim, hummus, cornflakes],
        targets: [100, 100, 10, 10], // דורש 100 חלבון ב-100 קלוריות (בלתי אפשרי)
        preferences: [1, 1, 1],
        settings: standardSettings,
      );
      expect(result, isNull, reason: 'האלגוריתם אמור להבין שאין פתרון');
    });

    test('7. שמירה על חוקי הברזל (פחמימות לא חורגות ב-10%)', () {
      final result = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel, ptitim, pita, hummus],
        targets: [1600, 120, 150, 40],
        preferences: [5, 4, 3, 2],
        settings: standardSettings,
      );
      expect(result, isNotNull);
      expect(result!.totalCarbs, lessThanOrEqualTo(165.5), reason: 'פחמימות לא אמורות לחרוג ביותר מ-10% (165.5)');
    });

    test('8. שינוי קליני - הורדת 5 גרם לא הורסת את הארוחה', () {
      final initial = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel, pita, hummus, ptitim],
        targets: [2000, 130, 180, 60],
        preferences: [5, 5, 5, 5],
        settings: standardSettings,
      );

      if (initial != null && initial.weights[2] != null) {
        final adjusted = MealOptimizer.optimizeWithFixed(
          allFoods: [schnitzel, pita, hummus, ptitim],
          fixedWeights: {2: initial.weights[2]! - 5.0}, // הורדת 5 גרם חומוס
          targets: [2000, 130, 180, 60],
          preferences: [5, 5, 5, 5],
          settings: standardSettings,
        );

        if (adjusted != null) {
          expect(adjusted.totalCalories, lessThanOrEqualTo(2001.0), reason: 'הקלוריות לא אמורות לזנק');
        }
      }
    });

    test('9. נעילת מוצר מונעת ממנו להשתנות כשמשנים מוצר אחר', () {
      final initial = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel, ptitim, hummus],
        targets: [2000, 130, 180, 60],
        preferences: [5, 4, 3],
        settings: standardSettings,
      );
      expect(initial, isNotNull);

      final hummusWeight = initial!.weights[3] ?? 0;

      // נועל את החומוס ומוסיף 5 גרם לפתיתים
      final fixedWeights = {
        3: hummusWeight, // חומוס נעול
        2: (initial.weights[2] ?? 0) + 5.0, // פתיתים מוגדל ב-5
      };

      final adjusted = MealOptimizer.optimizeWithFixed(
        allFoods: [schnitzel, ptitim, hummus],
        fixedWeights: fixedWeights,
        targets: [2000, 130, 180, 60],
        preferences: [5, 4, 3],
        settings: standardSettings,
      );

      if (adjusted != null) {
        // החומוס נשאר בדיוק כפי שהיה (עד כדי שבריר גרם)
        expect(adjusted.weights[3], closeTo(hummusWeight, 0.1), reason: 'החומוס היה נעול, הוא לא אמור להשתנות');
        // הפתיתים באמת השתנו
        expect(adjusted.weights[2], closeTo((initial.weights[2] ?? 0) + 5.0, 0.1), reason: 'הפתיתים שונו ב-5 גרם');
      }
    });

    test('10. נעילת כל המוצרים (מקרה קיצון)', () {
      // מנסים לנעול את כל שלושת המוצרים על ערכים שלא מכסים את היעד
      final fixedWeights = {1: 100.0, 2: 100.0, 3: 100.0};

      final adjusted = MealOptimizer.optimizeWithFixed(
        allFoods: [schnitzel, ptitim, hummus],
        fixedWeights: fixedWeights,
        targets: [2000, 130, 180, 60], // יעד גבוה מדי למה שנעלנו
        preferences: [5, 4, 3],
        settings: standardSettings,
      );

      // האלגוריתם אמור להחזיר null כי אין מה לשנות, והיעד לא מושג
      expect(adjusted, isNull, reason: 'אם הכל נעול ואין מספיק אוכל, אין פתרון');
    });

    test('11. שינוי קליני - שמירה על פרופורציות (לא איפוס) כשמשנים מוצר', () {
      final initial = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel, ptitim, hummus],
        targets: [2000, 130, 180, 60],
        preferences: [5, 4, 3],
        settings: standardSettings,
      );
      expect(initial, isNotNull);

      final hummusWeight = initial!.weights[3] ?? 0;
      expect(hummusWeight, greaterThan(10.0));

      // מוסיפים 10 גרם לפתיתים, ומעבירים את המצב ההתחלתי כדי לשמור על רציפות
      Map<int, double> currentMealWeights = {};
      for (var id in [1, 2, 3]) {
        currentMealWeights[id] = initial.weights[id] ?? 0.0;
      }

      final adjusted = MealOptimizer.optimizeWithFixed(
        allFoods: [schnitzel, ptitim, hummus],
        fixedWeights: {2: (initial.weights[2] ?? 0) + 10.0},
        targets: [2000, 130, 180, 60],
        preferences: [5, 4, 3],
        settings: standardSettings,
        initialWeights: currentMealWeights, // מעבירים את המצב ההתחלתי
      );

      expect(adjusted, isNotNull);
      // החומוס לא צריך להתאפס, אלא פשוט לקטון או לגדול בהדרגה
      expect(adjusted!.weights[3] ?? 0, greaterThan(0.0), reason: 'החומוס לא אמור להתאפס לחלוטין');
    });

    test('12. מציאת פתרון בטווח התחתון של הקלוריות (עד 10% סטייה)', () {
      // יעדים אפשריים: 1500 קלוריות (מינימום 1350), 120 חלבון, 100 פחמימות
      final result = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel, chicken],
        targets: [1500, 120, 100, 50],
        preferences: [5, 4],
        settings: standardSettings,
      );

      expect(result, isNotNull, reason: 'אמור למצוא פתרון חוקי');
      // האלגוריתם אמור לנצל את הטווח התחתון (מינימום 1350 קלוריות)
      expect(result!.totalCalories, lessThanOrEqualTo(1500.0));
      expect(result.totalCalories, greaterThanOrEqualTo(1350.0));
    });

    test('13. שימוש בטווח התחתון של הקלוריות (סטייה של 10% למטה) עם שניצל בלבד', () {
      final result = MealOptimizer.findOptimalWeights(
        selectedFoods: [schnitzel],
        targets: [1500, 120, 100, 50],
        preferences: [5],
        settings: standardSettings,
      );

      expect(result, isNotNull, reason: 'אמור למצוא פתרון חוקי');
      // 600 גרם שניצל נותן 1380 קלוריות, שזה בטווח התחתון (1350-1500)
      expect(result!.totalCalories, closeTo(1380, 5.0));
    });
  });
}