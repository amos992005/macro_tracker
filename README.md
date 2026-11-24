# Macro Tracker

A Hebrew Flutter macro tracker with a local food catalog, profile-scoped SQLite cache, Supabase synchronization and a web/PWA build.

## Run locally

Install Flutter, then run (never use a `service_role`/secret key in the client):

```sh
flutter pub get
dart run sqflite_common_ffi_web:setup
flutter run -d chrome
```

A public Supabase publishable key is configured in `MacroSyncService`; it is intentionally client-visible. You can override it with `--dart-define=SUPABASE_ANON_KEY=...` if you rotate the project's publishable key.

The project URL and Edge Function route are configured in `lib/data/macro_sync_service.dart`. Authentication is performed by the deployed `macro-api` Edge Function; the function keeps the service-role credential on the server, stores salted PBKDF2 PIN hashes, enforces account- and client-level throttles, and issues revocable session tokens. PINs are not saved on the device. A PIN is still a low-entropy credential and there is no PIN recovery flow at this time.

## GitHub Pages

The workflow at `.github/workflows/deploy_web.yml` runs Flutter tests and builds with `/macro_tracker/` as the base path. Enable GitHub Pages with **GitHub Actions** as the build source. No service-role credential or other private Supabase key is needed by the build. The deployed app uses local SQLite for the 9,240-food base catalog and synchronizes profile data with Supabase when connected.

AI meal and nutrition-label analysis is routed through the authenticated `macro-api` Edge Function. Configure `GEMINI_API_KEY` only as a Supabase Edge Function secret; never add it to Flutter, GitHub Actions, or the repository. The function uses a fixed model fallback chain, then queries Gemini `ListModels` after model 404s and retries the newest callable flash/pro models for that API key. It logs upstream and JSON-parse failures to a service-role-only `macro_ai_logs` table and returns a short technical cause to the client, without storing meal/image input or the API-key URL. Composite diary entries are stored as per-meal component JSON for cross-device sync. GitHub Actions also signs up a disposable CI profile and exercises the live authenticated image+text analysis endpoint.

## Data and security

Application tables are prefixed `macro_`. Their RLS is enabled and direct `anon`/`authenticated` table access is revoked; the client communicates only with the allow-listed Edge Function API. The existing `public.user_notebooks` table is unrelated and is intentionally untouched. Local SQLite files are separated by authenticated profile; the first signed-in profile imports an existing native `macro_tracker.db` when present.
