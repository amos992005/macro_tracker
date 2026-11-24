import 'package:flutter_test/flutter_test.dart';
import 'package:macro_tracker/core/search_utils.dart';
import 'package:macro_tracker/data/models/food.dart';

void main() {
  group('SearchUtils v3 - Ambitious Tests', () {
    // מוצרים לדוגמה
    final matcha = Food(id: 1, name: 'מאצ\'ה', caloriesPer100g: 300, proteinPer100g: 5, carbsPer100g: 50, fatPer100g: 10);
    final dessert = Food(id: 2, name: 'מעדן שוקולד', caloriesPer100g: 150, proteinPer100g: 4, carbsPer100g: 20, fatPer100g: 5);
    final chicken = Food(id: 3, name: 'חזה עוף', caloriesPer100g: 165, proteinPer100g: 31, carbsPer100g: 0, fatPer100g: 3.6);
    final cornflakes = Food(id: 4, name: 'קורנפלקס אלופים', caloriesPer100g: 375, proteinPer100g: 7, carbsPer100g: 84, fatPer100g: 1);
    final goShake = Food(id: 5, name: 'GO חלבון whey', caloriesPer100g: 380, proteinPer100g: 80, carbsPer100g: 6, fatPer100g: 5);
    final favoriteFood = Food(id: 6, name: 'שוקולד מריר', caloriesPer100g: 500, proteinPer100g: 5, carbsPer100g: 50, fatPer100g: 30, isFavorite: true);

    final allFoods = [matcha, dessert, chicken, cornflakes, goShake, favoriteFood];

    // --- 1. העדפת התאמה מקורית (הבעיה של "מע") ---
    test('חיפוש "מע" מעדיף את "מעדן" על פני "מאצ\'ה" (התאמה מקורית)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'מע');
      expect(results.first.name, 'מעדן שוקולד'); // הודות להתאמה המדויקת של האותיות מ-ע
    });

    test('חיפוש "מע" לא מחזיר את "מאצ\'ה" במקום הראשון', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'מע');
      expect(results.first.name, isNot('מאצ\'ה'));
    });

    // --- 2. התאמה חלקית (Partial Match) ---
    test('חיפוש תחילית של מילה (חל -> חלב/חזה)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'חז');
      expect(results.first.name, 'חזה עוף');
    });

    test('חיפוש עם רווחים חסרים (קורן פלקס -> קורנפלקס)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'קורן פלקס');
      expect(results.first.name, 'קורנפלקס אלופים');
    });

    // --- 3. שגיאות כתיב (Fuzzy Matching) ---
    test('חיפוש עם שגיאת כתיב קלה (עווף -> עוף)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'עווף');
      expect(results.first.name, 'חזה עוף');
    });

    test('חיפוש עם אות חסרה (קרנפלקס -> קורנפלקס)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'קרנפלקס');
      expect(results.first.name, 'קורנפלקס אלופים');
    });

    // --- 4. תעתיקים (עברית <-> אנגלית) ---
    test('חיפוש גו מוצא GO', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'גו');
      expect(results.first.name, 'GO חלבון whey');
    });

    test('חיפוש GO מוצא GO', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'GO');
      expect(results.first.name, 'GO חלבון whey');
    });

    // --- 5. מילות נרדפות ---
    test('חיפוש משקה מוצא GO (מילון נרדפות)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'משקה');
      expect(results.any((f) => f.name == 'GO חלבון whey'), isTrue);
    });

    // --- 6. טיפול במספרים ---
    test('חיפוש עם מספרים (חלב 3%)', () {
      final milk = Food(id: 7, name: 'חלב 3%', caloriesPer100g: 60, proteinPer100g: 3, carbsPer100g: 4.5, fatPer100g: 3);
      final testFoods = [...allFoods, milk];
      final results = SearchUtils.filterAndSortFoods(testFoods, 'חלב 3%');
      expect(results.first.name, 'חלב 3%');
    });

    // --- 7. דירוג (Ranking) ---
    test('התאמה מדויקת של מילה שלמה מנצחת התאמה חלקית', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'חזה עוף');
      expect(results.first.name, 'חזה עוף');
    });

    test('מוצר עם שם קצר ומדויק מקבל עדיפות על שם ארוך', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'שוקולד');
      expect(results.first.name, 'שוקולד מריר'); // זה מועדף, אז הוא מנצח
    });

    // --- 8. מועדפים ---
    test('מועדפים תמיד מופיעים ראשונים (אם יש להם התאמה)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'מריר');
      expect(results.first.isFavorite, isTrue);
    });

    // --- 9. מקרי קצה ---
    test('חיפוש ריק מחזיר את כל המוצרים (עד 100)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, '');
      expect(results, isNotEmpty);
    });

    test('חיפוש שאין לו תוצאות בכלל מחזיר רשימה ריקה (פיצה)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'פיצה');
      expect(results, isEmpty); // לא אמורים להיות מוצרים רלוונטיים בכלל
    });

    // --- 10. אתגר: התאמה של שתי מילים לא קשורות ---
    test('חיפוש "קורנפלקס עוף" - לא אמור להחזיר כלום (אין מוצר כזה)', () {
      final results = SearchUtils.filterAndSortFoods(allFoods, 'קורנפלקס עוף');
      expect(results, isEmpty, reason: 'אין מוצר שמכיל גם קורנפלקס וגם עוף');
    });

    test('מאכל בסוף מאגר של 10,000 רשומות נמצא ראשון בחיפוש מדויק', () {
      final foods = List<Food>.generate(
        9999,
        (index) => Food(
          id: index + 1,
          name: 'מאכל בדיקה $index',
          caloriesPer100g: 100,
          proteinPer100g: 10,
          carbsPer100g: 10,
          fatPer100g: 5,
        ),
      )..add(
          Food(
            id: 10000,
            name: 'אבקת חלבון שוקולד',
            caloriesPer100g: 400,
            proteinPer100g: 70,
            carbsPer100g: 15,
            fatPer100g: 8,
          ),
        );

      final results = SearchUtils.filterAndSortFoods(foods, 'אבקת חלבון שוקולד');

      expect(results, isNotEmpty);
      expect(results.first.id, 10000);
      expect(results.first.name, 'אבקת חלבון שוקולד');
    });

    test('ניקוד, מקפים, פיסוק ואותיות סופיות מנורמלים בלי תעתיק פונטי', () {
      expect(SearchUtils.normalize('אָבְקַת-חלבון, שוקולד!'), 'אבקת חלבונ שוקולד');
      expect(SearchUtils.normalize('ךםןףץ'), 'כמנפצ');
      expect(SearchUtils.normalize('קורן'), 'קורנ');
      expect(SearchUtils.normalize('חלבון'), 'חלבונ');
    });

    test('חיפוש שתי מילים מוצא גם שם מאכל שמחבר אותן', () {
      final compoundFood = Food(
        id: 10,
        name: 'חזהעוף',
        caloriesPer100g: 165,
        proteinPer100g: 31,
        carbsPer100g: 0,
        fatPer100g: 3.6,
      );
      final results = SearchUtils.filterAndSortFoods([compoundFood], 'חזה עוף');

      expect(results, isNotEmpty);
      expect(results.first.id, compoundFood.id);
    });

    test('התאמה מלאה של כל המילים מדורגת לפני התאמה חלקית', () {
      final exactAllWords = Food(
        id: 8,
        name: 'אבקת חלבון שוקולד',
        caloriesPer100g: 400,
        proteinPer100g: 70,
        carbsPer100g: 15,
        fatPer100g: 8,
      );
      final partialWords = Food(
        id: 9,
        name: 'אבקת חלבון וניל',
        caloriesPer100g: 400,
        proteinPer100g: 70,
        carbsPer100g: 15,
        fatPer100g: 8,
      );
      final results = SearchUtils.filterAndSortFoods(
        [partialWords, exactAllWords],
        'אבקת חלבון שוקולד',
      );

      expect(results.first.id, exactAllWords.id);
      expect(results.any((food) => food.id == partialWords.id), isTrue);
    });
  });
}