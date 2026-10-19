import 'dart:math' as math;
import '../data/models/food.dart';

// מחלקת עזר פנימית לשמירת נתוני חיפוש מחושבים מראש
class _FoodSearchData {
  final List<String> tokens;
  final String normNoSpaces;
  _FoodSearchData(this.tokens, this.normNoSpaces);
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

  static final Map<String, String> _primaryCache = {};
  static final Map<String, List<String>> _variantCache = {};

  // --- מטמון נתוני חיפוש עבור מוצרים ---
  static final Map<String, _FoodSearchData> _foodDataCache = {};

  // --- מטמון נתוני חיפוש עבור שאילתות ---
  static final Map<String, List<String>> _queryTokensCache = {};
  static final Map<String, String> _queryNormCache = {};

  static String normalize(String text) {
    if (text.isEmpty) return '';
    if (_primaryCache.containsKey(text)) return _primaryCache[text]!;

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
    _primaryCache[text] = result;
    return result;
  }

  static List<String> _tokenizeAndClean(String text) {
    String normalized = normalize(text);
    List<String> tokens = normalized.split(' ').where((t) => t.isNotEmpty).toList();
    return tokens.where((t) => !_stopWords.contains(t) && t.length > 1).toList();
  }

  // מחזיר את נתוני החיפוש של מוצר - מחושב פעם אחת ונשמר במטמון
  static _FoodSearchData _getFoodData(Food food) {
    final key = food.name;
    if (_foodDataCache.containsKey(key)) return _foodDataCache[key]!;

    final tokens = _tokenizeAndClean(food.name);
    final normNoSpaces = normalize(food.name).replaceAll(' ', '');
    final data = _FoodSearchData(tokens, normNoSpaces);
    _foodDataCache[key] = data;
    return data;
  }

  // מחזיר את הטוקנים של השאילתה - מחושב פעם אחת ונשמר במטמון
  static List<String> _getQueryTokens(String query) {
    if (_queryTokensCache.containsKey(query)) return _queryTokensCache[query]!;
    final tokens = _tokenizeAndClean(query);
    _queryTokensCache[query] = tokens;
    return tokens;
  }

  // מחזיר את השאילתה ללא רווחים - מחושב פעם אחת ונשמר במטמון
  static String _getQueryNormNoSpaces(String query) {
    if (_queryNormCache.containsKey(query)) return _queryNormCache[query]!;
    final norm = normalize(query).replaceAll(' ', '');
    _queryNormCache[query] = norm;
    return norm;
  }

