import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;

const String baseUrl = 'https://www.foodsdictionary.co.il';
const String searchEndpoint = '$baseUrl/search.php'; // עדכנו את הנתיב
const String outputFile = 'foods_from_foodsdictionary.json';
const int maxProducts = 2000;

// האדר שמדמה דפדפן כדי למנוע חסימות
const Map<String, String> browserHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
  'Accept-Language': 'he-IL,he;q=0.9,en-US;q=0.8,en;q=0.7',
};

final List<String> searchQueries = [
  'חזה עוף', 'שניצל', 'עוף', 'הודו', 'בקר', 'סטייק', 'בשר טחון', 'כבד', 'טונה', 'סלמון', 'דג', 'ביצה', 'חלבון ביצה',
  'טופו', 'סויה', 'אפונה', 'שעועית', 'עדשים', 'חומוס', 'פול', 'גרגירי חומוס', 'חלבון מי גבינה', 'אבקת חלבון',
  'אורז', 'פסטה', 'ספגטי', 'לחם', 'פיתה', 'טורטיה', 'קוואקר', 'שיבולת שועל', 'תפוח אדמה', 'בטטה', 'קינואה', 'בורגול', 'פתיתים', 'קורנפלקס', 'גרנולה',
  'שמן זית', 'אבוקדו', 'אגוז', 'שקד', 'חמאת בוטנים', 'טחינה', 'זרעים', 'גרעינים',
  'עגבניה', 'מלפפון', 'חסה', 'גזר', 'בצל', 'שום', 'פלפל', 'ברוקולי', 'כרובית', 'קישוא', 'חציל', 'תרד', 'סלק', 'דלעת', 'תירס',
  'תפוח', 'בננה', 'תפוז', 'אבטיח', 'ענבים', 'תות', 'מנגו', 'אגס', 'אפרסק', 'שזיף', 'קיווי', 'אננס', 'רימון',
  'חלב', 'גבינה', 'יוגורט', 'קוטג', 'שמנת', 'חמאה', 'לאבנה', 'צפתית',
  'שוקולד', 'עוגיה', 'גלידה', 'חטיף אנרגיה', 'דבש', 'ריבה', 'סילאן',
  'מיץ', 'סודה', 'קפה', 'תה', 'משקה חלבון', 'משקה אנרגיה'
];

final Set<String> visitedUrls = {};
final List<Map<String, dynamic>> allFoods = [];

Future<void> main() async {
  print('מתחיל סריקה חכמה של FoodsDictionary...');

  for (String query in searchQueries) {
    print('מחפש: $query');
    await _scrapeSearchPage(query);
    if (allFoods.length >= maxProducts) break;
  }

  final file = File(outputFile);
  await file.writeAsString(jsonEncode(allFoods));
  print('הסתיים! נשמרו ${allFoods.length} מאכלים בקובץ $outputFile');
}

Future<void> _scrapeSearchPage(String query) async {
  try {
    final encodedQuery = Uri.encodeComponent(query);
    final url = Uri.parse('$searchEndpoint?q=$encodedQuery');

    final response = await http.get(url, headers: browserHeaders);

    if (response.statusCode != 200) {
      print('  שגיאה: סטטוס ${response.statusCode}');
      return;
    }

    final document = parser.parse(response.body);

    // הדפסת דיבאג כדי לראות אם קיבלנו תוצאות
    // print('  אורך HTML: ${response.body.length} תווים');

    final links = document.querySelectorAll('a');
    int foundLinks = 0;

    for (var a in links) {
      final href = a.attributes['href'];
      if (href != null && href.toLowerCase().contains('products/')) {
        // טיפול בקישור יחסי או מוחלט
        final fullUrl = href.startsWith('http') ? href : '$baseUrl/$href'.replaceAll('//', '/').replaceFirst(':/', '://');

        if (!visitedUrls.contains(fullUrl) && allFoods.length < maxProducts) {
          visitedUrls.add(fullUrl);
          foundLinks++;
          final food = await _scrapeProductPage(fullUrl);
          if (food != null) {
            allFoods.add(food);
            print('  נוסף: ${food['name']}');
          }
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
    }

    if (foundLinks == 0) {
      print('  לא נמצאו קישורים למוצרים בחיפוש הזה.');
    }
  } catch (e) {
    print('שגיאה בחיפוש "$query": $e');
  }
}

Future<Map<String, dynamic>?> _scrapeProductPage(String url) async {
  try {
    final response = await http.get(Uri.parse(url), headers: browserHeaders);
    if (response.statusCode != 200) return null;

    final document = parser.parse(response.body);

    String name = document.querySelector('h1')?.text.trim() ?? '';
    if (name.isEmpty) {
      name = document.querySelector('title')?.text.trim() ?? 'מוצר ללא שם';
      name = name.replaceAll(' - FoodsDictionary', '').trim();
    }

    double calories = 0, protein = 0, carbs = 0, fat = 0;
    bool isLiquid = false;

    final tables = document.querySelectorAll('table');
    for (var table in tables) {
      final text = table.text;
      if (text.contains('קלוריות') || text.contains('חלבונים')) {
        final rows = table.querySelectorAll('tr');
        for (var row in rows) {
          final cells = row.querySelectorAll('td');
          if (cells.length >= 2) {
            final label = cells[0].text.trim();
            final valueText = cells[1].text.trim();
            final numberMatch = RegExp(r'([\d.]+)').firstMatch(valueText);
            if (numberMatch != null) {
              final value = double.tryParse(numberMatch.group(1)!) ?? 0;
              if (label.contains('קלוריות')) calories = value;
              else if (label.contains('חלבונים')) protein = value;
              else if (label.contains('פחמימות')) carbs = value;
              else if (label.contains('שומנים')) fat = value;
            }
          }
        }
        if (text.contains('ל-100 מ"ל')) isLiquid = true;
        break;
      }
    }

    if (!isLiquid) {
      final liquidKeywords = ['חלב', 'מיץ', 'שתייה', 'משקה', 'מים', 'סודה', 'בירה', 'יין', 'שייק'];
      isLiquid = liquidKeywords.any((k) => name.contains(k));
    }

    if (calories == 0) return null;

    return {
      'name': name,
      'calories_per_100g': calories,
      'protein_per_100g': protein,
      'carbs_per_100g': carbs,
      'fat_per_100g': fat,
      'is_liquid': isLiquid ? 1 : 0,
      'is_recipe': 0,
      'servings': 1.0,
    };
  } catch (e) {
    return null;
  }
}