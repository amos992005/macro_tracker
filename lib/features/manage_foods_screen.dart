import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../core/file_platform.dart';
import '../data/macro_sync_service.dart';
import '../core/search_utils.dart';
import '../data/database_helper.dart';
import '../data/models/food.dart';

class ManageFoodsScreen extends StatefulWidget {
  const ManageFoodsScreen({super.key});

  @override
  State<ManageFoodsScreen> createState() => _ManageFoodsScreenState();
}

class _ManageFoodsScreenState extends State<ManageFoodsScreen> {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  List<Food> _foods = [];
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _loadFoods();
  }

  Future<void> _loadFoods() async {
    final foods = await _dbHelper.getAllFoods();
    if (!mounted) return;
    setState(() {
      _foods = foods;
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  List<Food> get _filteredFoods {
    return SearchUtils.filterAndSortFoods(_foods, _searchQuery);
  }

  Future<void> _exportFoods({bool onlyFavorites = false}) async {
    List<Food> foodsToExport = onlyFavorites
        ? _foods.where((f) => f.isFavorite).toList()
        : _foods;

    if (foodsToExport.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(onlyFavorites ? 'אין מועדפים לייצוא.' : 'אין מאכלים לייצוא.')),
        );
      }
      return;
    }

    List<Map<String, dynamic>> foodMaps = foodsToExport.map((f) => f.toMap()).toList();
    String jsonString = jsonEncode(foodMaps);

    try {
      String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: onlyFavorites ? 'שמור קובץ מועדפים' : 'שמור קובץ מאכלים',
        fileName: onlyFavorites ? 'macro_tracker_favorites.json' : 'macro_tracker_foods.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(utf8.encode(jsonString)),
      );

      if (outputFile != null) {
        if (!kIsWeb && defaultTargetPlatform != TargetPlatform.iOS && defaultTargetPlatform != TargetPlatform.android) {
          await writeTextToPath(outputFile, jsonString);
        }
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('הקובץ נשמר בהצלחה!')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('שגיאה בשמירת הקובץ: $e')));
    }
  }

  Future<void> _importFoods({bool forceFavorite = false}) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );

    if (result != null) {
      final pickedFile = result.files.single;
      final bytes = pickedFile.bytes;
      if (bytes == null && pickedFile.path == null) return;
      final jsonString = bytes != null
          ? utf8.decode(bytes)
          : await readTextFromPath(pickedFile.path!);

      try {
        List<dynamic> jsonList = jsonDecode(jsonString);

        // מפה של המאכלים הקיימים לצורך חיפוש מהיר, לפי שם מנורמל.
        final existingFoodsMap = {
          for (var food in _foods) food.name.trim().toLowerCase(): food,
        };
        final processedNames = <String>{};

        List<Food> newFoodsToInsert = [];
        // מפה של מוצרים שיש לעדכן (לפי ID כדי למנוע כפילויות)
        Map<int, Food> foodsToUpdate = {};

        for (var json in jsonList) {
          final newFood = Food.fromMap(json);
          final normalizedName = newFood.name.trim().toLowerCase();
          if (normalizedName.isEmpty || !processedNames.add(normalizedName)) continue;

          final existingFood = existingFoodsMap[normalizedName];
          if (existingFood != null) {
            final existing = existingFood;

            // אם מייבאים מועדפים, אנחנו דורסים את הערכים הקיימים עם מה שבקובץ
            if (forceFavorite) {
              final updatedFood = Food(
                id: existing.id,
                name: newFood.name.trim(),
                caloriesPer100g: newFood.caloriesPer100g,
                proteinPer100g: newFood.proteinPer100g,
                carbsPer100g: newFood.carbsPer100g,
                fatPer100g: newFood.fatPer100g,
                isLiquid: newFood.isLiquid,
                isRecipe: newFood.isRecipe,
                servings: newFood.servings,
                isFavorite: true, // מבטיחים שיהיה מועדף
              );
              foodsToUpdate[existing.id!] = updatedFood;
            }
          } else {
            // אם המאכל לא קיים, נוסיף אותו
            newFoodsToInsert.add(Food(
              name: newFood.name.trim(),
              caloriesPer100g: newFood.caloriesPer100g,
              proteinPer100g: newFood.proteinPer100g,
              carbsPer100g: newFood.carbsPer100g,
              fatPer100g: newFood.fatPer100g,
              isLiquid: newFood.isLiquid,
              isRecipe: newFood.isRecipe,
              servings: newFood.servings,
              isFavorite: forceFavorite ? true : newFood.isFavorite,
            ));
          }
        }

        if (newFoodsToInsert.isNotEmpty) {
          await _dbHelper.insertFoodsBatch(newFoodsToInsert);
        }

        for (var food in foodsToUpdate.values) {
          await _dbHelper.updateFood(food);
        }

        _loadFoods();

        if (mounted) {
          String msg = 'יובאו בהצלחה ${newFoodsToInsert.length} מאכלים חדשים.';
          if (foodsToUpdate.isNotEmpty) {
            msg += '\nעודכנו ${foodsToUpdate.length} מאכלים קיימים (הערכים שונו למועדפים).';
          }
          if (newFoodsToInsert.isEmpty && foodsToUpdate.isEmpty) {
            msg = 'לא נמצאו מאכלים חדשים או מועדפים לעדכון.';
          }
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('שגיאה בקריאת הקובץ: $e')));
        }
      }
    }
  }

  Future<void> _deleteFood(Food food) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() {
      _foods.removeWhere((f) => f.id == food.id);
    });

    bool isUndone = false;
    Timer? timer;

    final snackBar = SnackBar(
      content: Text('${food.name} נמחק'),
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: 'בטל',
        onPressed: () {
          timer?.cancel();
          isUndone = true;
          setState(() {
            _foods.add(food);
            _foods.sort((a, b) => a.id!.compareTo(b.id!));
          });
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        },
      ),
    );

    ScaffoldMessenger.of(context).showSnackBar(snackBar);

    timer = Timer(const Duration(seconds: 4), () async {
      if (!isUndone) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        await _dbHelper.deleteFood(food.id!);
      }
    });
  }

  void _showFoodDialog({Food? existingFood}) {
    final nameController = TextEditingController(text: existingFood?.name ?? '');
    final calController = TextEditingController(text: existingFood?.caloriesPer100g.toString() ?? '');
    final proController = TextEditingController(text: existingFood?.proteinPer100g.toString() ?? '');
    final carbController = TextEditingController(text: existingFood?.carbsPer100g.toString() ?? '');
    final fatController = TextEditingController(text: existingFood?.fatPer100g.toString() ?? '');
    final servingsController = TextEditingController(text: existingFood?.servings.toString() ?? '1');

    bool isLiquid = existingFood?.isLiquid ?? false;
    bool isRecipe = existingFood?.isRecipe ?? false;
    bool isCompletingAI = false;
    String? aiMessage;
    Uint8List? labelImageBytes;
    String? labelImageMime;

    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> completeNutrition({ImageSource? source}) async {
              if (source != null) {
                final image = await ImagePicker().pickImage(source: source, maxWidth: 1024, maxHeight: 1024, imageQuality: 80);
                if (image == null) return;
                labelImageBytes = await image.readAsBytes();
                if (labelImageBytes!.length > 6 * 1024 * 1024) {
                  labelImageBytes = null;
                  setDialogState(() => aiMessage = 'התמונה גדולה מדי. בחרו תמונה קטנה מ-6MB.');
                  return;
                }
                final lowerName = image.name.toLowerCase();
                labelImageMime = lowerName.endsWith('.png') ? 'image/png' : lowerName.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
              }
              if (nameController.text.trim().isEmpty && labelImageBytes == null) {
                setDialogState(() => aiMessage = 'כתבו שם מוצר או בחרו תמונת תווית.');
                return;
              }
              setDialogState(() { isCompletingAI = true; aiMessage = null; });
              try {
                final result = await MacroSyncService.instance.analyzeMeal(
                  text: nameController.text.trim(), imageBytes: labelImageBytes, mimeType: labelImageMime, mode: 'nutrition_label',
                );
                final items = (result['items'] as List? ?? const []).whereType<Map>().toList();
                if (items.isEmpty) throw StateError('לא התקבלו ערכים מהניתוח.');
                final values = Map<String, dynamic>.from(items.first);
                setDialogState(() {
                  if (nameController.text.trim().isEmpty) nameController.text = values['name']?.toString() ?? '';
                  calController.text = (values['calories_per_100g'] as num? ?? 0).toString();
                  proController.text = (values['protein_per_100g'] as num? ?? 0).toString();
                  carbController.text = (values['carbs_per_100g'] as num? ?? 0).toString();
                  fatController.text = (values['fat_per_100g'] as num? ?? 0).toString();
                  isLiquid = values['is_liquid'] == true;
                  aiMessage = result['confidence_note']?.toString() ?? 'הערכים הושלמו; מומלץ לוודא מול התווית.';
                });
              } catch (error) {
                setDialogState(() => aiMessage = error.toString());
              } finally {
                if (context.mounted) setDialogState(() => isCompletingAI = false);
              }
            }

            return AlertDialog(
              title: Text(existingFood == null ? 'הוספת מאכל חדש' : 'עריכת מאכל'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'שם המאכל / המתכון'),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: isCompletingAI ? null : () => completeNutrition(),
                          icon: isCompletingAI ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome),
                          label: const Text('✨ השלם ערכים עם AI'),
                        ),
                        IconButton(
                          tooltip: 'צילום תווית מוצר',
                          onPressed: isCompletingAI ? null : () => completeNutrition(source: ImageSource.camera),
                          icon: const Icon(Icons.camera_alt_outlined),
                        ),
                        IconButton(
                          tooltip: 'בחירת תמונת תווית',
                          onPressed: isCompletingAI ? null : () => completeNutrition(source: ImageSource.gallery),
                          icon: const Icon(Icons.photo_library_outlined),
                        ),
                      ],
                    ),
                    if (aiMessage != null) Align(alignment: Alignment.centerRight, child: Text(aiMessage!, style: const TextStyle(fontSize: 12, color: Colors.amber))),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Expanded(child: Text('האם זה נוזל?')),
                        Checkbox(
                          value: isLiquid,
                          onChanged: (val) => setDialogState(() => isLiquid = val ?? false),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Expanded(child: Text('האם זה מתכון (לפי מנות)?')),
                        Checkbox(
                          value: isRecipe,
                          onChanged: (val) {
                            setDialogState(() {
                              isRecipe = val ?? false;
                              if (!isRecipe) servingsController.text = '1';
                            });
                          },
                        ),
                      ],
                    ),
                    if (isRecipe)
                      TextField(
                        controller: servingsController,
                        decoration: const InputDecoration(labelText: 'כמה מנות יש במתכון?'),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      ),

                    const Divider(),
                    Text(isRecipe ? 'סך הערכים של כל המתכון:' : 'ערכים תזונתיים ל-100 (גרם/מ"ל):', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(controller: calController, decoration: const InputDecoration(labelText: 'קלוריות'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    TextField(controller: proController, decoration: const InputDecoration(labelText: 'חלבון (גר)'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    TextField(controller: carbController, decoration: const InputDecoration(labelText: 'פחמימות (גר)'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    TextField(controller: fatController, decoration: const InputDecoration(labelText: 'שומן (גר)'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
                ElevatedButton(
                  onPressed: () async {
                    String newName = nameController.text.trim();
                    if (newName.isEmpty) return;

                    bool nameExists = _foods.any((f) => f.name == newName && f.id != existingFood?.id);
                    if (nameExists) {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('שם קיים'),
                          content: Text('כבר קיים מאכל בשם "$newName". אנא בחר שם אחר.'),
                          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('הבנתי'))],
                        ),
                      );
                      return;
                    }

                    double servings = double.tryParse(servingsController.text) ?? 1.0;
                    if (servings <= 0) servings = 1.0;

                    bool finalIsFavorite = isRecipe ? true : (existingFood?.isFavorite ?? false);

                    final foodObj = Food(
                      id: existingFood?.id,
                      name: newName,
                      caloriesPer100g: double.tryParse(calController.text) ?? 0,
                      proteinPer100g: double.tryParse(proController.text) ?? 0,
                      carbsPer100g: double.tryParse(carbController.text) ?? 0,
                      fatPer100g: double.tryParse(fatController.text) ?? 0,
                      isLiquid: isLiquid,
                      isRecipe: isRecipe,
                      servings: servings,
                      isFavorite: finalIsFavorite,
                    );

                    if (existingFood == null) {
                      await _dbHelper.insertFood(foodObj);
                    } else {
                      await _dbHelper.updateFood(foodObj);
                    }

                    if (context.mounted) Navigator.pop(context);
                    _loadFoods();
                  },
                  child: const Text('שמור'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ניהול מאכלים ומתכונים'),
        centerTitle: true,
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'export_all') _exportFoods(onlyFavorites: false);
              if (value == 'export_favs') _exportFoods(onlyFavorites: true);
              if (value == 'import_all') _importFoods(forceFavorite: false);
              if (value == 'import_favs') _importFoods(forceFavorite: true);
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'export_all',
                child: Text('ייצוא כל המאכלים'),
              ),
              const PopupMenuItem<String>(
                value: 'export_favs',
                child: Text('ייצוא מועדפים בלבד'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'import_all',
                child: Text('ייבוא מאכלים (לא דורס קיימים)'),
              ),
              const PopupMenuItem<String>(
                value: 'import_favs',
                child: Text('ייבוא מועדפים (מעדכן ערכים)'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      labelText: 'חפש מאכל...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchDebounce?.cancel();
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          }
                      ) : null,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onChanged: (val) {
                      _searchDebounce?.cancel();
                      _searchDebounce = Timer(const Duration(milliseconds: 200), () {
                        if (!mounted) return;
                        setState(() => _searchQuery = val);
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _searchQuery.isEmpty
                        ? 'סה"כ מוצרים במאגר: ${_foods.length}'
                        : 'נמצאו ${_filteredFoods.length} תוצאות',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: _searchQuery.isEmpty ? Colors.blueGrey : Colors.blue,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

            Expanded(
              child: _filteredFoods.isEmpty
                  ? const Center(child: Text('לא נמצאו מאכלים'))
                  : ListView.builder(
                itemCount: _filteredFoods.length,
                itemBuilder: (context, index) {
                  final food = _filteredFoods[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: ListTile(
                      onTap: () => _showFoodDialog(existingFood: food),
                      title: Text(food.name),
                      subtitle: Text(
                          food.isRecipe
                              ? 'מתכון: ${food.servings.toStringAsFixed(0)} מנות'
                              : '${food.caloriesPer100g} קק"ל ל-100${food.isLiquid ? 'מ"ל' : 'גרם'}'
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(food.isFavorite ? Icons.star : Icons.star_border, color: Colors.amber),
                            onPressed: () async {
                              await _dbHelper.toggleFavorite(food.id!, !food.isFavorite);
                              _loadFoods();
                            },
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _deleteFood(food),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showFoodDialog(),
        icon: const Icon(Icons.add),
        label: const Text('הוסף מאכל'),
      ),
    );
  }
}
