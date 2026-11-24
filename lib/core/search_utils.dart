import '../data/models/food.dart';

class _FoodSearchData {
  final String normalizedName;
  final List<String> tokens;

  const _FoodSearchData(this.normalizedName, this.tokens);
}

class _TokenMatch {
  final int score;
  final bool isDirect;

  const _TokenMatch(this.score, {required this.isDirect});
}

class _ScoredFood {
  final Food food;
  final String normalizedName;
  final int score;
  final bool matchesAllTokens;

  const _ScoredFood({
    required this.food,
    required this.normalizedName,
    required this.score,
    required this.matchesAllTokens,
  });
}

class SearchUtils {
  // Synonyms intentionally contribute only a small fallback score. Exact and
  // token-based matches always outrank synonym-only results.
  static const Map<String, List<String>> _synonyms = {
    'משקה': ['שתייה', 'שייק', 'אבקה', 'נוזל', 'go', 'גו', 'ווי', 'whey'],
    'חלבון': ['פרוטאין', 'whey', 'וויי', 'גיינר'],
    'פחמימה': ['פחמימות', 'קרב', 'סוכר', 'פסטה', 'אורז', 'לחם', 'פתיתים', 'פריכיות'],
    'שומן': ['שומנים', 'שמן', 'אבוקדו', 'אגוז', 'חמאה'],
    'בשר': ['עוף', 'בקר', 'הודו', 'דג', 'טונה', 'שניצל'],
    'חלב': ['חלבי', 'גבינה', 'יוגורט', 'קוטג', 'שמנת'],
    'פירות': ['תפוח', 'בננה', 'תפוז', 'ענבים'],
    'ירקות': ['עגבניה', 'מלפפון', 'חסה', 'גזר'],
    'אבקה': ['חלבון', 'פרוטאין', 'whey'],
    'ווי': ['whey', 'חלבון', 'אבקה'],
    'גו': ['go'],
    'go': ['גו'],
    'שייק': ['משקה', 'אבקה'],
    'פרוטאין': ['חלבון', 'אבקה'],
  };

  static const Set<String> _usagePrefixes = {'ב', 'ל', 'כ', 'מ', 'ה', 'ו', 'ש'};
  static final Map<String, _FoodSearchData> _foodDataCache = {};

  /// Normalizes Hebrew/English food names without transliterating Hebrew.
  /// Hebrew vowel marks are removed, hyphens and punctuation become word
  /// separators, and repeated whitespace is collapsed.
  static String normalize(String text) {
    final output = StringBuffer();
    bool needsSpace = false;

    for (final rune in text.toLowerCase().runes) {
      if (_isHebrewMark(rune)) continue;

      if (_isLetterOrDigit(rune)) {
        if (needsSpace && output.length > 0) output.write(' ');
        output.writeCharCode(rune);
        needsSpace = false;
      } else {
        // Treat hyphens, punctuation, symbols and whitespace as separators.
        needsSpace = output.length > 0;
      }
    }

    return output.toString().trim();
  }

  static bool _isHebrewMark(int rune) {
    return (rune >= 0x0591 && rune <= 0x05BD) ||
        rune == 0x05BF ||
        (rune >= 0x05C1 && rune <= 0x05C2) ||
        (rune >= 0x05C4 && rune <= 0x05C5) ||
        rune == 0x05C7;
  }

  static bool _isLetterOrDigit(int rune) {
    final isHebrewLetter = rune >= 0x05D0 && rune <= 0x05EA;
    final isAsciiLetter =
        (rune >= 0x0061 && rune <= 0x007A) ||
        (rune >= 0x0041 && rune <= 0x005A);
    final isAsciiDigit = rune >= 0x0030 && rune <= 0x0039;
    return isHebrewLetter || isAsciiLetter || isAsciiDigit;
  }

  static _FoodSearchData _dataFor(Food food) {
    return _foodDataCache.putIfAbsent(food.name, () {
      final normalizedName = normalize(food.name);
      return _FoodSearchData(
        normalizedName,
        normalizedName.isEmpty ? const [] : normalizedName.split(' '),
      );
    });
  }

  /// Returns forms with one Hebrew usage prefix removed, e.g. "בחלבון" and
  /// "חלבון". The original form is retained to avoid over-normalizing roots.
  static Set<String> _tokenForms(String token) {
    final forms = <String>{token};
    if (token.length > 2 && _usagePrefixes.contains(token[0])) {
      forms.add(token.substring(1));
    }
    return forms;
  }

