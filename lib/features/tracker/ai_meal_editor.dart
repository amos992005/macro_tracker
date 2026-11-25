import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/ai_meal_utils.dart';
import '../../core/search_utils.dart';
import '../../data/database_helper.dart';
import '../../data/macro_sync_service.dart';
import '../../data/models/food.dart';

class AiMealEditor extends StatefulWidget {
  const AiMealEditor({
    super.key,
    required this.foods,
    this.initialTitle,
    this.initialItems,
  });

  final List<Food> foods;
  final String? initialTitle;
  final List<Map<String, dynamic>>? initialItems;

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required List<Food> foods,
    String? title,
    List<Map<String, dynamic>>? items,
  }) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => AiMealEditor(
        foods: foods,
        initialTitle: title,
        initialItems: items,
      ),
    );
  }

  @override
  State<AiMealEditor> createState() => _AiMealEditorState();
}

class _AiMealEditorState extends State<AiMealEditor> {
  final _dbHelper = DatabaseHelper();
  final _description = TextEditingController();
  final _title = TextEditingController();
  final _correction = TextEditingController();
  final _picker = ImagePicker();
  final List<_AiItem> _items = [];
  Uint8List? _imageBytes;
  String? _imageMime;
  String? _error;
  String? _confidenceNote;
  bool _pro = false;
  bool _saveAsRecipe = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _title.text = widget.initialTitle ?? '';
    for (final item in widget.initialItems ?? const []) {
      _items.add(_AiItem.fromMap(item, foods: widget.foods, preserveStoredUnit: true));
    }
  }

  @override
  void dispose() {
    _description.dispose();
    _title.dispose();
    _correction.dispose();
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> _selectImage(ImageSource source) async {
    try {
      final image = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );
      if (image == null) return;
      final bytes = await image.readAsBytes();
      if (bytes.length > 6 * 1024 * 1024) {
        setState(() => _error = 'התמונה גדולה מדי. בחרו תמונה קטנה מ-6MB.');
        return;
      }
      final lowerPath = image.name.toLowerCase();
      setState(() {
        _imageBytes = bytes;
        _imageMime = lowerPath.endsWith('.png') ? 'image/png' :
            lowerPath.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
        _error = null;
      });
    } catch (error) {
      setState(() => _error = 'לא ניתן לפתוח תמונה: $error');
    }
  }

  Future<void> _analyze() async {
    if (_description.text.trim().isEmpty && _imageBytes == null) {
      setState(() => _error = 'כתבו תיאור קצר או בחרו תמונה.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await MacroSyncService.instance.analyzeMeal(
        text: _description.text.trim(),
        imageBytes: _imageBytes,
        mimeType: _imageMime,
        pro: _pro,
      );
      for (final item in _items) {
        item.dispose();
      }
      final rawItems = (result['items'] as List? ?? const []).whereType<Map>();
      _items
        ..clear()
        ..addAll(rawItems.map((item) => _AiItem.fromMap(
              Map<String, dynamic>.from(item),
              foods: widget.foods,
            )));
      _title.text = result['meal_title']?.toString() ?? 'ארוחה מפוענחת';
      setState(() {
        _error = null;
        _confidenceNote = result['confidence_note']?.toString();
      });
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _correctMeal() async {
    final correctionPrompt = _correction.text.trim();
    if (correctionPrompt.isEmpty) {
      setState(() => _error = 'כתבו מה תרצו לדייק או לתקן בארוחה.');
      return;
    }
    if (_items.isEmpty) return;

    final previousItems = _items.map((item) => item.toMap()).toList();
    final matchedFoodsByName = <String, Food>{
      for (final item in _items)
        if (item.matchedFood != null) item.name: item.matchedFood!,
    };
    final payload = buildMealCorrectionPayload(
      mealTitle: _title.text,
      items: previousItems,
      correctionPrompt: correctionPrompt,
      pro: _pro,
    );

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await MacroSyncService.instance.analyzeMeal(
        text: '',
        pro: _pro,
        currentMeal: Map<String, dynamic>.from(payload['current_meal'] as Map),
        correctionPrompt: payload['correction_prompt'] as String,
      );
      final correctedItems = (result['items'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (correctedItems.isEmpty) {
        throw StateError('לא התקבלה ארוחה מעודכנת מה-AI.');
      }
      final mergedItems = mergeAiMealCorrectionItems(
        previousItems: previousItems,
        correctedItems: correctedItems,
        matchedFoodsByName: matchedFoodsByName,
      );
      final replacementItems = mergedItems
          .map((item) => _AiItem.fromMap(item, foods: widget.foods))
          .toList();
      if (!mounted) {
        for (final item in replacementItems) {
          item.dispose();
        }
        return;
      }

      for (final item in _items) {
        item.dispose();
      }
      _items
        ..clear()
        ..addAll(replacementItems);
      _title.text = result['meal_title']?.toString() ?? _title.text;
      _correction.clear();
      setState(() {
        _confidenceNote = result['confidence_note']?.toString();
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'עדכון הארוחה נכשל: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addManualItem() async {
    final selected = await showDialog<Food>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        List<Food> results = SearchUtils.filterAndSortFoods(widget.foods, '');
        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: const Text('הוספת רכיב מהמאגר'),
            content: SizedBox(
              width: 420,
              height: 360,
              child: Column(children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'חפשו מאכל'),
                  onChanged: (value) => setState(() => results = SearchUtils.filterAndSortFoods(widget.foods, value).take(30).toList()),
                ),
                const SizedBox(height: 8),
                Expanded(child: ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (_, index) {
                    final food = results[index];
                    return ListTile(
                      title: Text(food.name),
                      subtitle: Text('${food.caloriesPer100g.toStringAsFixed(0)} קק״ל ל-100${food.isLiquid ? ' מ״ל' : ' גרם'}'),
                      onTap: () => Navigator.pop(context, food),
                    );
                  },
                )),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול'))],
          );
        });
      },
    );
    if (selected == null) return;
    setState(() {
      _items.add(_AiItem(
        name: selected.name,
        searchQuery: selected.name,
        grams: 100,
        liquid: selected.isLiquid,
        assumed: false,
        calories: selected.caloriesPer100g,
        matchedFood: selected,
        protein: selected.proteinPer100g,
        carbs: selected.carbsPer100g,
        fat: selected.fatPer100g,
      ));
    });
  }

  Future<void> _replaceFromFood(_AiItem item) async {
    final queryController = TextEditingController(text: item.searchQuery);
    final selected = await showDialog<Food>(
      context: context,
      builder: (context) {
        List<Food> results = SearchUtils.filterAndSortFoods(widget.foods, queryController.text).take(30).toList();
        return StatefulBuilder(builder: (context, setState) => AlertDialog(
          title: const Text('החלפה ממאגר המזונות'),
          content: SizedBox(
            width: 420,
            height: 360,
            child: Column(children: [
              TextField(
                controller: queryController,
                autofocus: true,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'חיפוש בעברית במאגר המזונות'),
                onChanged: (value) => setState(() => results = SearchUtils.filterAndSortFoods(widget.foods, value).take(30).toList()),
              ),
              const SizedBox(height: 8),
              Expanded(child: ListView.builder(
                itemCount: results.length,
                itemBuilder: (_, index) {
                  final food = results[index];
                  return ListTile(
                    title: Text(food.name),
                    subtitle: Text('${food.caloriesPer100g.toStringAsFixed(0)} קק״ל ל-100${food.isLiquid ? ' מ״ל' : ' גרם'}'),
                    onTap: () => Navigator.pop(context, food),
                  );
                },
              )),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול'))],
        ));
      },
    );
    queryController.dispose();
    if (selected == null) return;
    setState(() => item.replaceWith(selected));
  }

  Future<void> _saveItemToMyFoods(_AiItem item) async {
    if (item.isSavingToMyFoods || item.matchedFood != null) return;
    setState(() => item.isSavingToMyFoods = true);
    try {
      final result = await _dbHelper.insertFoodIfAbsent(
        Food(
          name: item.name.trim(),
          caloriesPer100g: item.calories,
          proteinPer100g: item.protein,
          carbsPer100g: item.carbs,
          fatPer100g: item.fat,
          isLiquid: item.liquid,
        ),
      );
      if (!mounted) return;
      setState(() {
        item.replaceWith(result.food);
        for (final other in _items) {
          if (!identical(other, item) &&
              other.name.trim() == result.food.name.trim()) {
            other.replaceWith(result.food);
          }
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.inserted
                ? 'המזון נשמר למאגר שלי'
                : 'המזון כבר קיים במאגר וקושר לרכיב',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן לשמור למאגר: $error')),
      );
    } finally {
      if (mounted) setState(() => item.isSavingToMyFoods = false);
    }
  }

  double _total(String nutrient) => _items.fold<double>(0, (sum, item) {
    final value = switch (nutrient) {
      'calories' => item.calories,
      'protein' => item.protein,
      'carbs' => item.carbs,
      _ => item.fat,
    };
    return sum + item.grams * value / 100;
  });

  void _save() {
    if (_items.isEmpty) {
      setState(() => _error = 'הוסיפו לפחות רכיב אחד לפני השמירה.');
      return;
    }
    if (_items.any((item) => !item.grams.isFinite || item.grams <= 0)) {
      setState(() => _error = 'יש להזין משקל חיובי לכל רכיב.');
      return;
    }
    Navigator.pop(context, {
      'title': _title.text.trim().isEmpty ? 'ארוחה מפוענחת' : _title.text.trim(),
      'items': _items.map((item) => item.toMap()).toList(),
      'save_as_recipe': _saveAsRecipe,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('✨ סורק ומפענח AI'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: _description,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'תיאור ארוחה, מתכון או הערות',
                hintText: 'למשל: אורז בלי שמן, חומוס של מותג מסוים; אכלתי שתי מנות',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _selectImage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('צילום'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _selectImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(_imageBytes == null ? 'בחירת תמונה' : 'תמונה נבחרה ✓'),
              ),
              Switch.adaptive(value: _pro, onChanged: _busy ? null : (value) => setState(() => _pro = value)),
              const Text('ניתוח מעמיק במיוחד (Pro)', style: TextStyle(fontSize: 12)),
            ]),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _analyze,
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome),
              label: Text(_busy ? 'מפענח…' : 'נתח ארוחה'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            if (_confidenceNote != null) ...[
              const SizedBox(height: 8),
              Text('הערת AI: $_confidenceNote', style: const TextStyle(color: Colors.amber, fontSize: 12)),
            ],
            if (_items.isNotEmpty) ...[
              const Divider(height: 24),
              TextField(
                controller: _title,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'שם הארוחה'),
              ),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextField(
                    controller: _correction,
                    enabled: !_busy,
                    minLines: 1,
                    maxLines: 2,
                    textDirection: TextDirection.rtl,
                    decoration: const InputDecoration(
                      labelText: 'דייק או תקן עם AI',
                      hintText: 'למשל: בלי שמן, הוסף כף טחינה',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _correctMeal,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_fix_high, size: 18),
                  label: Text(_busy ? 'מעדכן…' : 'עדכן'),
                ),
              ]),
              const SizedBox(height: 8),
              AbsorbPointer(
                absorbing: _busy,
                child: Column(children: [
                  ..._items.asMap().entries.map((entry) => _buildItemCard(entry.key, entry.value)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(onPressed: _addManualItem, icon: const Icon(Icons.add), label: const Text('הוספת רכיב מהמאגר')),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _saveAsRecipe,
                    onChanged: (value) => setState(() => _saveAsRecipe = value ?? false),
                    title: const Text('שמור גם כמתכון במאגר המזונות'),
                    subtitle: const Text('הערכים יישמרו למנה אחת כפי שנערכה כאן.'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  Card(
                    color: Colors.black26,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(alignment: WrapAlignment.spaceAround, spacing: 12, runSpacing: 8, children: [
                        _totalLabel('קלוריות', _total('calories'), 'קק״ל'),
                        _totalLabel('חלבון', _total('protein'), 'ג׳'),
                        _totalLabel('פחמימות', _total('carbs'), 'ג׳'),
                        _totalLabel('שומן', _total('fat'), 'ג׳'),
                      ]),
                    ),
                  ),
                ]),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('ביטול')),
        if (_items.isNotEmpty) FilledButton(onPressed: _busy ? null : _save, child: const Text('הוסף ארוחה ליומן היום')),
      ],
    );
  }

  Widget _buildItemCard(int index, _AiItem item) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold))),
            if (item.assumed) const Chip(avatar: Icon(Icons.warning_amber, size: 16), label: Text('השערת בישול'), visualDensity: VisualDensity.compact),
            IconButton(
              tooltip: 'הסר רכיב',
              onPressed: () => setState(() => _items.removeAt(index).dispose()),
              icon: const Icon(Icons.close, color: Colors.redAccent),
            ),
          ]),
          if (item.variants.isNotEmpty)
            Wrap(spacing: 5, children: item.variants.map((variant) => ChoiceChip(
              label: Text(variant['label']?.toString() ?? 'אפשרות'),
              selected: item.activeVariant == variant['label'],
              onSelected: (selected) {
                if (!selected) return;
                setState(() => item.applyVariant(variant));
              },
            )).toList()),
          Row(children: [
            SizedBox(
              width: 112,
              child: TextField(
                controller: item.gramsController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: item.liquid ? 'כמות מ״ל' : 'גרמים', isDense: true),
                onChanged: (value) => setState(() => item.updateTotalGrams(value)),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: () => setState(() => item.liquid = !item.liquid),
              child: Text(item.liquid ? 'הצג בגרם' : 'הצג במ״ל'),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text('קל׳ ${_itemMacro(item, item.calories).toStringAsFixed(0)} · חלבון ${_itemMacro(item, item.protein).toStringAsFixed(1)}ג׳\nפחמ׳ ${_itemMacro(item, item.carbs).toStringAsFixed(1)}ג׳ · שומן ${_itemMacro(item, item.fat).toStringAsFixed(1)}ג׳', style: const TextStyle(fontSize: 12))),
          ]),
          if (item.count != null && item.gramsPerUnit != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Text('הנחה: '),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: item.countController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'יחידות', isDense: true),
                  onChanged: (value) => setState(() => item.updateCount(value)),
                ),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('×')),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: item.gramsPerUnitController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'גרם ליחידה', isDense: true),
                  onChanged: (value) => setState(() => item.updateGramsPerUnit(value)),
                ),
              ),
              const Text(' גרם'),
            ]),
          ],
          const SizedBox(height: 4),
          Text(
            '${item.matchedFood == null ? 'הערכת AI' : 'מאגר: ${item.matchedFood!.name}'} · ל-100 גרם: ${item.calories.toStringAsFixed(0)} קל׳, חלבון ${item.protein.toStringAsFixed(1)}ג׳, פחמ׳ ${item.carbs.toStringAsFixed(1)}ג׳, שומן ${item.fat.toStringAsFixed(1)}ג׳',
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
          if (item.matchedFood == null && item.suggestions.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text('התאמות מהמאגר:', style: TextStyle(fontSize: 11)),
            Wrap(
              spacing: 5,
              runSpacing: 2,
              children: item.suggestions.map((food) => ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(
                  '${food.name} · ${food.caloriesPer100g.toStringAsFixed(0)} קק״ל/100ג׳',
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () => setState(() => item.replaceWith(food)),
              )).toList(),
            ),
          ],
          if (item.canSaveToMyFoods && item.matchedFood == null)
            TextButton.icon(
              onPressed: item.isSavingToMyFoods
                  ? null
                  : () => _saveItemToMyFoods(item),
              icon: item.isSavingToMyFoods
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('שמור למאגר שלי'),
            ),
          TextButton.icon(
            onPressed: () => _replaceFromFood(item),
            icon: const Icon(Icons.search, size: 18),
            label: const Text('החלף ממאגר המזונות'),
          ),
        ]),
      ),
    );
  }

  double _itemMacro(_AiItem item, double per100) => item.grams * per100 / 100;

  Widget _totalLabel(String name, double value, String unit) => Text('$name: ${value.toStringAsFixed(1)} $unit', style: const TextStyle(fontWeight: FontWeight.w600));
}

