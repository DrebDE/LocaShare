# Contributing to LocaShare

Thank you for helping improve LocaShare. Please adhere to these project conventions and privacy commitments before submitting changes.

## Repository Layout

- `backend/` — PHP 8.2 API (`api/`), core services (`includes/`), database schemas (`database/`), web dashboard (`dashboard/`), and CLI/CGI test runner (`tests/run_tests.php`).
- `mobile/` — Flutter + native Kotlin Android client (`lib/` and `android/app/src/main/kotlin/com/locashare/app/`).

## Privacy & Security Rules

1. **No stealth tracking**: Never hide the app, omit the persistent foreground notification, suppress Android permission prompts, or add remote activation endpoints without on-phone owner action.
2. **Never log secrets or coordinates**: Use `Security::logError()` (which redacts tokens, pairing codes, coordinates, and `Bearer` headers) on the backend and avoid logging `deviceToken`, pairing codes, or `lat`/`lng` in Android Logcat.
3. **Latest-only storage by default**: Do not add automatic coordinate history logging tables unless implemented as an explicit, disabled-by-default opt-in control owned by the phone user.
4. **Authenticate every read and write**: Phone endpoints must verify both the device Bearer token and `device_id` match; dashboard endpoints must enforce `locashare_session` pairing ownership and `X-CSRF-Token` on state-changing routes.
5. **Preserve existing style & safety**: Keep HTML rendering free of unsanitized `innerHTML`, validate coordinates/timestamps/payload sizes strictly, and preserve strict Content-Security-Policy headers in `dashboard/index.php`.

## Pre-PR Verification Checklist

Run all checks from the repository root (`locashare/`):

```powershell
# 1. PHP syntax checks & end-to-end HTTP integration suite
Get-ChildItem -Recurse -Filter "*.php" backend | ForEach-Object { php -l $_.FullName }
php backend\tests\run_tests.php

# 2. Flutter static analysis, unit/widget tests, and Android APK build
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Keep changes focused on the feature, avoid committing `.env` secrets or generated build artifacts (`backend/database/*.sqlite`, `mobile/build/`), and update `README.md` whenever API payloads or environment variables change.
