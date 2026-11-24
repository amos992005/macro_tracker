ALTER TABLE public.macro_meal_entries
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false;
