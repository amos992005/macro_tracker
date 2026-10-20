import 'dart:math' as math;
import '../data/models/food.dart';

class _FoodSearchData {
  final String rawOriginal;
  final List<String> tokens;
  final String normNoSpaces;
  final String normOriginal;
  _FoodSearchData(this.rawOriginal, this.tokens, this.normNoSpaces, this.normOriginal);
}

class SearchUtils {
  static const Map<String, List<String>> _synonyms = {
    'משקה': ['שתייה', 'שייק', 'אבקה', 'נוזל', 'go', 'גו', 'ווי'],
    'חלבון': ['פרוטאין', 'אבקה', 'whey', 'וויי', 'גיינר'],
    'פחמימה': ['פחמימות', 'קרב', 'סוכר', 'פסטה', 'אורז', 'לחם', 'פתיתים', 'פריכיות'],
    'שומן': ['שומנים', 'שמן', 'אבוקדו', 'אגוז', 'חמאה'],
    'בשר': ['עוף', 'בקר', 'הודו', 'דג', 'טונה', 'שניצל'],
    'חלב': ['חלבי', 'גבינה', 'יוגורט', 'קוטג', 'שמנת'],
    'פירות': ['תפוח', 'בננה', 'תפוז', 'ענבים'],
    'ירקות': ['עגבניה', 'מלפפון', 'חסה', 'גזר'],
    'אבקה': ['חלבון', 'פרוטאין', 'whey'],
    'ווי': ['whey', 'חלבון', 'אבקה'],
    'שייק': ['משקה', 'אבקה'],
    'פרוטאין': ['חלבון', 'אבקה'],
  };

  static const Map<String, List<String>> _hebrewOptions = {
    'א': ['a', 'e'], 'ב': ['b', 'v'], 'ג': ['g'], 'ד': ['d'], 'ה': ['h'],
    'ו': ['v', 'o', 'u'], 'ז': ['z'], 'ח': ['h', 'ch'], 'ט': ['t'], 'י': ['i', 'y'],
    'כ': ['k', 'ch'], 'ך': ['k', 'ch'], 'ל': ['l'], 'מ': ['m'], 'ם': ['m'],
    'נ': ['n'], 'ן': ['n'], 'ס': ['s'], 'ע': ['a', 'e'], 'פ': ['p', 'f'],
    'ף': ['p', 'f'], 'צ': ['ts', 'tz'], 'ץ': ['ts', 'tz'], 'ק': ['k', 'q'],
    'ר': ['r'], 'ש': ['sh', 's'], 'ת': ['t'],
  };

  static const List<String> _stopWords = ['ו', 'עם', 'של', 'על', 'ב', 'ל', 'מ', 'ה', 'ש', 'את', 'כי', 'או'];

  static final Map<String, String> _normalizeCache = {};
  static final Map<String, List<String>> _variantCache = {};
  static final Map<String, _FoodSearchData> _foodDataCache = {};

  static String normalize(String text) {
    if (text.isEmpty) return '';
    if (_normalizeCache.containsKey(text)) return _normalizeCache[text]!;

    String lower = text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    StringBuffer sb = StringBuffer();
    for (int i = 0; i < lower.length; i++) {
      String c = lower[i];
      if (_hebrewOptions.containsKey(c)) {
        sb.write(_hebrewOptions[c]!.first);
      } else {
        sb.write(c);
      }
    }
    String result = sb.toString();
    _normalizeCache[text] = result;
    return result;
  }

  static List<String> _getRawTokens(String text) {
    String lower = text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    List<String> tokens = lower.split(' ').where((t) => t.isNotEmpty).toList();
    return tokens.where((t) => !_stopWords.contains(t) && t.length > 1).toList();
  }

