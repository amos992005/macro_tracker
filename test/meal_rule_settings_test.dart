import 'package:flutter_test/flutter_test.dart';
import 'package:macro_tracker/core/meal_rule_settings.dart';

void main() {
  test('parses integer and decimal tolerances with whitespace', () {
    expect(MealRuleSettings.parsePercent('  12  ', fallback: 4), 12);
    expect(MealRuleSettings.parsePercent(' 2.75 ', fallback: 4), 2.75);
    expect(MealRuleSettings.parsePercent(' 2,75 ', fallback: 4), 2.75);
    expect(MealRuleSettings.parsePercent(' ', fallback: 4), 4);
    expect(MealRuleSettings.parsePercent('-1', fallback: 4), 4);
  });
}
