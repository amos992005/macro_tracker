import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../core/calculator.dart';
import '../../core/composite_meal_utils.dart';
import '../../core/meal_optimizer.dart';
import '../../core/meal_rule_settings.dart';
import '../../core/search_utils.dart';
import '../../data/database_helper.dart';
import '../../data/models/food.dart';
import 'ai_meal_editor.dart';
import '../manage_foods_screen.dart';

class TrackerScreen extends StatefulWidget {
  final String? username;
  final Future<void> Function()? onSignOut;
  const TrackerScreen({super.key, this.username, this.onSignOut});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final TextEditingController _weightController = TextEditingController();

  List<Food> _foods = [];
  int? _selectedFoodId;
  List<Map<String, dynamic>> _todayMeals = [];

  String _todayDate = '';
  Map<String, dynamic> _settings = {};

  double _targetCalories = 2000;
  double _targetProtein = 150;
  double _targetCarbs = 200;
  double _targetFat = 60;

  @override
  void initState() {
    super.initState();
    _todayDate = getEffectiveDate();
    _loadData();
  }

  String getEffectiveDate() {
    final now = DateTime.now();
    if (now.hour < 4) {
      final yesterday = now.subtract(const Duration(days: 1));
      return DateFormat('yyyy-MM-dd').format(yesterday);
    }
    return DateFormat('yyyy-MM-dd').format(now);
  }

  Future<void> _loadData() async {
    final foods = await _dbHelper.getAllFoods();
    final meals = await _dbHelper.getMealsForDate(_todayDate);
    final defaultTargets = await _dbHelper.getDefaultTargets();
    final savedDailyTargets = await _dbHelper.getTargetsForDate(_todayDate);
    final targets = savedDailyTargets ?? defaultTargets;
    if (savedDailyTargets == null) {
      await _dbHelper.saveTargetsForDate(
        _todayDate,
        (targets['calories'] as num).toDouble(),
        (targets['protein'] as num).toDouble(),
        (targets['carbs'] as num).toDouble(),
        (targets['fat'] as num).toDouble(),
      );
    }
    final settings = await _dbHelper.getSettings();
    if (!mounted) return;

    setState(() {
      _foods = foods;
      _todayMeals = meals;
      _settings = settings;
      _targetCalories = (targets['calories'] as num).toDouble();
      _targetProtein = (targets['protein'] as num).toDouble();
      _targetCarbs = (targets['carbs'] as num).toDouble();
      _targetFat = (targets['fat'] as num).toDouble();

      if (_foods.isEmpty) {
        _selectedFoodId = null;
      } else if (_selectedFoodId == null || !_foods.any((f) => f.id == _selectedFoodId)) {
        _selectedFoodId = _foods.first.id;
      }
    });
  }

  Future<void> _addMeal() async {
    if (_selectedFoodId == null || _weightController.text.isEmpty) return;

    final amount = double.tryParse(_weightController.text);
    if (amount == null || amount <= 0) return;

    final food = _foods.firstWhere((f) => f.id == _selectedFoodId);

    double finalAmountToSave = amount;
    if (food.isRecipe) {
      finalAmountToSave = (100 / food.servings) * amount;
    }

    await _dbHelper.insertMealEntry(_selectedFoodId!, finalAmountToSave, _todayDate);
    _weightController.clear();
    _loadData();
  }

  Future<void> _deleteMeal(int entryId) async {
    await _dbHelper.deleteMealEntry(entryId);
    _loadData();
  }

  Future<void> _showAiMealEditor({Map<String, dynamic>? existingMeal}) async {
    List<Map<String, dynamic>>? initialItems;
    if (existingMeal != null && existingMeal['components_json'] is String) {
      try {
        final decoded = jsonDecode(existingMeal['components_json'] as String) as List;
        initialItems = decoded.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
      } catch (_) {
        initialItems = [];
      }
    }
    final result = await AiMealEditor.show(
      context,
      foods: _foods,
      title: existingMeal?['meal_title']?.toString() ?? existingMeal?['food_name']?.toString(),
      items: initialItems,
    );
    if (result == null || !mounted) return;
    final items = (result['items'] as List).whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
    final title = result['title'] as String;
    if (existingMeal == null) {
      await _dbHelper.insertCompositeMeal(title: title, components: items, date: _todayDate);
      if (result['save_as_recipe'] == true) {
        double total(String key) => items.fold<double>(0, (sum, item) =>
            sum + ((item['grams'] as num?)?.toDouble() ?? 0) * ((item['${key}_per_100g'] as num?)?.toDouble() ?? 0) / 100);
        await _dbHelper.insertFood(Food(
          name: title,
          caloriesPer100g: total('calories'),
          proteinPer100g: total('protein'),
          carbsPer100g: total('carbs'),
          fatPer100g: total('fat'),
          isRecipe: true,
          servings: 1,
          isFavorite: true,
        ));
      }
    } else {
      await _dbHelper.updateCompositeMeal(entryId: existingMeal['entry_id'] as int, title: title, components: items);
    }
    await _loadData();
  }

