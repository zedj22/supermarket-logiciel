# Phase 1 Architecture Decisions

## 1. Lazy Engine Factory
**Decision**: Database engine created lazily via `_EngineFactory` singleton, not at import time.
**Reason**: Prevents connection errors when importing modules without a running database.
**Impact**: Safe to import `app.db` in tests and CLI tools without DB.

## 2. Exception Hierarchy
**Decision**: Custom exception classes inheriting from `AppError` with `code`, `message_key`, `details`.
**Reason**: Consistent structured error responses. `message_key` enables i18n of error messages on the client.
**Impact**: All API errors return `{code, message_key, details, request_id}`.

## 3. TimestampMixin vs Embedding
**Decision**: `TimestampMixin` as separate class, mixed into `BaseModel`.
**Reason**: Some tables may not need timestamps (e.g., junction tables). Mixin allows opt-in.
**Impact**: Models inherit `created_at` and `updated_at` via `BaseModel`, but can use `Base` directly if timestamps are unwanted.

## 4. Translation System (Static Maps vs Code Generation)
**Decision**: Static `Map<String, Map<String, String>>` in `AppStrings`.
**Reason**: Phase 1 scope is foundation only. ARB files with `flutter gen-l10n` can be added in Phase 2.
**Impact**: Translations are type-safe but not generated. Easy to migrate to ARB later.

## 5. Theme Architecture
**Decision**: Three themes (Dark, Light, Grey) as complete `ThemeData` objects.
**Reason**: User requirement for multiple themes. Each theme is a full `ThemeData` to ensure consistency.
**Impact**: `AppTheme.dark()`, `AppTheme.light()`, `AppTheme.grey()` each return a complete theme. `ThemeNotifier` cycles through them.

## 6. AppThemeMode Location
**Decision**: `AppThemeMode` enum in its own file `app_theme_mode.dart`.
**Reason**: Avoids circular imports between `app_theme.dart` and `theme_provider.dart`.
**Impact**: Clean import graph. Both theme files import from `app_theme_mode.dart`.

## 7. Google Fonts in Tests
**Decision**: Separate unit tests (ThemeNotifier) from widget tests (AppTheme).
**Reason**: `google_fonts` package requires the Flutter binding to load fonts. Unit tests that call `AppTheme.dark()` need `TestWidgetsFlutterBinding.ensureInitialized()`.
**Impact**: Theme state logic tested in unit tests. Theme rendering tested in widget tests.

## 8. Dio over http
**Decision**: Use `dio` package for HTTP client.
**Reason**: Dio provides interceptors, request/response transformation, and timeout configuration out of the box.
**Impact**: `ApiClient` wraps Dio with token management and logging interceptor.
