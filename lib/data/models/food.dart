class Food {
  final int? id;
  final String name;
  final double caloriesPer100g;
  final double proteinPer100g;
  final double carbsPer100g;
  final double fatPer100g;
  final bool isLiquid;
  final bool isRecipe;
  final double servings;

  Food({
    this.id,
    required this.name,
    required this.caloriesPer100g,
    required this.proteinPer100g,
    required this.carbsPer100g,
    required this.fatPer100g,
    this.isLiquid = false,
    this.isRecipe = false,
    this.servings = 1.0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'calories_per_100g': caloriesPer100g,
      'protein_per_100g': proteinPer100g,
      'carbs_per_100g': carbsPer100g,
      'fat_per_100g': fatPer100g,
      'is_liquid': isLiquid ? 1 : 0,
      'is_recipe': isRecipe ? 1 : 0,
      'servings': servings,
    };
  }

  factory Food.fromMap(Map<String, dynamic> map) {
    return Food(
      id: map['id'],
      name: map['name'],
      caloriesPer100g: map['calories_per_100g'],
      proteinPer100g: map['protein_per_100g'],
      carbsPer100g: map['carbs_per_100g'],
      fatPer100g: map['fat_per_100g'],
      isLiquid: map['is_liquid'] == 1,
      isRecipe: map['is_recipe'] == 1,
      servings: map['servings']?.toDouble() ?? 1.0,
    );
  }
}