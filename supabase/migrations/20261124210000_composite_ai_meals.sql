ALTER TABLE public.macro_meal_entries
  ADD COLUMN IF NOT EXISTS meal_title text,
  ADD COLUMN IF NOT EXISTS components_json text;