  NutritionResult _calculateDailyTotals() {
    double totalCal = 0, totalPro = 0, totalCarb = 0, totalFat = 0;
    for (var meal in _todayMeals) {
      final result = Calculator.calculateFromWeight(
        weightGrams: meal['weight_grams'],
        calPer100g: meal['calories_per_100g'],
        proPer100g: meal['protein_per_100g'],
        carbPer100g: meal['carbs_per_100g'],
        fatPer100g: meal['fat_per_100g'],
      );
      totalCal += result.calories;
      totalPro += result.protein;
      totalCarb += result.carbs;
      totalFat += result.fat;
    }
    return NutritionResult(totalCal, totalPro, totalCarb, totalFat);
  }

  Future<void> _editTargets() async {
    final defaultTargets = await _dbHelper.getDefaultTargets();
    if (!mounted) return;

    final calController = TextEditingController(text: _targetCalories.toStringAsFixed(0));
    final proController = TextEditingController(text: _targetProtein.toStringAsFixed(0));
    final carbController = TextEditingController(text: _targetCarbs.toStringAsFixed(0));
    final fatController = TextEditingController(text: _targetFat.toStringAsFixed(0));

    final defaultCalories = (defaultTargets['calories'] as num).toDouble();
    final defaultProtein = (defaultTargets['protein'] as num).toDouble();
    final defaultCarbs = (defaultTargets['carbs'] as num).toDouble();
    final defaultFat = (defaultTargets['fat'] as num).toDouble();
    bool isSaving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> saveTargets({required bool saveAsDefault}) async {
              if (isSaving) return;
              setDialogState(() => isSaving = true);

              final newCalories =
                  double.tryParse(calController.text) ?? _targetCalories;
              final newProtein =
                  double.tryParse(proController.text) ?? _targetProtein;
              final newCarbs =
                  double.tryParse(carbController.text) ?? _targetCarbs;
              final newFat = double.tryParse(fatController.text) ?? _targetFat;

              try {
                if (saveAsDefault) {
                  await _dbHelper.saveDefaultTargets(
                    newCalories,
                    newProtein,
                    newCarbs,
                    newFat,
                  );
                }
                await _dbHelper.saveTargetsForDate(
                  _todayDate,
                  newCalories,
                  newProtein,
                  newCarbs,
                  newFat,
                );

                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) await _loadData();
              } finally {
                if (dialogContext.mounted) {
                  setDialogState(() => isSaving = false);
                }
              }
            }

            Future<void> resetTodayToDefaults() async {
              if (isSaving) return;
              setDialogState(() => isSaving = true);
              try {
                await _dbHelper.saveTargetsForDate(
                  _todayDate,
                  defaultCalories,
                  defaultProtein,
                  defaultCarbs,
                  defaultFat,
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) await _loadData();
              } finally {
                if (dialogContext.mounted) {
                  setDialogState(() => isSaving = false);
                }
              }
            }

