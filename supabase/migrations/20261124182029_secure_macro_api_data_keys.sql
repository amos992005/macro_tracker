ALTER TABLE public.macro_meal_entries ADD COLUMN IF NOT EXISTS client_id text;
UPDATE public.macro_meal_entries SET client_id = id::text WHERE client_id IS NULL;
ALTER TABLE public.macro_meal_entries ALTER COLUMN client_id SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS macro_meals_user_client_id_idx ON public.macro_meal_entries(user_id, client_id);

ALTER TABLE public.macro_meal_entries DROP CONSTRAINT IF EXISTS macro_meal_entries_date_check;
ALTER TABLE public.macro_meal_entries ADD CONSTRAINT macro_meal_entries_date_check
  CHECK (date = 'default' OR date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$');
ALTER TABLE public.macro_daily_targets DROP CONSTRAINT IF EXISTS macro_daily_targets_date_check;
ALTER TABLE public.macro_daily_targets ADD CONSTRAINT macro_daily_targets_date_check
  CHECK (date = 'default' OR date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$');