class _AiItem {
  _AiItem({
    required this.name,
    required this.searchQuery,
    required this.grams,
    required this.liquid,
    required this.assumed,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    this.count,
    this.gramsPerUnit,
    this.matchedFood,
    List<Food>? suggestions,
    this.canSaveToMyFoods = false,
    List<Map<String, dynamic>>? variants,
  })  : suggestions = suggestions ?? [],
        variants = variants ?? [],
        gramsController = TextEditingController(text: grams.toStringAsFixed(1)),
        countController = TextEditingController(text: count?.toString() ?? ''),
        gramsPerUnitController =
            TextEditingController(text: gramsPerUnit?.toString() ?? '');

  factory _AiItem.fromMap(
    Map<String, dynamic> map, {
    required List<Food> foods,
    bool preserveStoredUnit = false,
  }) {
    final name = map['name']?.toString() ?? 'מאכל';
    final searchQuery = effectiveAiSearchQuery(
      name: name,
      searchQuery: map['search_query']?.toString() ?? '',
    );
    final matchedFood = findExactAiFoodMatch(
      foods: foods,
      name: name,
      searchQuery: searchQuery,
    );
    final suggestions = matchedFood == null
        ? suggestAiFoodMatches(
            foods: foods,
            name: name,
            searchQuery: searchQuery,
          )
        : const <Food>[];
    final canSaveToMyFoods = shouldOfferAiFoodSave(
      name: name,
      matchedFood: matchedFood,
      foods: foods,
    );
    final rawCount = map['count'];
    final rawGramsPerUnit = map['grams_per_unit'];
    final hasPortionAssumption = rawCount is num && rawGramsPerUnit is num;
    final count = hasPortionAssumption ? rawCount.toDouble() : null;
    final gramsPerUnit =
        hasPortionAssumption ? rawGramsPerUnit.toDouble() : null;
    final amount = hasPortionAssumption
        ? gramsFromUnitCount(count: count!, gramsPerUnit: gramsPerUnit!)
        : (map['grams'] as num?)?.toDouble() ?? 100;
    final aiSaysLiquid = map['is_liquid'] == true;
    final liquid = preserveStoredUnit && map['is_liquid'] is bool
        ? aiSaysLiquid
        : shouldUseMilliliters(
            aiSaysLiquid: aiSaysLiquid,
            matchedFoodIsLiquid: matchedFood?.isLiquid,
          );

    return _AiItem(
      name: name,
      searchQuery: searchQuery,
      grams: amount,
      liquid: liquid,
      assumed: map['is_assumed_addition'] == true,
      calories: matchedFood?.caloriesPer100g ??
          (map['calories_per_100g'] as num?)?.toDouble() ??
          0,
      protein: matchedFood?.proteinPer100g ??
          (map['protein_per_100g'] as num?)?.toDouble() ??
          0,
      carbs: matchedFood?.carbsPer100g ??
          (map['carbs_per_100g'] as num?)?.toDouble() ??
          0,
      fat: matchedFood?.fatPer100g ??
          (map['fat_per_100g'] as num?)?.toDouble() ??
          0,
      count: count,
      gramsPerUnit: gramsPerUnit,
      matchedFood: matchedFood,
      suggestions: suggestions,
      canSaveToMyFoods: canSaveToMyFoods,
      variants: (map['variants'] as List? ?? const [])
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList(),
    );
  }