  static List<String> _getVariants(String text) {
    if (text.isEmpty) return [''];
    if (_variantCache.containsKey(text)) return _variantCache[text]!;

    String lower = text.toLowerCase().trim();
    bool hasHebrew = lower.codeUnits.any((c) => c >= 0x0590 && c <= 0x05FF);

    if (!hasHebrew) {
      _variantCache[text] = [lower];
      return [lower];
    }

    Set<String> stems = {lower};
    const suffixes = ['יות', 'ים', 'ות', 'נים', 'ית', 'ה'];
    for (var suffix in suffixes) {
      if (lower.endsWith(suffix) && lower.length - suffix.length >= 3) {
        stems.add(lower.substring(0, lower.length - suffix.length));
      }
    }

    Set<String> results = {};
    for (var stem in stems) {
      if (stem.length > 6) {
        results.add(normalize(stem));
        continue;
      }

      List<String> current = [''];
      for (int i = 0; i < stem.length; i++) {
        String c = stem[i];
        List<String> opts = _hebrewOptions[c] ?? [c];
        List<String> next = [];
        for (var r in current) {
          for (var opt in opts) {
            next.add(r + opt);
          }
        }
        current = next;
      }
      results.addAll(current);
    }

    List<String> finalList = results.toList();
    _variantCache[text] = finalList;
    return finalList;
  }

  static _FoodSearchData _getFoodData(Food food) {
    if (_foodDataCache.containsKey(food.name)) return _foodDataCache[food.name]!;

    final rawTokens = _getRawTokens(food.name);
    final normTokens = rawTokens.map((t) => normalize(t)).toList();
    final normNoSpaces = normalize(food.name).replaceAll(' ', '');
    final normOriginal = normalize(food.name);

    final data = _FoodSearchData(food.name, normTokens, normNoSpaces, normOriginal);
    _foodDataCache[food.name] = data;
    return data;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    if ((a.length - b.length).abs() > 3) return 100;

    List<int> prev = List.generate(b.length + 1, (i) => i);
    for (int i = 1; i <= a.length; i++) {
      List<int> curr = [i];
      for (int j = 1; j <= b.length; j++) {
        int cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr.add([
          curr[j - 1] + 1,
          prev[j] + 1,
          prev[j - 1] + cost,
        ].reduce(math.min));
      }
      prev = curr;
    }
    return prev[b.length];
  }

  static double _scoreProduct(Food food, _FoodSearchData foodData, List<String> rawQueryTokens, String normQueryNoSpaces, String rawQuery) {
    double score = 0;
    String lowerRawQuery = rawQuery.toLowerCase().trim();
    String lowerRawProduct = foodData.rawOriginal.toLowerCase();

    // 1. התאמה אותנטית (טקסט מקורי, ללא תעתיק)
    if (lowerRawProduct == lowerRawQuery) {
      score += 30000;
    } else if (lowerRawProduct.startsWith(lowerRawQuery)) {
      score += 15000;
    } else if (lowerRawProduct.contains(lowerRawQuery)) {
      score += 5000;
    }

    // 2. התאמה של כל המשפט המנורמל
    if (foodData.normNoSpaces == normQueryNoSpaces) {
      score += 20000;
    } else if (foodData.normNoSpaces.contains(normQueryNoSpaces)) {
      score += 8000;
    }

    // 3. ניקוד לפי כיסוי מילים
    int matchedTokens = 0;
    for (var rawQToken in rawQueryTokens) {
      String qToken = normalize(rawQToken);
      double bestTokenScore = 0;

      for (var fToken in foodData.tokens) {
        if (fToken == qToken) { bestTokenScore = math.max(bestTokenScore, 1000); }
        else if (fToken.startsWith(qToken)) { bestTokenScore = math.max(bestTokenScore, 500); }
        else if (fToken.contains(qToken)) { bestTokenScore = math.max(bestTokenScore, 200); }
        else if (qToken.length >= 2 && (fToken.length - qToken.length).abs() <= 2) {
          int dist = _levenshtein(qToken, fToken);
          if (dist <= 2) { bestTokenScore = math.max(bestTokenScore, 100.0 / dist); }
        }
      }

      // בדיקת מילים נרדפות
      if (bestTokenScore == 0) {
        List<String>? syns = _synonyms[rawQToken] ?? _synonyms[normalize(rawQToken)];
        if (syns != null) {
          for (var syn in syns) {
            String normSyn = normalize(syn);
            for (var fToken in foodData.tokens) {
              if (fToken == normSyn) { bestTokenScore = math.max(bestTokenScore, 800); break; }
              if (fToken.contains(normSyn)) { bestTokenScore = math.max(bestTokenScore, 300); break; }
            }
          }
        }
      }

      if (bestTokenScore > 0) matchedTokens++;
      score += bestTokenScore;
    }

    if (matchedTokens == 0) return 0;

    // ==== תיקון 1: דרישת "כל המילים" (AND semantics) ====
    // אם השאילתה מכילה יותר ממילה משמעותית אחת, נדרוש שכולן יתאימו.
    // יוצא מן הכלל: אם כל השאילתה מופיעה כתת-מחרוזת בטקסט המקורי
    // (למשל "קורנפלקס עוף טרי" שמכיל "קורנפלקס עוף"), לא נדרוש את כלל ה-AND.
    bool fullRawMatch = lowerRawProduct.contains(lowerRawQuery);
    if (!fullRawMatch &&
        rawQueryTokens.length > 1 &&
        matchedTokens < rawQueryTokens.length) {
      return 0;
    }
    // ====================================================

    if (matchedTokens == rawQueryTokens.length && rawQueryTokens.isNotEmpty) {
      score *= 1.5;
    }

    if (rawQueryTokens.isNotEmpty) {
      String firstToken = rawQueryTokens.first.toLowerCase();
      if (lowerRawProduct.startsWith(firstToken)) {
        score += 2000;
      }
    }

    score -= (lowerRawProduct.length * 5.0);

    return score;
  }