            return AlertDialog(
              title: const Text('עדכון יעדים להיום'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: calController,
                      decoration: const InputDecoration(labelText: 'קלוריות'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                    TextField(
                      controller: proController,
                      decoration: const InputDecoration(labelText: 'חלבון (גר)'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                    TextField(
                      controller: carbController,
                      decoration: const InputDecoration(labelText: 'פחמימות (גר)'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                    TextField(
                      controller: fatController,
                      decoration: const InputDecoration(labelText: 'שומן (גר)'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'ברירת מחדל קבועה נוכחית: '
                      '${defaultCalories.toStringAsFixed(0)} קלוריות, '
                      '${defaultProtein.toStringAsFixed(0)} חלבון, '
                      '${defaultCarbs.toStringAsFixed(0)} פחמימות, '
                      '${defaultFat.toStringAsFixed(0)} שומן.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: isSaving ? null : resetTodayToDefaults,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('אפס את היעדים להיום לברירת המחדל'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('ביטול'),
                ),
                OutlinedButton(
                  onPressed: isSaving
                      ? null
                      : () => saveTargets(saveAsDefault: false),
                  child: const Text('שמור להיום בלבד'),
                ),
                ElevatedButton(
                  onPressed: isSaving
                      ? null
                      : () => saveTargets(saveAsDefault: true),
                  child: const Text('שמור כברירת מחדל וגם להיום'),
                ),
              ],
            );
          },
        );
      },
    );

    calController.dispose();
    proController.dispose();
    carbController.dispose();
    fatController.dispose();
  }

  void _showFoodPicker() {
    final searchController = TextEditingController();
    bool showOnlyFavorites = false;
    Timer? debounce;

    List<Food> dialogFilteredList = SearchUtils.filterAndSortFoods(_foods, '');

    void performSearch(String query, StateSetter setDialogState, {bool immediate = false}) {
      if (debounce?.isActive ?? false) debounce!.cancel();

      void executeSearch() {
        final results = SearchUtils.filterAndSortFoods(_foods, query, onlyFavorites: showOnlyFavorites);
        setDialogState(() {
          dialogFilteredList = results;
        });
      }

      if (immediate) {
        executeSearch();
      } else {
        debounce = Timer(const Duration(milliseconds: 200), executeSearch);
      }
    }

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('בחר מאכל'),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('food_picker_search'),
                            controller: searchController,
                            decoration: const InputDecoration(
                              hintText: 'חפש...',
                              prefixIcon: Icon(Icons.search),
                              isDense: true,
                            ),
                            onChanged: (val) => performSearch(val, setDialogState),
                          ),
                        ),
                        IconButton(
                          icon: Icon(showOnlyFavorites ? Icons.star : Icons.star_border, color: Colors.amber),
                          onPressed: () {
                            setDialogState(() {
                              showOnlyFavorites = !showOnlyFavorites;
                            });
                            performSearch(searchController.text, setDialogState, immediate: true);
                          },
                        )
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: dialogFilteredList.isEmpty
                          ? const Center(child: Text('לא נמצאו תוצאות'))
                          : ListView.builder(
                        key: const ValueKey('food_picker_list'),
                        itemCount: dialogFilteredList.length,
                        itemBuilder: (context, index) {
                          final food = dialogFilteredList[index];
                          return ListTile(
                            leading: food.isFavorite ? const Icon(Icons.star, color: Colors.amber) : null,
                            title: Text(food.name),
                            subtitle: Text('${food.caloriesPer100g} קק"ל ל-100${food.isLiquid ? 'מ"ל' : 'גרם'}'),
                            onTap: () {
                              setState(() {
                                _selectedFoodId = food.id;
                              });
                              Navigator.pop(context);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showRuleSettingsDialog() async {
    String calMode = _settings['cal_mode'] as String? ?? 'down';
    double calPct = (_settings['cal_pct'] as num?)?.toDouble() ?? 10.0;
    String proMode = _settings['pro_mode'] as String? ?? 'up';
    double proPct = (_settings['pro_pct'] as num?)?.toDouble() ?? 10.0;
    String carbMode = _settings['carb_mode'] as String? ?? 'both';
    double carbPct = (_settings['carb_pct'] as num?)?.toDouble() ?? 10.0;
    String fatMode = _settings['fat_mode'] as String? ?? 'free';
    double fatPct = (_settings['fat_pct'] as num?)?.toDouble() ?? 0.0;
    final controllers = <String, TextEditingController>{
      'cal_pct': TextEditingController(text: calPct.toString()),
      'pro_pct': TextEditingController(text: proPct.toString()),
      'carb_pct': TextEditingController(text: carbPct.toString()),
      'fat_pct': TextEditingController(text: fatPct.toString()),
    };

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Widget buildRuleRow(String title, String mode, TextEditingController controller, ValueChanged<String> onModeChange) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Row(
                      children: [
                        DropdownButton<String>(
                          value: mode,
                          items: const [
                            DropdownMenuItem(value: 'free', child: Text('ללא הגבלה (גמיש)')),
                            DropdownMenuItem(value: 'up', child: Text('למעלה בלבד')),
                            DropdownMenuItem(value: 'down', child: Text('למטה בלבד')),
                            DropdownMenuItem(value: 'both', child: Text('שני הכיוונים')),
                          ],
                          onChanged: (value) {
                            if (value != null) setDialogState(() => onModeChange(value));
                          },
                        ),
                        if (mode != 'free') ...[
                          const SizedBox(width: 16),
                          SizedBox(
                            width: 76,
                            child: TextField(
                              controller: controller,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: false),
                              decoration: const InputDecoration(labelText: '%', isDense: true),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                );
              }

              return AlertDialog(
                title: const Text('חוקי הברזל (סטייה מהיעד)'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      buildRuleRow('קלוריות:', calMode, controllers['cal_pct']!, (value) => calMode = value),
                      buildRuleRow('חלבון:', proMode, controllers['pro_pct']!, (value) => proMode = value),
                      buildRuleRow('פחמימות:', carbMode, controllers['carb_pct']!, (value) => carbMode = value),
                      buildRuleRow('שומן:', fatMode, controllers['fat_pct']!, (value) => fatMode = value),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('ביטול'),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      final newSettings = <String, dynamic>{
                        'cal_mode': calMode,
                        'cal_pct': MealRuleSettings.parsePercent(controllers['cal_pct']!.text, fallback: calPct),
                        'pro_mode': proMode,
                        'pro_pct': MealRuleSettings.parsePercent(controllers['pro_pct']!.text, fallback: proPct),
                        'carb_mode': carbMode,
                        'carb_pct': MealRuleSettings.parsePercent(controllers['carb_pct']!.text, fallback: carbPct),
                        'fat_mode': fatMode,
                        'fat_pct': MealRuleSettings.parsePercent(controllers['fat_pct']!.text, fallback: fatPct),
                      };
                      try {
                        await _dbHelper.saveSettings(newSettings);
                        if (!mounted) return;
                        setState(() => _settings = {..._settings, ...newSettings});
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(content: Text('הגדרות חוקי הברזל נשמרו.')),
                        );
                        await _loadData();
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(content: Text('שמירת ההגדרות נכשלה: $error')),
                          );
                        }
                      }
                    },
                    child: const Text('שמור'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    }
  }

  void _showMealBuilderDialog() {
    final calController = TextEditingController();
    final proController = TextEditingController();
    final carbController = TextEditingController();
    final fatController = TextEditingController();
    final searchController = TextEditingController();

    List<int> selectedFoodIds = [];
    Map<int, int> preferences = {};
    Map<int, double> lockedWeights = {};

    OptimizationResult? result;
    bool isSaving = false;
    bool isCalculating = false;

    bool showOnlyFavorites = false;
    Timer? debounce;
    List<Food> filteredFoods = SearchUtils.filterAndSortFoods(_foods, '');

    void performSearch(String query, StateSetter setDialogState, {bool immediate = false}) {
      if (debounce?.isActive ?? false) debounce!.cancel();

      void executeSearch() {
        final results = SearchUtils.filterAndSortFoods(_foods, query, onlyFavorites: showOnlyFavorites);
        setDialogState(() {
          filteredFoods = results;
        });
      }

      if (immediate) {
        executeSearch();
      } else {
        debounce = Timer(const Duration(milliseconds: 200), executeSearch);
      }
    }

    showDialog(
      context: context,
      builder: (mainDialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {

            Future<void> runOptimization() async {
              if (selectedFoodIds.isEmpty || isCalculating) return;
              double tCal = double.tryParse(calController.text) ?? 0;
              double tPro = double.tryParse(proController.text) ?? 0;
              double tCarb = double.tryParse(carbController.text) ?? 0;
              double tFat = double.tryParse(fatController.text) ?? 0;
              if (tCal == 0 && tPro == 0 && tCarb == 0 && tFat == 0) return;

              final selectedFoods = _foods.where((f) => selectedFoodIds.contains(f.id)).toList();
              final prefsList = selectedFoods.map((f) => preferences[f.id] ?? 3).toList();

              setDialogState(() => isCalculating = true);
              OptimizationResult? optResult;
              try {
                optResult = await MealOptimizer.optimizeWithFixedInIsolate(
                  allFoods: selectedFoods,
                  fixedWeights: lockedWeights,
                  targets: [tCal, tPro, tCarb, tFat],
                  preferences: prefsList,
                  settings: _settings,
                );
              } finally {
                if (context.mounted) setDialogState(() => isCalculating = false);
              }

              if (!context.mounted) return;
              setDialogState(() => result = optResult);

              if (optResult == null && this.mounted) {
                final errorMsg = MealOptimizer.lastErrorMessage ?? 'לא נמצא שילוב חוקי שעומד ביעדים ובחוקי הברזל.';
                showDialog(
                  context: this.context,
                  builder: (popupContext) {
                    return AlertDialog(
                      title: const Text('שגיאה'),
                      content: Text('$errorMsg\nנסה לשנות את היעדים או לבחור מוצרים אחרים.'),
                      actions: [TextButton(onPressed: () => Navigator.pop(popupContext), child: const Text('סגור'))],
                    );
                  },
                );
              }
            }

            Future<void> adjustItem(int foodId, double currentWeight, double change) async {
              if (isCalculating) return;
              double tCal = double.tryParse(calController.text) ?? 0;
              double tPro = double.tryParse(proController.text) ?? 0;
              double tCarb = double.tryParse(carbController.text) ?? 0;
              double tFat = double.tryParse(fatController.text) ?? 0;

              final selectedFoods = _foods.where((f) => selectedFoodIds.contains(f.id)).toList();
              final prefsList = selectedFoods.map((f) => preferences[f.id] ?? 3).toList();

              Map<int, double> currentMealWeights = {};
              for (var id in selectedFoodIds) {
                currentMealWeights[id] = result?.weights[id] ?? 0.0;
              }

              setDialogState(() => isCalculating = true);
              OptimizationResult? optResult;
              try {
                optResult = await MealOptimizer.adjustWeightInIsolate(
                  selectedFoods: selectedFoods,
                  targets: [tCal, tPro, tCarb, tFat],
                  preferences: prefsList,
                  settings: _settings,
                  lockedWeights: lockedWeights,
                  currentWeights: currentMealWeights,
                  adjustedFoodId: foodId,
                  changeAmount: change,
                );
              } finally {
                if (context.mounted) setDialogState(() => isCalculating = false);
              }

              if (!context.mounted) return;
              if (optResult != null) {
                setDialogState(() => result = optResult);
              } else if (this.mounted) {
                final errorMsg = MealOptimizer.lastErrorMessage ?? 'לא ניתן להוסיף יותר מהמוצר הזה בלי לחרוג מהיעדים ובחוקי הברזל.';
                showDialog(
                  context: this.context,
                  builder: (popupContext) {
                    return AlertDialog(
                      title: const Text('לא ניתן להוסיף'),
                      content: Text(errorMsg),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(popupContext), child: const Text('סגור')),
                      ],
                    );
                  },
                );
              }
            }

            Future<void> saveToDiary() async {
              if (result == null || selectedFoodIds.isEmpty) return;
              setDialogState(() => isSaving = true);
              final selectedFoods = _foods
                  .where((food) => selectedFoodIds.contains(food.id))
                  .toList();
              final components = buildCompositeMealComponents(
                foods: selectedFoods,
                weights: result!.weights,
              );
              if (components.isEmpty) {
                setDialogState(() => isSaving = false);
                return;
              }
              try {
                await _dbHelper.insertCompositeMeal(
                  title: mealBuilderCompositeTitle,
                  components: components,
                  date: _todayDate,
                );
                if (context.mounted) {
                  Navigator.pop(mainDialogContext);
                  _loadData();
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('הארוחה נוספה ליומן בהצלחה!')),
                  );
                }
              } catch (error) {
                if (context.mounted) {
                  setDialogState(() => isSaving = false);
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    SnackBar(content: Text('שמירת הארוחה נכשלה: $error')),
                  );
                }
              }
            }

            void copyDetails() {
              if (result == null || selectedFoodIds.isEmpty) return;
              StringBuffer buffer = StringBuffer();
              buffer.writeln('סיכום ארוחה:');
              for (var id in selectedFoodIds) {
                final food = _foods.firstWhere((f) => f.id == id);
                final weight = result!.weights[id] ?? 0;
                if (weight > 0.1) {
                  buffer.writeln('- ${food.name}: ${weight.toStringAsFixed(1)} ${food.isLiquid ? 'מ"ל' : 'גרם'}');
                }
              }
              buffer.writeln('סה"כ: ${result!.totalCalories.toStringAsFixed(1)} קלוריות, ${result!.totalProtein.toStringAsFixed(1)} חלבון, ${result!.totalCarbs.toStringAsFixed(1)} פחמימות, ${result!.totalFat.toStringAsFixed(1)} שומן');
              Clipboard.setData(ClipboardData(text: buffer.toString()));
              ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(content: Text('הפרטים הועתקו ללוח!')));
            }

            final dailyTotals = _calculateDailyTotals();
            double remainingCal = (_targetCalories - dailyTotals.calories).clamp(0, 9999);
            double remainingPro = (_targetProtein - dailyTotals.protein).clamp(0, 9999);
            double remainingCarb = (_targetCarbs - dailyTotals.carbs).clamp(0, 9999);
            double remainingFat = (_targetFat - dailyTotals.fat).clamp(0, 9999);

            return AlertDialog(
              title: const Text('✨ הרכבת ארוחה חכמה'),
              content: SizedBox(
                width: double.maxFinite,
                height: 550,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () {
                          calController.text = remainingCal.toStringAsFixed(0);
                          proController.text = remainingPro.toStringAsFixed(0);
                          carbController.text = remainingCarb.toStringAsFixed(0);
                          fatController.text = remainingFat.toStringAsFixed(0);
                        },
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('מלא יעדים לפי מה שנשאר להיום'),
                      ),
                      const SizedBox(height: 12),
                      const Text('יעדים לארוחה:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: TextField(controller: calController, decoration: const InputDecoration(labelText: 'קלוריות'), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                          const SizedBox(width: 8),
                          Expanded(child: TextField(controller: proController, decoration: const InputDecoration(labelText: 'חלבון'), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: TextField(controller: carbController, decoration: const InputDecoration(labelText: 'פחמימות'), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                          const SizedBox(width: 8),
                          Expanded(child: TextField(controller: fatController, decoration: const InputDecoration(labelText: 'שומן'), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                        ],
                      ),
                      const Divider(height: 30),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const ValueKey('meal_builder_search'),
                              controller: searchController,
                              decoration: InputDecoration(
                                labelText: 'חפש מוצר...',
                                prefixIcon: const Icon(Icons.search),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onChanged: (val) => performSearch(val, setDialogState),
                            ),
                          ),
                          IconButton(
                            icon: Icon(showOnlyFavorites ? Icons.star : Icons.star_border, color: Colors.amber),
                            onPressed: () {
                              setDialogState(() {
                                showOnlyFavorites = !showOnlyFavorites;
                              });
                              performSearch(searchController.text, setDialogState, immediate: true);
                            },
                          )
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text('בחר מוצרים (עד 10):', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 250,
                        child: filteredFoods.isEmpty
                            ? const Center(child: Text('לא נמצאו מוצרים'))
                            : ListView.builder(
                          key: const ValueKey('meal_builder_food_list'),
                          itemCount: filteredFoods.length,
                          itemBuilder: (context, index) {
                            final food = filteredFoods[index];
                            bool isSelected = selectedFoodIds.contains(food.id);
                            int pref = preferences[food.id] ?? 3;

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              child: Column(
                                children: [
                                  CheckboxListTile(
                                    dense: true,
                                    title: Row(
                                      children: [
                                        if (food.isFavorite) const Padding(
                                          padding: EdgeInsets.only(right: 4.0),
                                          child: Icon(Icons.star, color: Colors.amber, size: 16),
                                        ),
                                        Expanded(child: Text(food.name)),
                                      ],
                                    ),
                                    value: isSelected,
                                    onChanged: (val) {
                                      setDialogState(() {
                                        if (val == true && selectedFoodIds.length < 10) {
                                          selectedFoodIds.add(food.id!);
                                          preferences[food.id!] = 3;
                                        } else if (val == false) {
                                          selectedFoodIds.remove(food.id);
                                          lockedWeights.remove(food.id);
                                        }
                                      });
                                    },
                                  ),
                                  if (isSelected)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 4.0, left: 16, right: 16),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const Text('פחות ', style: TextStyle(fontSize: 10)),
                                          ...List.generate(5, (index) {
                                            return InkWell(
                                              onTap: () => setDialogState(() => preferences[food.id!] = index + 1),
                                              child: Icon(index < pref ? Icons.star : Icons.star_border, color: Colors.amber, size: 18),
                                            );
                                          }),
                                          const Text(' יותר', style: TextStyle(fontSize: 10)),
                                        ],
                                      ),
                                    )
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: isCalculating ? null : runOptimization,
                        icon: isCalculating
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.auto_awesome),
                        label: Text(isCalculating ? 'מחשב...' : 'חשב משקלים'),
                      ),
                      if (result != null) ...[
                        const Divider(height: 30),
                        const Text('התוצאה (כוונן ידנית ונעל מוצרים):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                        const SizedBox(height: 8),
                        ...selectedFoodIds.map((id) {
                          final food = _foods.firstWhere((f) => f.id == id);
                          final weight = result!.weights[id] ?? 0;
                          final isLocked = lockedWeights.containsKey(id);

                          return Card(
                            elevation: 0,
                            color: isLocked ? Colors.orange.shade50 : Colors.blue.shade50,
                            child: ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                              title: Text(food.name, style: const TextStyle(fontSize: 14)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(isLocked ? Icons.lock : Icons.lock_open, color: isLocked ? Colors.orange : Colors.grey),
                                    onPressed: () {
                                      setDialogState(() {
                                        if (isLocked) {
                                          lockedWeights.remove(id);
                                        } else {
                                          lockedWeights[id] = weight;
                                        }
                                      });
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20),
                                    onPressed: weight > 0 && !isCalculating ? () => adjustItem(id, weight, -5) : null,
                                  ),
                                  Text('${weight.toStringAsFixed(1)} ${food.isLiquid ? 'מ"ל' : 'גרם'}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blue)),
                                  IconButton(
                                    icon: const Icon(Icons.add_circle_outline, color: Colors.green, size: 20),
                                    onPressed: isCalculating ? null : () => adjustItem(id, weight, 5),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                        const Divider(),
                        const Text('סיכום תזונתי של הארוחה:', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        _buildCompareRow('קלוריות', result!.totalCalories, double.tryParse(calController.text) ?? 0, 'קק"ל'),
                        _buildCompareRow('חלבון', result!.totalProtein, double.tryParse(proController.text) ?? 0, 'גר'),
                        _buildCompareRow('פחמימות', result!.totalCarbs, double.tryParse(carbController.text) ?? 0, 'גר'),
                        _buildCompareRow('שומן', result!.totalFat, double.tryParse(fatController.text) ?? 0, 'גר'),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: isSaving ? null : saveToDiary,
                                icon: isSaving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.save),
                                label: const Text('הוסף ליומן'),
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: copyDetails,
                                icon: const Icon(Icons.copy),
                                label: const Text('העתק'),
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
                              ),
                            ),
                          ],
                        )
                      ]
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(mainDialogContext), child: const Text('סגור')),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildCompareRow(String label, double actual, double target, String unit) {
    double diff = actual - target;
    bool isGood = diff.abs() < target * 0.05;
    Color color = isGood ? Colors.green : (diff > 0 ? Colors.orange : Colors.blueGrey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('$label:', style: const TextStyle(fontSize: 13)),
          Text('${actual.toStringAsFixed(1)} $unit (יעד: ${target.toStringAsFixed(0)})', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dailyTotals = _calculateDailyTotals();
    Food? selectedFood = _selectedFoodId != null ? _foods.firstWhere((f) => f.id == _selectedFoodId) : null;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fitness_center, color: Color(0xFF00FF87)),
            const SizedBox(width: 8),
            const Text('מעקב מאקרו', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'הרכבת ארוחה חכמה',
            onPressed: _showMealBuilderDialog,
          ),
          IconButton(
            icon: const Icon(Icons.book),
            tooltip: 'ניהול מאכלים ומתכונים',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (context) => const ManageFoodsScreen()));
              _loadData();
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'עדכן יעדים להיום',
            onPressed: _editTargets,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'הגדרות חוקי ברזל',
            onPressed: _showRuleSettingsDialog,
          ),
          if (widget.username != null)
            PopupMenuButton<String>(
              tooltip: 'מחובר בתור ${widget.username}',
              onSelected: (value) {
                if (value == 'signout') widget.onSignOut?.call();
              },
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  enabled: false,
                  child: Row(children: [const Icon(Icons.person_outline), const SizedBox(width: 8), Text(widget.username!)]),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(value: 'signout', child: Text('התנתקות / החלפת משתמש')),
              ],
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1A1A2E),
              Color(0xFF16213E),
              Color(0xFF0A0E21),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: () => _showAiMealEditor(),
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('✨ סורק ומפענח AI'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00A86B),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        InkWell(
                          onTap: _showFoodPicker,
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'בחר מאכל / מתכון',
                              border: InputBorder.none,
                              suffixIcon: Icon(Icons.arrow_drop_down),
                            ),
                            child: Text(
                              selectedFood?.name ?? 'לחץ לבחירת מאכל...',
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _weightController,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(
                                  labelText: selectedFood?.isRecipe == true ? 'מספר מנות' : (selectedFood?.isLiquid == true ? 'נפח (מ"ל)' : 'משקל (גרם)'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 80,
                              child: ElevatedButton(
                                onPressed: _addMeal,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 0),
                                ),
                                child: const Text('הוסף', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                  child: Column(
                    children: [
                      const Text('סה"כ היום (מתוך יעד)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70)),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildMacroText('קלוריות', dailyTotals.calories, _targetCalories, 'קק"ל'),
                          _buildMacroText('חלבון', dailyTotals.protein, _targetProtein, 'גר'),
                          _buildMacroText('פחמימות', dailyTotals.carbs, _targetCarbs, 'גר'),
                          _buildMacroText('שומן', dailyTotals.fat, _targetFat, 'גר'),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Text('ארוחות היום:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white70)),
                const SizedBox(height: 10),
                Expanded(
                  child: _todayMeals.isEmpty
                      ? const Center(child: Text('לא הוזנו ארוחות להיום', style: TextStyle(color: Colors.white54)))
                      : ListView.builder(
                    itemCount: _todayMeals.length,
                    itemBuilder: (context, index) {
                      final meal = _todayMeals[index];
                      final isComposite = meal['components_json'] is String;
                      final componentCount = isComposite ? _componentCount(meal['components_json']) : 0;
                      final isLiquid = meal['is_liquid'] == 1;
                      final isRecipe = meal['is_recipe'] == 1;
                      final servings = (meal['servings'] as num?)?.toDouble() ?? 1.0;
                      double displayAmount = meal['weight_grams'];
                      String unit = isLiquid ? 'מ"ל' : 'גרם';
                      if (isRecipe) {
                        displayAmount = (meal['weight_grams'] / (100 / servings));
                        unit = 'מנות';
                      }
                      final result = Calculator.calculateFromWeight(
                        weightGrams: meal['weight_grams'],
                        calPer100g: meal['calories_per_100g'],
                        proPer100g: meal['protein_per_100g'],
                        carbPer100g: meal['carbs_per_100g'],
                        fatPer100g: meal['fat_per_100g'],
                      );
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: isComposite ? const Icon(Icons.auto_awesome, color: Color(0xFF00FF87)) : null,
                          title: Text(isComposite ? (meal['meal_title']?.toString().isNotEmpty == true ? meal['meal_title'] : meal['food_name']) : meal['food_name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            isComposite
                                ? '$componentCount רכיבים · ${result.calDisplay} קק״ל · חלבון ${result.protein.toStringAsFixed(1)}ג׳ · פחמימות ${result.carbs.toStringAsFixed(1)}ג׳ · שומן ${result.fat.toStringAsFixed(1)}ג׳\nהקישו לצפייה ועריכה'
                                : '${displayAmount.toStringAsFixed(1)} $unit',
                            style: const TextStyle(color: Colors.white60),
                            maxLines: 2,
                          ),
                          onTap: isComposite ? () => _showAiMealEditor(existingMeal: meal) : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('${result.calDisplay} קק"ל', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF00FF87))),
                              IconButton(icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: () => _deleteMeal(meal['entry_id'])),
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
        ),
      ),
    );
  }

  int _componentCount(dynamic raw) {
    try {
      return (jsonDecode(raw as String) as List).length;
    } catch (_) {
      return 0;
    }
  }

  Widget _buildMacroText(String label, double current, double target, String unit) {
    bool isOver = current > target;
    Color valueColor = isOver ? Colors.red.shade700 : const Color(0xFF00FF87);
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        Text('${current.toStringAsFixed(1)} / ${target.toStringAsFixed(0)}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: valueColor)),
        Text(unit, style: const TextStyle(fontSize: 10, color: Colors.white54)),
      ],
    );
  }
}