  String name;
  String searchQuery;
  double grams;
  final TextEditingController gramsController;
  bool liquid;
  bool assumed;
  double calories;
  double protein;
  double carbs;
  double fat;
  double? count;
  double? gramsPerUnit;
  final TextEditingController countController;
  final TextEditingController gramsPerUnitController;
  Food? matchedFood;
  List<Food> suggestions;
  bool canSaveToMyFoods;
  bool isSavingToMyFoods = false;
  List<Map<String, dynamic>> variants;
  String? activeVariant;

  void _updateDerivedGrams() {
    if (count == null || gramsPerUnit == null) return;
    grams = gramsFromUnitCount(count: count!, gramsPerUnit: gramsPerUnit!);
    gramsController.text = grams.toStringAsFixed(1);
  }

  void updateCount(String value) {
    final parsed = double.tryParse(value);
    if (parsed == null || !parsed.isFinite || parsed < 0) return;
    count = parsed;
    _updateDerivedGrams();
  }

  void updateGramsPerUnit(String value) {
    final parsed = double.tryParse(value);
    if (parsed == null || !parsed.isFinite || parsed < 0) return;
    gramsPerUnit = parsed;
    _updateDerivedGrams();
  }

  void updateTotalGrams(String value) {
    final parsed = double.tryParse(value);
    if (parsed == null || !parsed.isFinite) {
      grams = 0;
      return;
    }
    grams = parsed;
    if (count != null && count! > 0) {
      gramsPerUnit = grams / count!;
      gramsPerUnitController.text = gramsPerUnit!.toStringAsFixed(1);
    }
  }