  static List<Food> filterAndSortFoods(List<Food> foods, String query, {bool onlyFavorites = false}) {
    if (query.trim().isEmpty) {
      var list = onlyFavorites ? foods.where((f) => f.isFavorite).toList() : foods;
      return list.take(100).toList();
    }

    final rawQueryTokens = _getRawTokens(query);
    final normQueryNoSpaces = normalize(query).replaceAll(' ', '');

    if (rawQueryTokens.isEmpty) {
      var list = onlyFavorites ? foods.where((f) => f.isFavorite).toList() : foods;
      return list.take(100).toList();
    }

    final queryVariantsList = <String>[];
    final querySynonymsList = <String>[];

    for (var rawQToken in rawQueryTokens) {
      queryVariantsList.addAll(_getVariants(rawQToken));
      final syns = _synonyms[rawQToken] ?? _synonyms[normalize(rawQToken)];
      if (syns != null) {
        for (var syn in syns) {
          querySynonymsList.addAll(_getVariants(syn));
        }
      }
    }

    final candidates = <Food>[];
    for (var food in foods) {
      if (onlyFavorites && !food.isFavorite) continue;

      final foodData = _getFoodData(food);
      bool isCandidate = false;

      // 1. התאמה מקורית (טקסט גולמי)
      if (foodData.rawOriginal.toLowerCase().contains(query.toLowerCase().trim())) {
        isCandidate = true;
      }

      // 2. התאמה מנורמלת
      if (!isCandidate && foodData.normNoSpaces.contains(normQueryNoSpaces)) {
        isCandidate = true;
      }

      // 3. וריאציות
      if (!isCandidate) {
        for (var variant in queryVariantsList) {
          if (variant.length >= 2 && foodData.normOriginal.contains(variant)) {
            isCandidate = true;
            break;
          }
        }
      }

      // 4. מילים נרדפות
      if (!isCandidate) {
        for (var syn in querySynonymsList) {
          if (syn.length >= 2 && foodData.normOriginal.contains(syn)) {
            isCandidate = true;
            break;
          }
        }
      }

      // 5. מרחק Levenshtein
      if (!isCandidate) {
        for (var rawQToken in rawQueryTokens) {
          String qToken = normalize(rawQToken);
          if (qToken.length < 2) continue;

          for (var fToken in foodData.tokens) {
            if (fToken.length < 2) continue;
            if ((fToken.length - qToken.length).abs() <= 2) {
              if (_levenshtein(qToken, fToken) <= 2) {
                isCandidate = true;
                break;
              }
            }
          }
          if (isCandidate) break;
        }
      }

      if (isCandidate) candidates.add(food);
      if (candidates.length >= 500) break;
    }

    final scored = candidates.map((f) {
      final foodData = _getFoodData(f);
      double score = _scoreProduct(f, foodData, rawQueryTokens, normQueryNoSpaces, query);

      // ==== תיקון 2: בונוס מועדפים רק אם יש ניקוד חיובי ====
      // כדי שמוצר מועדף שלא באמת מתאים לא "ינצח" בגלל הבונוס.
      if (score > 0 && f.isFavorite) score += 3000;
      // ===================================================

      return MapEntry(f, score);
    }).where((e) => e.value > 0).toList();

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).take(100).toList();
  }
}