  static List<Food> filterAndSortFoods(List<Food> foods, String query, {bool onlyFavorites = false}) {
    // 1. מקרה קצה - חיפוש ריק
    if (query.trim().isEmpty) {
      var list = onlyFavorites ? foods.where((f) => f.isFavorite).toList() : foods;
      return list.take(100).toList();
    }

    // 2. שליפת נתוני השאילתה מהמטמון (חישוב מהיר)
    final queryTokens = _getQueryTokens(query);
    final normQueryNoSpaces = _getQueryNormNoSpaces(query);

    if (queryTokens.isEmpty) {
      var list = onlyFavorites ? foods.where((f) => f.isFavorite).toList() : foods;
      return list.take(100).toList();
    }

    // 3. סינון מקדים מהיר (ללא חישובי ציון)
    final preFiltered = <Food>[];
    for (var food in foods) {
      if (onlyFavorites && !food.isFavorite) continue;

      final foodData = _getFoodData(food); // שליפה מהמטמון

      // בדיקה מהירה: התאמת משפט מלא (בלי רווחים)
      if (foodData.normNoSpaces.contains(normQueryNoSpaces)) {
        preFiltered.add(food);
        continue;
      }

      // בדיקה מהירה: התאמת token בודד
      bool hasMatch = false;
      for (var qToken in queryTokens) {
        for (var fToken in foodData.tokens) {
          if (fToken.contains(qToken) || qToken.contains(fToken)) {
            hasMatch = true;
            break;
          }
        }
        if (hasMatch) break;
      }

      if (hasMatch) preFiltered.add(food);
    }

    // 4. ניקוד רק על מה שעבר את הסינון
    final scored = preFiltered.map((f) {
      final foodData = _getFoodData(f); // שליפה מהמטמון
      double score = 0;

      // בונוס עצום על התאמת משפט מלא
      if (foodData.normNoSpaces == normQueryNoSpaces) {
        score += 100000;
      } else if (foodData.normNoSpaces.contains(normQueryNoSpaces)) {
        score += 10000;
      }

      // בונוס לפי אחוז המילים שנמצאו
      int matches = 0;
      for (var qToken in queryTokens) {
        bool isMatched = false;
        for (var fToken in foodData.tokens) {
          if (fToken.contains(qToken) || qToken.contains(fToken)) {
            isMatched = true;
            break;
          }
        }
        if (isMatched) matches++;
      }

      if (matches == queryTokens.length && queryTokens.isNotEmpty) {
        score += 5000;
      } else {
        score += (matches / queryTokens.length) * 1000;
      }

      // מועדפים מקבלים בונוס
      if (f.isFavorite) score += 2000;

      return MapEntry(f, score);
    }).toList();

    // 5. מיון והחזרה
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).take(150).toList();
  }

  // --- פונקציות הטסטים הישנות (נשארות ללא שינוי) ---
  static List<String> variants(String text) {
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

  static int _lev(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    if ((a.length - b.length).abs() > 3) return 100;

    List<int> prev = List.generate(b.length + 1, (i) => i);
    for (int i = 1; i <= a.length; i++) {
      List<int> curr = [i];
      for (int j = 1; j <= b.length; j++) {
        int cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr.add([curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].reduce(math.min));
      }
      prev = curr;
    }
    return prev[b.length];
  }

  static double _ngramScore(String a, String b) {
    if (a.length < 3 || b.length < 3) return 0.0;
    Set<String> aGrams = {};
    for (int i = 0; i <= a.length - 3; i++) aGrams.add(a.substring(i, i + 3));
    Set<String> bGrams = {};
    for (int i = 0; i <= b.length - 3; i++) bGrams.add(b.substring(i, i + 3));
    int overlap = aGrams.intersection(bGrams).length;
    int total = aGrams.length + bGrams.length - overlap;
    if (total == 0) return 0.0;
    return overlap / total;
  }

  static double _tokenScore(String q, String f) {
    if (q.isEmpty || f.isEmpty) return 0.0;
    if (q == f) return 100.0;

    if (q.length < 2) {
      if (f.startsWith(q)) return 60.0;
      return 0.0;
    }

    if (f.startsWith(q)) return 80.0;
    if (q.startsWith(f) && f.length >= 3) return 75.0;
    if (f.contains(q)) return 55.0;
    if (q.contains(f) && f.length >= 3) return 45.0;

    int prefixLen = 0;
    int minLen = math.min(q.length, f.length);
    for(int i=0; i<minLen; i++) {
      if(q[i] == f[i]) prefixLen++;
      else break;
    }
    if (prefixLen >= 3) {
      double ratio = prefixLen / math.max(q.length, f.length);
      return 30.0 + (ratio * 30.0);
    }

    if (q.length >= 4 && f.length >= 4) {
      double ngram = _ngramScore(q, f);
      if (ngram > 0.4) return 20.0 + (ngram * 30.0);
    }

    if ((q.length - f.length).abs() > 3) return 0.0;

    int dist = _lev(q, f);
    int maxLen = math.max(q.length, f.length);
    if (maxLen == 0) return 0.0;
    double similarity = 1.0 - (dist / maxLen);

    if (similarity >= 0.75) return 40.0;
    if (similarity >= 0.65) return 20.0;

    return 0.0;
  }

  static double score(String foodName, String query) {
    if (query.trim().isEmpty) return 1.0;

    String normFood = normalize(foodName);
    List<String> foodTokens = normFood.split(' ').where((t) => t.isNotEmpty).toList();
    if (foodTokens.isEmpty) return 0.0;

    List<String> rawQueryTokens = query.toLowerCase().trim().split(' ').where((t) => t.isNotEmpty).toList();
    if (rawQueryTokens.isEmpty) return 0.0;

    double totalScore = 0.0;
    int highQuality = 0;
    int strongMatches = 0;

    for (String rawToken in rawQueryTokens) {
      List<String> qVariants = variants(rawToken);
      double bestScore = 0.0;

      for (String qv in qVariants) {
        for (String fToken in foodTokens) {
          double s = _tokenScore(qv, fToken);
          if (s > bestScore) {
            bestScore = s;
            if (s >= 100) break;
          }
        }
        if (bestScore >= 100) break;
      }

      String normToken = normalize(rawToken);
      List<String>? syns = _synonyms[rawToken] ?? _synonyms[normToken];
      if (syns != null && bestScore < 100) {
        for (String syn in syns) {
          for (String sv in variants(syn)) {
            for (String fToken in foodTokens) {
              double s = _tokenScore(sv, fToken) * 0.5;
              if (s > bestScore) bestScore = s;
            }
          }
        }
      }

      totalScore += bestScore;
      if (bestScore >= 75) highQuality++;
      if (bestScore >= 45) strongMatches++;
    }

    double hqRatio = highQuality / rawQueryTokens.length;
    double strongRatio = strongMatches / rawQueryTokens.length;

    if (hqRatio >= 1.0) totalScore *= 2.5;
    else if (hqRatio >= 0.66) totalScore *= 1.6;
    else if (hqRatio >= 0.33) totalScore *= 1.2;

    if (strongRatio >= 1.0) totalScore *= 1.3;

    if (rawQueryTokens.isNotEmpty && foodTokens.isNotEmpty) {
      List<String> firstVariants = variants(rawQueryTokens.first);
      if (firstVariants.any((v) => v.length >= 2 && foodTokens.first.startsWith(v))) {
        totalScore *= 1.5;
      }
    }

    return totalScore;
  }

  static bool matches(String foodName, String query) {
    if (query.trim().isEmpty) return true;
    return score(foodName, query) > 0.5;
  }
}