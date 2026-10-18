import 'dart:async';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _loadFoods();
  }

  Future<void> _loadFoods() async {
    final foods = await _dbHelper.getAllFoods();
    setState(() {
      _foods = foods;
    });
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

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
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
                    Row(
                      children: [
                        const Expanded(child: Text('האם זה נוזל?')),
                        Checkbox(
                          value: isLiquid,
                          onChanged: (val) {
                            setDialogState(() {
                              isLiquid = val ?? false;
                            });
                          },
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
                          keyboardType: TextInputType.number
                      ),

                    const Divider(),
                    Text(isRecipe ? 'סך הערכים של כל המתכון:' : 'ערכים תזונתיים ל-100 (גרם/מ"ל):', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
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
                    if (nameController.text.isEmpty) return;

                    double servings = double.tryParse(servingsController.text) ?? 1.0;
                    if (servings <= 0) servings = 1.0;

                    final foodObj = Food(
                      id: existingFood?.id,
                      name: nameController.text,
                      caloriesPer100g: double.tryParse(calController.text) ?? 0,
                      proteinPer100g: double.tryParse(proController.text) ?? 0,
                      carbsPer100g: double.tryParse(carbController.text) ?? 0,
                      fatPer100g: double.tryParse(fatController.text) ?? 0,
                      isLiquid: isLiquid,
                      isRecipe: isRecipe,
                      servings: servings,
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
      ),
      body: _foods.isEmpty
          ? const Center(child: Text('אין מאכלים עדיין. הוסף אחד!'))
          : ListView.builder(
        itemCount: _foods.length,
        itemBuilder: (context, index) {
          final food = _foods[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListTile(
              onTap: () => _showFoodDialog(existingFood: food),
              title: Text(food.name),
              subtitle: Text(
                  food.isRecipe
                      ? 'מתכון: ${food.servings.toStringAsFixed(0)} מנות (${food.caloriesPer100g.toStringAsFixed(0)} קק"ל למנה)'
                      : '${food.caloriesPer100g} קק"ל ל-100${food.isLiquid ? 'מ"ל' : 'גרם'}'
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.edit, color: Colors.blueGrey, size: 20),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showFoodDialog(),
        icon: const Icon(Icons.add),
        label: const Text('הוסף מאכל'),
      ),
    );
  }
}