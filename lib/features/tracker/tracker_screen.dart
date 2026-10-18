import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../core/calculator.dart';
import '../../core/meal_optimizer.dart';
import '../../data/database_helper.dart';
import '../../data/models/food.dart';
import '../manage_foods_screen.dart';

class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

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
    final targets = await _dbHelper.getTargetsForDate(_todayDate);
    final settings = await _dbHelper.getSettings();

    setState(() {
      _foods = foods;
      _todayMeals = meals;
      _settings = settings;

      if (targets != null) {
        _targetCalories = targets['calories'];
        _targetProtein = targets['protein'];
        _targetCarbs = targets['carbs'];
        _targetFat = targets['fat'];
      } else {
        _dbHelper.saveTargetsForDate(_todayDate, _targetCalories, _targetProtein, _targetCarbs, _targetFat);
      }

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

  void _editTargets() {
    final calController = TextEditingController(text: _targetCalories.toStringAsFixed(0));
    final proController = TextEditingController(text: _targetProtein.toStringAsFixed(0));
    final carbController = TextEditingController(text: _targetCarbs.toStringAsFixed(0));
    final fatController = TextEditingController(text: _targetFat.toStringAsFixed(0));

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('עדכון יעדים להיום'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: calController, decoration: const InputDecoration(labelText: 'קלוריות'), keyboardType: TextInputType.number),
                TextField(controller: proController, decoration: const InputDecoration(labelText: 'חלבון (גר)'), keyboardType: TextInputType.number),
                TextField(controller: carbController, decoration: const InputDecoration(labelText: 'פחמימות (גר)'), keyboardType: TextInputType.number),
                TextField(controller: fatController, decoration: const InputDecoration(labelText: 'שומן (גר)'), keyboardType: TextInputType.number),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
            ElevatedButton(
              onPressed: () async {
                double newCal = double.tryParse(calController.text) ?? _targetCalories;
                double newPro = double.tryParse(proController.text) ?? _targetProtein;
                double newCarb = double.tryParse(carbController.text) ?? _targetCarbs;
                double newFat = double.tryParse(fatController.text) ?? _targetFat;

                await _dbHelper.saveTargetsForDate(_todayDate, newCal, newPro, newCarb, newFat);

                if (context.mounted) Navigator.pop(context);
                _loadData();
              },
              child: const Text('שמור'),
            ),
          ],
        );
      },
    );
  }

  void _showRuleSettingsDialog() {
    String calMode = _settings['cal_mode'] ?? 'down';
    double calPct = _settings['cal_pct'] ?? 10.0;
    String proMode = _settings['pro_mode'] ?? 'up';
    double proPct = _settings['pro_pct'] ?? 10.0;
    String carbMode = _settings['carb_mode'] ?? 'both';
    double carbPct = _settings['carb_pct'] ?? 10.0;
    String fatMode = _settings['fat_mode'] ?? 'free';
    double fatPct = _settings['fat_pct'] ?? 0.0;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Widget buildRuleRow(String title, String currentMode, double currentPct, Function(String) onModeChange, Function(double) onPctChange) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  Row(
                    children: [
                      DropdownButton<String>(
                        value: currentMode,
                        items: const [
                          DropdownMenuItem(value: 'free', child: Text('ללא הגבלה (גמיש)')),
                          DropdownMenuItem(value: 'up', child: Text('למעלה בלבד')),
                          DropdownMenuItem(value: 'down', child: Text('למטה בלבד')),
                          DropdownMenuItem(value: 'both', child: Text('שני הכיוונים')),
                        ],
                        onChanged: (val) {
                          if (val != null) setDialogState(() => onModeChange(val));
                        },
                      ),
                      if (currentMode != 'free') ...[
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 60,
                          child: TextField(
                            controller: TextEditingController(text: currentPct.toStringAsFixed(0)),
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: '%', isDense: true),
                            onChanged: (val) {
                              double pct = double.tryParse(val) ?? 0;
                              onPctChange(pct);
                            },
                          ),
                        ),
                      ]
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
                    buildRuleRow('קלוריות:', calMode, calPct, (v) => calMode = v, (v) => calPct = v),
                    buildRuleRow('חלבון:', proMode, proPct, (v) => proMode = v, (v) => proPct = v),
                    buildRuleRow('פחמימות:', carbMode, carbPct, (v) => carbMode = v, (v) => carbPct = v),
                    buildRuleRow('שומן:', fatMode, fatPct, (v) => fatMode = v, (v) => fatPct = v),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('ביטול'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    Map<String, dynamic> newSettings = {
                      'cal_mode': calMode, 'cal_pct': calPct,
                      'pro_mode': proMode, 'pro_pct': proPct,
                      'carb_mode': carbMode, 'carb_pct': carbPct,
                      'fat_mode': fatMode, 'fat_pct': fatPct,
                    };
                    await _dbHelper.saveSettings(newSettings);
                    if (context.mounted) Navigator.pop(context);
                    _loadData();
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

  void _showMealBuilderDialog() {
    final calController = TextEditingController();
    final proController = TextEditingController();
    final carbController = TextEditingController();
    final fatController = TextEditingController();
    final searchController = TextEditingController();

    List<int> selectedFoodIds = [];
    Map<int, int> preferences = {};

    OptimizationResult? result;
    bool isSaving = false;

    showDialog(
      context: context,
      builder: (mainDialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {

            void runOptimization() {
              if (selectedFoodIds.isEmpty) return;

              double tCal = double.tryParse(calController.text) ?? 0;
              double tPro = double.tryParse(proController.text) ?? 0;
              double tCarb = double.tryParse(carbController.text) ?? 0;
              double tFat = double.tryParse(fatController.text) ?? 0;

              if (tCal == 0 && tPro == 0 && tCarb == 0 && tFat == 0) return;

              final selectedFoods = _foods.where((f) => selectedFoodIds.contains(f.id)).toList();
              final prefsList = selectedFoods.map((f) => preferences[f.id] ?? 3).toList();

              final optResult = MealOptimizer.findOptimalWeights(
                selectedFoods: selectedFoods,
                targets: [tCal, tPro, tCarb, tFat],
                preferences: prefsList,
                settings: _settings,
              );

              setDialogState(() {
                result = optResult;
              });

              if (optResult == null) {
                showDialog(
                  context: this.context,
                  builder: (popupContext) {
                    return AlertDialog(
                      title: const Text('שגיאה'),
                      content: const Text('לא נמצא שילוב חוקי שעומד ביעדים ובחוקי הברזל.\nנסה לשנות את היעדים או לבחור מוצרים אחרים.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(popupContext), child: const Text('סגור')),
                      ],
                    );
                  },
                );
              }
            }

            void adjustItem(int foodId, double change) {
              double tCal = double.tryParse(calController.text) ?? 0;
              double tPro = double.tryParse(proController.text) ?? 0;
              double tCarb = double.tryParse(carbController.text) ?? 0;
              double tFat = double.tryParse(fatController.text) ?? 0;

              final selectedFoods = _foods.where((f) => selectedFoodIds.contains(f.id)).toList();
              final prefsList = selectedFoods.map((f) => preferences[f.id] ?? 3).toList();

              List<double> currentWeights = selectedFoods.map((f) => result?.weights[f.id] ?? 0.0).toList();

              final optResult = MealOptimizer.adjustWeight(
                selectedFoods: selectedFoods,
                targets: [tCal, tPro, tCarb, tFat],
                preferences: prefsList,
                settings: _settings,
                lockedFoodId: foodId,
                currentWeights: currentWeights,
                changeAmount: change,
              );

              if (optResult != null) {
                setDialogState(() { result = optResult; });
              } else {
                showDialog(
                  context: this.context,
                  builder: (popupContext) {
                    return AlertDialog(
                      title: const Text('לא ניתן להוסיף'),
                      content: const Text('לא ניתן להוסיף יותר מהמוצר הזה בלי לחרוג מהיעדים ובחוקי הברזל.'),
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
              for (var id in selectedFoodIds) {
                final food = _foods.firstWhere((f) => f.id == id);
                final weight = result!.weights[id] ?? 0;
                if (weight > 0.1) await _dbHelper.insertMealEntry(id, weight, _todayDate);
              }
              if (context.mounted) {
                Navigator.pop(mainDialogContext);
                _loadData();
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(content: Text('הארוחה נוספה ליומן בהצלחה!')),
                );
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
                  buffer.writeln('- ${food.name}: ${weight.toStringAsFixed(1)} ${food.isLiquid ? 'מ״ל' : 'גרם'}');
                }
              }
              buffer.writeln('סה״כ: ${result!.totalCalories.toStringAsFixed(1)} קלוריות, ${result!.totalProtein.toStringAsFixed(1)} חלבון, ${result!.totalCarbs.toStringAsFixed(1)} פחמימות, ${result!.totalFat.toStringAsFixed(1)} שומן');
              Clipboard.setData(ClipboardData(text: buffer.toString()));
              ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(content: Text('הפרטים הועתקו ללוח!')));
            }

            final dailyTotals = _calculateDailyTotals();
            double remainingCal = (_targetCalories - dailyTotals.calories).clamp(0, 9999);
            double remainingPro = (_targetProtein - dailyTotals.protein).clamp(0, 9999);
            double remainingCarb = (_targetCarbs - dailyTotals.carbs).clamp(0, 9999);
            double remainingFat = (_targetFat - dailyTotals.fat).clamp(0, 9999);

            List<Food> filteredFoods = _foods.where((f) => f.name.contains(searchController.text)).toList();

            return AlertDialog(
              title: const Text('✨ הרכבת ארוחה חכמה'),
              content: SingleChildScrollView(
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
                        Expanded(child: TextField(controller: calController, decoration: const InputDecoration(labelText: 'קלוריות'), keyboardType: TextInputType.number)),
                        const SizedBox(width: 8),
                        Expanded(child: TextField(controller: proController, decoration: const InputDecoration(labelText: 'חלבון'), keyboardType: TextInputType.number)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: TextField(controller: carbController, decoration: const InputDecoration(labelText: 'פחמימות'), keyboardType: TextInputType.number)),
                        const SizedBox(width: 8),
                        Expanded(child: TextField(controller: fatController, decoration: const InputDecoration(labelText: 'שומן'), keyboardType: TextInputType.number)),
                      ],
                    ),
                    const Divider(height: 30),
                    TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        labelText: 'חפש מוצר...',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onChanged: (val) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 8),
                    const Text('בחר מוצרים (עד 10):', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ...filteredFoods.map((food) {
                      bool isSelected = selectedFoodIds.contains(food.id);
                      int pref = preferences[food.id] ?? 3;
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 2),
                        child: Column(
                          children: [
                            CheckboxListTile(
                              dense: true,
                              title: Text(food.name),
                              value: isSelected,
                              onChanged: (val) {
                                setDialogState(() {
                                  if (val == true && selectedFoodIds.length < 10) {
                                    selectedFoodIds.add(food.id!);
                                    preferences[food.id!] = 3;
                                  } else if (val == false) {
                                    selectedFoodIds.remove(food.id);
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
                    }).toList(),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: runOptimization,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('חשב משקלים'),
                    ),
                    if (result != null) ...[
                      const Divider(height: 30),
                      const Text('התוצאה (כוונן ידנית):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                      const SizedBox(height: 8),
                      ...selectedFoodIds.map((id) {
                        final food = _foods.firstWhere((f) => f.id == id);
                        final weight = result!.weights[id] ?? 0;
                        return Card(
                          elevation: 0,
                          color: Colors.blue.shade50,
                          child: ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                            title: Text(food.name, style: const TextStyle(fontSize: 14)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.remove_circle_outline,
                                    color: Colors.red,
                                    size: 20,
                                  ),
                                  onPressed: weight > 0
                                      ? () => adjustItem(id, -5)
                                      : null,
                                ),
                                Text(
                                  '${weight.toStringAsFixed(1)} ${food.isLiquid ? 'מ״ל' : 'גרם'}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: Colors.blue,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.add_circle_outline,
                                    color: Colors.green,
                                    size: 20,
                                  ),
                                  onPressed: () => adjustItem(id, 5),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                      const Divider(),
                      const Text('סיכום תזונתי של הארוחה:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      _buildCompareRow('קלוריות', result!.totalCalories, double.tryParse(calController.text) ?? 0, 'קק״ל'),
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
            const Text('מעקב מאקרו'),
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
              Color(0xFF0F3460),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        DropdownButtonFormField<int>(
                          initialValue: _selectedFoodId,
                          decoration: const InputDecoration(labelText: 'בחר מאכל / מתכון', border: InputBorder.none),
                          hint: Text(_foods.isEmpty ? 'טוען נתונים...' : 'בחר מהרשימה...'),
                          items: _foods.map((food) => DropdownMenuItem<int>(value: food.id, child: Text(food.name))).toList(),
                          onChanged: (val) => setState(() => _selectedFoodId = val),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _weightController,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(
                                  labelText: selectedFood?.isRecipe == true ? 'מספר מנות' : (selectedFood?.isLiquid == true ? 'נפח (מ״ל)' : 'משקל (גרם)'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 80,
                              child: ElevatedButton(
                                onPressed: _addMeal,
                                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 0)),
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
                      const Text('סה״כ היום (מתוך יעד)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70)),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildMacroText('קלוריות', dailyTotals.calories, _targetCalories, 'קק״ל'),
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
                      final isLiquid = meal['is_liquid'] == 1;
                      final isRecipe = meal['is_recipe'] == 1;
                      final servings = (meal['servings'] as num?)?.toDouble() ?? 1.0;
                      double displayAmount = meal['weight_grams'];
                      String unit = isLiquid ? 'מ״ל' : 'גרם';
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
                          title: Text(meal['food_name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('${displayAmount.toStringAsFixed(1)} $unit', style: const TextStyle(color: Colors.white60)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('${result.calDisplay} קק״ל', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF00FF87))),
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

  Widget _buildMacroText(String label, double current, double target, String unit) {
    bool isOver = current > target;
    Color valueColor = isOver ? Colors.red.shade700 : Colors.green.shade800;
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        Text('${current.toStringAsFixed(1)} / ${target.toStringAsFixed(0)}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: valueColor)),
        Text(unit, style: const TextStyle(fontSize: 10, color: Colors.black54)),
      ],
    );
  }
}