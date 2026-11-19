// Local storage measurement — how much disk THIS computer uses for the
// application, for files the app saved, and for its cache.
//
// Scope discipline (multi-PC safety):
// * only three known, application-owned locations are ever inspected —
//   the installed executable's folder, the process working directory
//   (where the Windows save dialog lands exports by default) and this
//   app's own `%APPDATA%` folder.  Nothing else is scanned, no path
//   comes from the network, and no directory symlink is followed;
// * exports are top-level `.pdf`/`.csv`/`.xlsx` files only, and files
//   already counted there are skipped during the application walk, so a
//   working directory that contains the executable (dev builds) never
//   double-counts a byte;
// * the database and backups are NOT measured here — they live on the
//   server and come from `GET /api/v1/storage`.
//
// The measurement runs in a background isolate via `compute`, never on
// the UI thread, and every walk shares one wall-clock budget: an
// over-run reports `timeout` instead of a partial number.
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as native;
import 'package:flutter/foundation.dart' show compute, immutable, visibleForTesting;

import 'storage_models.dart';

/// One wall-clock budget covering exports + application + cache walks.
@visibleForTesting
const Duration kLocalStorageBudget = Duration(seconds: 5);

/// Only these extensions are "documents the app produced" — the save
/// dialogs write CSV/XLSX/PDF, nothing else counts as a local export.
const List<String> kLocalStorageExportExtensions = <String>[
  '.pdf',
  '.csv',
  '.xlsx',
];

/// The `%APPDATA%\<CompanyName>\<ProductName>` folder that
/// `shared_preferences` / `flutter_secure_storage` write into, mirrored
/// from `windows/runner/Runner.rc` (CompanyName) and `pubspec.yaml`
/// (name). Empty when the environment is unavailable.
@visibleForTesting
String localAppCacheDir() {
  final roaming = Platform.environment['APPDATA'];
  if (roaming == null || roaming.isEmpty) return '';
  return '$roaming/com.supermarket/supermarket_pos';
}

/// The three locations this probe is allowed to touch.
@immutable
class LocalStoragePaths {
  const LocalStoragePaths({
    required this.applicationDir,
    required this.exportsDir,
    required this.cacheDir,
  });

  final String applicationDir;
  final String exportsDir;
  final String cacheDir;

  List<String> toProbeArgs() => <String>[applicationDir, exportsDir, cacheDir];
}

/// Resolves the probe locations from the running process (never from
/// request data — there is no path parameter anywhere in this feature).
/// P9/Q18: the exports folder is deterministic, never the process CWD.
///
/// A production install runs from `C:\Program Files\...`, whose working
/// directory flips between `System32` (service-spawned) and the install
/// tree (shortcut) — measuring/reporting "Directory.current" therefore
/// described the wrong volume and wrote nowhere an operator could find.
/// Documents is user-writable, survives uninstall and is what the backup
/// and export flows expect.
@visibleForTesting
String localExportsDir() {
  final profile = Platform.environment['USERPROFILE'];
  if (profile == null || profile.isEmpty) return '';
  return '$profile\\Documents\\Supermarket Pro';
}

LocalStoragePaths resolveLocalStoragePaths() {
  final exports = localExportsDir();
  if (exports.isNotEmpty) {
    // The capacity probe (GetDiskFreeSpaceExW) needs an existing path.
    try {
      Directory(exports).createSync(recursive: true);
    } catch (_) {
      // Read-only profile: the probe reports "unavailable" instead.
    }
  }
  return LocalStoragePaths(
    applicationDir: File(Platform.resolvedExecutable).parent.path,
    exportsDir: exports.isEmpty ? Directory.current.path : exports,
    cacheDir: localAppCacheDir(),
  );
}

// ---------------------------------------------------------------------------
// Disk capacity (Windows, read-only)
// ---------------------------------------------------------------------------

typedef _GetDiskFreeSpaceExWW = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint16> directoryName,
  ffi.Pointer<ffi.Uint64> freeBytesAvailable,
  ffi.Pointer<ffi.Uint64> totalNumberOfBytes,
  ffi.Pointer<ffi.Uint64> totalNumberOfFreeBytes,
);
typedef _GetDiskFreeSpaceExWD = int Function(
  ffi.Pointer<ffi.Uint16> directoryName,
  ffi.Pointer<ffi.Uint64> freeBytesAvailable,
  ffi.Pointer<ffi.Uint64> totalNumberOfBytes,
  ffi.Pointer<ffi.Uint64> totalNumberOfFreeBytes,
);

