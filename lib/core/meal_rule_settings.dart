/// Parsing and normalization shared by the rule-settings dialog and tests.
class MealRuleSettings {
  const MealRuleSettings._();

  /// Accepts whole and decimal percentages, including surrounding/internal
  /// whitespace and a comma decimal separator. Invalid or empty input keeps
  /// the previous saved value rather than silently changing it to zero.
  static double parsePercent(String input, {required double fallback}) {
    var normalized = input.replaceAll(RegExp(r'\s+'), '');
    if (normalized.contains(',') && !normalized.contains('.')) {
      normalized = normalized.replaceAll(',', '.');
    }
    final parsed = double.tryParse(normalized);
    return parsed != null && parsed.isFinite && parsed >= 0 ? parsed : fallback;
  }
}
