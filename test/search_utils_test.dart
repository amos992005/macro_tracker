import 'package:flutter_test/flutter_test.dart';
import 'package:macro_tracker/core/search_utils.dart';

void main() {
  group('SearchUtils Comprehensive Tests', () {

    // --- 1. בדיקות התאמה בסיסיות (Exact & Case Insensitive) ---
    test('התאמה מדויקת בעברית', () {
      expect(SearchUtils.matches('חלב 3%', 'חלב'), isTrue);
      expect(SearchUtils.score('חלב 3%', 'חלב'), greaterThan(100));
    });

    test('התאמה מדויקת באנגלית (Case Insensitive)', () {
      expect(SearchUtils.matches('GO חלבון whey', 'go'), isTrue);
      expect(SearchUtils.matches('GO חלבון whey', 'GO'), isTrue);
      expect(SearchUtils.matches('GO חלבון whey', 'Go'), isTrue);
    });

    // --- 2. בדיקות תעתיק (עברית לאנגלית) ---
    test('חיפוש "גו" מוצא "GO"', () {
      // "גו" יכול להפוך ל-"go", "gv", "gu". "GO" הוא "go".
      expect(SearchUtils.matches('GO חלבון whey', 'גו'), isTrue);
    });

    test('חיפוש "ווי" מוצא "whey"', () {
      // "ווי" יכול להפוך ל-"wy", "vvy", "voy" וכו'.
      expect(SearchUtils.matches('אבקת whey חלבון', 'ווי'), isTrue);
    });

    // --- 3. בדיקות שגיאות כתיב (Levenshtein) ---
    test('חיפוש עם שגיאת כתיב קלה (חלכ במקום חלב)', () {
      expect(SearchUtils.matches('חלב 3%', 'חלכ'), isTrue);
    });

    test('חיפוש עם אות חסרה (עו במקום עוף)', () {
      expect(SearchUtils.matches('חזה עוף', 'עו'), isTrue);
    });

    // --- 4. בדיקות שורשים ומילים דומות (Stemming & N-Grams) ---
    test('חיפוש "פריכיות" מוצא "פריכונים"', () {
      expect(SearchUtils.matches('פריכונים מחיטה מלאה', 'פריכיות'), isTrue);
    });

    test('חיפוש "שוקולד" מוצא "שוקולדים"', () {
      expect(SearchUtils.matches('שוקולדים מרירים', 'שוקולד'), isTrue);
    });

    // --- 5. בדיקות מילים נרדפות (Synonyms) ---
    test('חיפוש "משקה" מוצא "שייק" (מילון נרדפות)', () {
      expect(SearchUtils.matches('שייק בננה וחלבון', 'משקה'), isTrue);
    });

    test('חיפוש "אבקה" מוצא "חלבון" (מילון נרדפות)', () {
      expect(SearchUtils.matches('חלבון מי גבינה', 'אבקה'), isTrue);
    });

    // --- 6. בדיקות חיפוש מרובה מילים ---
    test('חיפוש "משקה חלבון" מוצא "GO חלבון"', () {
      // "משקה" מתורגם/מתרחב ל-GO, "חלבון" הוא חלבון.
      expect(SearchUtils.matches('GO חלבון whey', 'משקה חלבון'), isTrue);
    });

    // --- 7. בדיקות מיון ורלוונטיות (Scoring & Ranking) ---
    test('מוצר שמתחיל במילה יקבל ציון גבוה ממוצר שמכיל אותה באמצע', () {
      final score1 = SearchUtils.score('חלב 3%', 'חלב');
      final score2 = SearchUtils.score('שוקולד חלב', 'חלב');

      expect(score1, greaterThan(score2), reason: 'התאמה בתחילית שווה יותר מאשר התאמה באמצע');
    });

    test('מוצר שמכיל את כל מילות החיפוש יקבל ציון גבוה מכזה שמכיל רק חלק', () {
      final score1 = SearchUtils.score('משקה חלבון שוקו', 'משקה חלבון');
      final score2 = SearchUtils.score('אבקת חלבון', 'משקה חלבון');

      expect(score1, greaterThan(score2), reason: 'התאמה של כל המילים צריכה לנצח');
    });

    test('התאמה מדויקת של מילה שלמה מנצחת התאמה חלקית', () {
      final score1 = SearchUtils.score('חזה עוף', 'עוף');
      final score2 = SearchUtils.score('עוגיית שוקולד', 'עוף'); // מתאים רק בגלל N-grams / קרבה

      expect(score1, greaterThan(score2));
    });

    // --- 8. בדיקות שליליות (לא אמור למצוא) ---
    test('חיפוש לא קשור לא מחזיר תוצאות', () {
      expect(SearchUtils.matches('חזה עוף', 'שוקולד'), isFalse);
      expect(SearchUtils.matches('חזה עוף', 'פיצה'), isFalse);
    });

    test('מילה קצרה מדי לא תגרום ליותר מדי רעש', () {
      // "א" מופיע בהמון מילים, אבל אם המוצר לא מתחיל ב-א, הוא לא אמור להתאים בצורה חזקה
      final score = SearchUtils.score('חלב', 'א');
      expect(score, lessThan(1.0));
    });
  });
}