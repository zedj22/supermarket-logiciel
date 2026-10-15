// Storage & Data Usage — local filesystem probe tests.
//
// The probe must show *exactly* what it measured: one partitioning pass
// per location, exports counted only at the top level, never a byte
// counted twice (a dev build runs the executable from the same folder
// the save dialog writes into), and a missing location reported as a
// reason — never an exception and never a silently wrong "0 B".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/storage/local_storage_measure.dart';
import 'package:supermarket_pos/features/storage/storage_models.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('storage_probe_');
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {
      // Best effort — temp directories are disposable.
    }
  });

  String newDir(String name) {
    final dir = Directory('${root.path}${Platform.pathSeparator}$name')
      ..createSync(recursive: true);
    return dir.path;
  }

  void newFile(String path, int bytes) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(bytes, 0));
  }

  group('measureLocalStorage', () {
    test('sums each location into its own category', () {
      final app = newDir('app');
      newFile('$app${Platform.pathSeparator}main.exe', 100);
      newFile('$app${Platform.pathSeparator}lib${Platform.pathSeparator}a.dll', 200);

      final exports = newDir('exports');
      newFile('$exports${Platform.pathSeparator}invoice.pdf', 300);
      newFile('$exports${Platform.pathSeparator}report.csv', 40);
      newFile('$exports${Platform.pathSeparator}notes.txt', 7);

      final cache = newDir('cache');
      newFile('$cache${Platform.pathSeparator}font.bin', 9);

      final section = measureLocalStorage([app, exports, cache]);

      expect(section.scope, storageScopeLocal);
      expect(section.category(storageCategoryApplication)?.bytes, 300);
      expect(section.category(storageCategoryExports)?.bytes, 340);
      expect(section.category(storageCategoryCacheTemp)?.bytes, 9);
      expect(section.totalBytes, 300 + 340 + 9);
      expect(section.complete, isTrue);
      expect(section.hasUnavailable, isFalse);
    });

    test('exports sharing the app folder are never counted twice', () {
      // The save dialog writes into the working directory, which for a
      // dev build *is* the executable folder: the exact overlap the
      // scope rules must handle without double-counting.
      final both = newDir('both');
      newFile('$both${Platform.pathSeparator}invoice.pdf', 100);
      newFile('$both${Platform.pathSeparator}invoice.txt', 5);
      newFile(
        '$both${Platform.pathSeparator}data${Platform.pathSeparator}bin.dat',
        200,
      );

      final missingCache = '${root.path}${Platform.pathSeparator}no_cache';
      final section = measureLocalStorage([both, both, missingCache]);

      // Top-level export files belong to exports, not to application.
      expect(section.category(storageCategoryExports)?.bytes, 100);
      expect(section.category(storageCategoryApplication)?.bytes, 205);
      expect(section.totalBytes, 305);
      // …and the overlap never shows up as a bigger number.
      expect(section.totalBytes, 100 + 205);

      expect(section.category(storageCategoryCacheTemp)?.available, isFalse);
      expect(section.category(storageCategoryCacheTemp)?.reason,
          storageReasonMissing);
      expect(section.complete, isFalse);
    });

    test('missing directories report a reason instead of throwing', () {
      final section = measureLocalStorage([
        '${root.path}${Platform.pathSeparator}ghost_app',
        '${root.path}${Platform.pathSeparator}ghost_exports',
        '${root.path}${Platform.pathSeparator}ghost_cache',
      ]);

      for (final key in kLocalStorageCategoryKeys) {
        final category = section.category(key);
        expect(category, isNotNull, reason: key);
        expect(category!.available, isFalse, reason: key);
        expect(category.reason, storageReasonMissing, reason: key);
      }
      expect(section.totalBytes, 0);
      expect(section.complete, isFalse);
    });

    test('an empty probe argument list degrades to "missing"', () {
      final section = measureLocalStorage(const <String>[]);
      expect(section.totalBytes, 0);
      for (final key in kLocalStorageCategoryKeys) {
        expect(section.category(key)?.available, isFalse);
      }
      expect(section.measuredAt, isNotNull);
    });

    test('existing-but-empty directories measure zero, not unavailable', () {
      final app = newDir('empty_app');
      final exports = newDir('empty_exports');
      final cache = newDir('empty_cache');

      final section = measureLocalStorage([app, exports, cache]);

      expect(section.category(storageCategoryApplication)?.available, isTrue);
      expect(section.category(storageCategoryApplication)?.bytes, 0);
      expect(section.category(storageCategoryExports)?.bytes, 0);
      expect(section.category(storageCategoryCacheTemp)?.bytes, 0);
      expect(section.complete, isTrue);
      expect(section.totalBytes, 0);
    });

    test('the disk row reflects the volume holding the app folder', () {
      final app = newDir('disk_app');
      final section = measureLocalStorage([app, app, app]);

      expect(section.disk, isNotNull);
      expect(section.disk!.available, isTrue);
      expect(section.disk!.totalBytes, greaterThan(0));
      expect(
        section.disk!.freeBytes!,
        lessThanOrEqualTo(section.disk!.totalBytes!),
      );
    });
  });
}
