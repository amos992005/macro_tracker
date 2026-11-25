import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:macro_tracker/data/database_helper.dart';
import 'package:macro_tracker/data/models/food.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper();

  setUpAll(() async {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await helper.activateProfile('ai-food-save-test');
  });

  tearDownAll(() async {
    await helper.deactivateProfile();
  });

  test('saving the same AI food twice reuses the existing local row', () async {
    const name = 'מזון בדיקת שמירה כפולה';
    final first = await helper.insertFoodIfAbsent(
      Food(
        name: name,
        caloriesPer100g: 123,
        proteinPer100g: 4,
        carbsPer100g: 20,
        fatPer100g: 2,
        isLiquid: true,
      ),
    );
    final second = await helper.insertFoodIfAbsent(
      Food(
        name: name,
        caloriesPer100g: 999,
        proteinPer100g: 99,
        carbsPer100g: 99,
        fatPer100g: 99,
      ),
    );

    expect(first.inserted, isTrue);
    expect(second.inserted, isFalse);
    expect(second.food.id, first.food.id);
    expect(second.food.caloriesPer100g, 123);
    expect(second.food.isLiquid, isTrue);

    final db = await helper.database;
    final rows = await db.query(
      'foods',
      where: 'name = ? AND is_deleted = 0',
      whereArgs: [name],
    );
    expect(rows, hasLength(1));
  });
}
