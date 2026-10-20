# clean_seed.py
import json
import os

INPUT_FILE = 'all_foods_with_carbs.json'
OUTPUT_FILE = 'foods_full_all.json'

# === מתכונים אישיים להסרה (התחלופה "התחלה נקייה") ===
PERSONAL_NAMES = {
    'אורז וחזה עוף ואפונה',
    'מתכון אורז וחזה עוף ואפונה וגזר',
    'שניצל מתכון שלי',
    'פתיתים מתכון שלי',
}

if not os.path.exists(INPUT_FILE):
    print(f'❌ לא נמצא הקובץ {INPUT_FILE}')
    exit(1)

with open(INPUT_FILE, 'r', encoding='utf-8') as f:
    data = json.load(f)

cleaned = []
skipped_invalid = 0
skipped_personal = 0
favorites_reset = 0

for item in data:
    if not isinstance(item, dict):
        skipped_invalid += 1
        continue

    name = (item.get('name') or '').strip()
    if not name:
        skipped_invalid += 1
        continue

    if name in PERSONAL_NAMES:
        skipped_personal += 1
        continue

    # אימות ערכים תזונתיים
    required = ['calories_per_100g', 'protein_per_100g', 'carbs_per_100g', 'fat_per_100g']
    if any(not isinstance(item.get(k), (int, float)) for k in required):
        skipped_invalid += 1
        continue

    if item.get('is_favorite') == 1:
        favorites_reset += 1

    cleaned.append({
        'name': name,
        'calories_per_100g': float(item['calories_per_100g']),
        'protein_per_100g': float(item['protein_per_100g']),
        'carbs_per_100g': float(item['carbs_per_100g']),
        'fat_per_100g': float(item['fat_per_100g']),
        'is_liquid': int(item.get('is_liquid', 0) or 0),
        'is_recipe': int(item.get('is_recipe', 0) or 0),
        'servings': float(item.get('servings', 1.0) or 1.0),
        'is_favorite': 0,  # התחלה נקייה
    })

with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
    json.dump(cleaned, f, ensure_ascii=False, indent=2)

print('=' * 50)
print(f'📥 קלט:              {len(data)} רשומות')
print(f'✅ פלט:              {len(cleaned)} מוצרים נקיים')
print(f'🗑️  מתכונים אישיים:  {skipped_personal} הוסרו')
print(f'⚠️  רשומות פגומות:  {skipped_invalid} דולגו')
print(f'⭐ מועדפים אופסו:   {favorites_reset} רשומות')
print(f'📁 נשמר ל:           {OUTPUT_FILE}')
print('=' * 50)