/// Capacity of the volume holding [path] via `GetDiskFreeSpaceExW`.
///
/// Returns null when the value cannot be obtained reliably (non-Windows
/// host, missing volume, Win32 failure) — the UI then shows the disk as
/// unavailable rather than inventing a number. Never throws.
@visibleForTesting
StorageDisk? windowsDiskUsage(String path) {
  if (!Platform.isWindows || path.isEmpty) return null;
  try {
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    final getUsage = kernel32
        .lookupFunction<_GetDiskFreeSpaceExWW, _GetDiskFreeSpaceExWD>(
          'GetDiskFreeSpaceExW',
        );
    final units = <int>[...path.codeUnits, 0];
    final name = native.calloc<ffi.Uint16>(units.length);
    final freeAvailable = native.calloc<ffi.Uint64>();
    final total = native.calloc<ffi.Uint64>();
    final totalFree = native.calloc<ffi.Uint64>();
    try {
      for (var i = 0; i < units.length; i++) {
        name[i] = units[i];
      }
      final ok = getUsage(name, freeAvailable, total, totalFree);
      final totalBytes = total.value;
      if (ok == 0 || totalBytes == 0 || totalBytes > 0x7FFFFFFFFFFFFFFF) {
        return null;
      }
      return StorageDisk(
        available: true,
        totalBytes: totalBytes.toInt(),
        freeBytes: freeAvailable.value.toInt(),
      );
    } finally {
      native.calloc.free(name);
      native.calloc.free(freeAvailable);
      native.calloc.free(total);
      native.calloc.free(totalFree);
    }
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Directory walks
// ---------------------------------------------------------------------------

/// Sums [directory] recursively. Returns null on budget overrun.
///
/// Symlinked entities are listed but never followed (recursive listing
/// uses `followLinks: false`), duplicate paths are counted once, and a
/// `FileSystemException` (missing / inaccessible) propagates so the
/// caller can attach the right reason instead of silently undercounting.
int? _sumDirectorySync(
  Directory directory, {
  Set<String> skipFiles = const <String>{},
  required DateTime deadline,
}) {
  var total = 0;
  final seen = <String>{};
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (DateTime.now().isAfter(deadline)) return null;
    if (entity is Link) continue; // links are skipped, never followed
    if (entity is! File) continue;
    final normalized = _normalizePath(entity.path);
    if (skipFiles.contains(normalized)) continue;
    if (!seen.add(normalized)) continue;
    total += entity.lengthSync();
  }
  return total;
}

String _normalizePath(String path) => path.toLowerCase();

// ---------------------------------------------------------------------------
// Measurement (top-level for `compute`)
// ---------------------------------------------------------------------------

StorageCategory _measured(String key, int? bytes) =>
    StorageCategory(key: key, available: true, bytes: bytes ?? 0);

/// Top-level entry point so it can run inside a background isolate via
/// [compute]; [rawPaths] is `[applicationDir, exportsDir, cacheDir]`.
///
/// Never throws: every failure becomes an unavailable category with a
/// reason, so the page can always render something truthful.
@visibleForTesting
StorageSection measureLocalStorage(List<String> rawPaths) {
  final paths = LocalStoragePaths(
    applicationDir: rawPaths.isNotEmpty ? rawPaths[0] : '',
    exportsDir: rawPaths.length > 1 ? rawPaths[1] : '',
    cacheDir: rawPaths.length > 2 ? rawPaths[2] : '',
  );
  final startedAt = DateTime.now();
  final deadline = startedAt.add(kLocalStorageBudget);

  // --- Documents & exports: top-level files of the working directory ---
  int? exportsBytes;
  String? exportsReason = storageReasonMissing;
  final exportFiles = <String>{};
  try {
    final exportsDir = Directory(paths.exportsDir);
    if (paths.exportsDir.isEmpty || !exportsDir.existsSync()) {
      exportsReason = storageReasonMissing;
    } else {
      exportsReason = null;
      for (final entity in exportsDir.listSync(followLinks: false)) {
        if (entity is! File) continue; // top-level only: no sub-directories
        final normalized = _normalizePath(entity.path);
        final hasExportExtension = kLocalStorageExportExtensions.any(
          normalized.endsWith,
        );
        if (!hasExportExtension) continue;
        exportFiles.add(normalized);
        exportsBytes = (exportsBytes ?? 0) + entity.lengthSync();
      }
      exportsBytes ??= 0;
    }
  } on FileSystemException {
    exportsReason = storageReasonError;
    exportsBytes = null;
  }

  // --- Installed application files (executable folder) -----------------
  int? appBytes;
  String? appReason;
  try {
    final appDir = Directory(paths.applicationDir);
    if (paths.applicationDir.isEmpty || !appDir.existsSync()) {
      appReason = storageReasonMissing;
    } else {
      appBytes = _sumDirectorySync(
        appDir,
        skipFiles: exportFiles, // exports live elsewhere in this scope
        deadline: deadline,
      );
      if (appBytes == null) appReason = storageReasonTimeout;
    }
  } on FileSystemException {
    appReason = storageReasonError;
    appBytes = null;
  }

  // --- Cache & temporary files (this app's %APPDATA% folder) -----------
  int? cacheBytes;
  String? cacheReason;
  try {
    if (paths.cacheDir.isEmpty) {
      cacheReason = storageReasonMissing;
    } else {
      final cacheDir = Directory(paths.cacheDir);
      if (!cacheDir.existsSync()) {
        cacheReason = storageReasonMissing;
      } else {
        cacheBytes = _sumDirectorySync(cacheDir, deadline: deadline);
        if (cacheBytes == null) cacheReason = storageReasonTimeout;
      }
    }
  } on FileSystemException {
    cacheReason = storageReasonError;
    cacheBytes = null;
  }

  final categories = <StorageCategory>[
    appReason == null
        ? _measured(storageCategoryApplication, appBytes)
        : StorageCategory.unavailable(storageCategoryApplication, appReason),
    exportsReason == null
        ? _measured(storageCategoryExports, exportsBytes)
        : StorageCategory.unavailable(storageCategoryExports, exportsReason),
    cacheReason == null
        ? _measured(storageCategoryCacheTemp, cacheBytes)
        : StorageCategory.unavailable(storageCategoryCacheTemp, cacheReason),
  ];

  return StorageSection(
    scope: storageScopeLocal,
    measuredAt: DateTime.now(),
    categories: categories,
    disk: windowsDiskUsage(paths.applicationDir) ??
        const StorageDisk.unavailable(),
  );
}

/// The provider-facing probe: runs [measureLocalStorage] off the UI
/// thread and resolves the current paths first.
Future<StorageSection> measureLocalStorageInBackground() {
  final paths = resolveLocalStoragePaths();
  return compute(measureLocalStorage, paths.toProbeArgs());
}