  static _TokenMatch? _matchToken(String queryToken, List<String> foodTokens) {
    final queryForms = _tokenForms(queryToken);
    int bestDirectScore = 0;

    for (final foodToken in foodTokens) {
      final foodForms = _tokenForms(foodToken);
      for (final queryForm in queryForms) {
        for (final foodForm in foodForms) {
          final matchScore = queryForm == foodForm
              ? 3000
              : queryForm.length >= 2 && foodForm.startsWith(queryForm)
                  ? 2000
                  : queryForm.length >= 3 && foodForm.contains(queryForm)
                      ? 1000
                      : 0;
          if (matchScore > bestDirectScore) bestDirectScore = matchScore;
        }
      }
    }

    if (bestDirectScore > 0) {
      return _TokenMatch(bestDirectScore, isDirect: true);
    }

    // Fuzzy matching is deliberately limited to one edit for words of at
    // least four characters, and is kept below all direct token matches.
    for (final foodToken in foodTokens) {
      for (final queryForm in queryForms) {
        if (queryForm.length < 4) continue;
        for (final foodForm in _tokenForms(foodToken)) {
          if ((queryForm.length - foodForm.length).abs() <= 1 &&
              _levenshteinAtMostOne(queryForm, foodForm)) {
            return const _TokenMatch(100, isDirect: false);
          }
        }
      }
    }

    // Synonyms are a final, low-confidence fallback—not a transliteration
    // layer and never a substitute for exact/phrase/token relevance.
    for (final queryForm in queryForms) {
      final synonyms = _synonyms[queryForm];
      if (synonyms == null) continue;
      for (final synonym in synonyms) {
        final normalizedSynonym = normalize(synonym);
        if (normalizedSynonym.isEmpty) continue;
        for (final foodToken in foodTokens) {
          if (_tokenForms(foodToken).contains(normalizedSynonym)) {
            return const _TokenMatch(50, isDirect: false);
          }
        }
      }
    }

    return null;
  }

  static bool _levenshteinAtMostOne(String a, String b) {
    if (a == b) return true;
    if ((a.length - b.length).abs() > 1) return false;

    int i = 0;
    int j = 0;
    int edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
        continue;
      }

      if (++edits > 1) return false;
      if (a.length > b.length) {
        i++;
      } else if (b.length > a.length) {
        j++;
      } else {
        i++;
        j++;
      }
    }

    if (i < a.length || j < b.length) edits++;
    return edits <= 1;
  }

  static _ScoredFood? _scoreFood(
    Food food,
    _FoodSearchData foodData,
    String normalizedQuery,
    List<String> queryTokens,
  ) {
    final name = foodData.normalizedName;
    if (name.isEmpty) return null;

    final favoriteBonus = food.isFavorite ? 100 : 0;

    // Tier 1: whole normalized phrase.
    if (name == normalizedQuery) {
      return _ScoredFood(
        food: food,
        normalizedName: name,
        score: 1000000 + favoriteBonus,
        matchesAllTokens: true,
      );
    }

    // Tier 2: phrase at the start, then phrase elsewhere in the name.
    if (name.startsWith(normalizedQuery)) {
      return _ScoredFood(
        food: food,
        normalizedName: name,
        score: 500000 + favoriteBonus,
        matchesAllTokens: true,
      );
    }
    if (name.contains(normalizedQuery)) {
      return _ScoredFood(
        food: food,
        normalizedName: name,
        score: 300000 + favoriteBonus,
        matchesAllTokens: true,
      );
    }

    final foodTokens = foodData.tokens;
    int directMatches = 0;
    int matchedTokens = 0;
    int totalScore = 0;

    for (final queryToken in queryTokens) {
      final match = _matchToken(queryToken, foodTokens);
      if (match == null) continue;
      matchedTokens++;
      totalScore += match.score;
      if (match.isDirect) directMatches++;
    }

    if (totalScore == 0) return null;
    final matchesAllTokens = matchedTokens == queryTokens.length;

    int score;
    if (directMatches == queryTokens.length) {
      // Tier 3: every query word matches directly. Exact word and prefix
      // matches score above substrings; focused names receive a length bonus.
      final lengthDifference = (name.length - normalizedQuery.length).abs();
      final rawLengthBonus = 5000 - lengthDifference * 75;
      final lengthBonus = rawLengthBonus > 0 ? rawLengthBonus : 0;
      score = 100000 + totalScore + lengthBonus + favoriteBonus;
    } else if (directMatches > 0) {
      // Partial direct matches remain below every complete direct match.
      final partialScore = directMatches * 1000 +
          totalScore +
          (food.isFavorite ? favoriteBonus : 0);
      score = partialScore < 99999 ? partialScore : 99999;
    } else {
      // Fuzzy/synonym-only matches are capped below even one real token hit.
      final fuzzyScore = 100 + totalScore;
      score = fuzzyScore < 999 ? fuzzyScore : 999;
    }

    return _ScoredFood(
      food: food,
      normalizedName: name,
      score: score,
      matchesAllTokens: matchesAllTokens,
    );
  }

  static List<Food> filterAndSortFoods(
    List<Food> foods,
    String query, {
    bool onlyFavorites = false,
  }) {
    final normalizedQuery = normalize(query);
    if (normalizedQuery.isEmpty) {
      final list = onlyFavorites ? foods.where((food) => food.isFavorite) : foods;
      return list.take(100).toList();
    }

    final queryTokens = normalizedQuery.split(' ');
    final scored = <_ScoredFood>[];

    // Score the full collection before sorting. In particular, do not stop at
    // an arbitrary candidate count: user-created foods may be at the end of
    // the SQLite result set.
    for (final food in foods) {
      if (onlyFavorites && !food.isFavorite) continue;
      final result = _scoreFood(food, _dataFor(food), normalizedQuery, queryTokens);
      if (result != null) scored.add(result);
    }

    // Preserve the existing strict AND behavior for multi-word searches when
    // no result matches every word; this avoids returning unrelated fragments.
    if (queryTokens.length > 1 &&
        !scored.any((result) => result.matchesAllTokens)) {
      return [];
    }

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byLength = a.normalizedName.length.compareTo(b.normalizedName.length);
      if (byLength != 0) return byLength;
      return a.normalizedName.compareTo(b.normalizedName);
    });

    return scored.take(100).map((result) => result.food).toList();
  }
}