  void applyVariant(Map<String, dynamic> variant) {
    activeVariant = variant['label']?.toString();
    calories = (variant['calories_per_100g'] as num?)?.toDouble() ?? calories;
    protein = (variant['protein_per_100g'] as num?)?.toDouble() ?? protein;
    carbs = (variant['carbs_per_100g'] as num?)?.toDouble() ?? carbs;
    fat = (variant['fat_per_100g'] as num?)?.toDouble() ?? fat;
  }

  void replaceWith(Food food) {
    name = food.name;
    searchQuery = food.name;
    liquid = food.isLiquid;
    calories = food.caloriesPer100g;
    protein = food.proteinPer100g;
    carbs = food.carbsPer100g;
    fat = food.fatPer100g;
    matchedFood = food;
    suggestions = [];
    canSaveToMyFoods = false;
    variants = [];
    activeVariant = null;
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'search_query': searchQuery,
        'grams': grams,
        'is_liquid': liquid,
        'is_assumed_addition': assumed,
        'calories_per_100g': calories,
        'protein_per_100g': protein,
        'carbs_per_100g': carbs,
        'fat_per_100g': fat,
        if (count != null && gramsPerUnit != null) ...{
          'count': count,
          'grams_per_unit': gramsPerUnit,
        },
        if (variants.isNotEmpty) 'variants': variants,
      };

  void dispose() {
    gramsController.dispose();
    countController.dispose();
    gramsPerUnitController.dispose();
  }
}
