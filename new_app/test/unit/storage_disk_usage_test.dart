// Storage & Data Usage — Windows disk capacity (read-only Win32 FFI).
//
// The only native call in the feature. Rules being pinned here:
//  * it never throws — an unusable path resolves to null and the UI
//    shows "unavailable" rather than crashing the page;
//  * a valid directory resolves to real capacity numbers with
//    0 <= free <= total;
//  * empty input short-circuits before any Win32 call.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/storage/local_storage_measure.dart';

void main() {
  group('windowsDiskUsage', () {
    test('empty path short-circuits to null without a Win32 call', () {
      expect(windowsDiskUsage(''), isNull);
    });

    test('a non-existent directory resolves to null, never throws', () {
      final bogus =
          '${Directory.systemTemp.path}${Platform.pathSeparator}no_such_dir_zzz';
      expect(() => windowsDiskUsage(bogus), returnsNormally);
      expect(windowsDiskUsage(bogus), isNull);
    });

    test('the current directory reports real capacity', () {
      final disk = windowsDiskUsage(Directory.current.path);
      expect(disk, isNotNull, reason: 'GetDiskFreeSpaceExW on an existing dir');
      expect(disk!.available, isTrue);
      expect(disk.totalBytes, greaterThan(0));
      expect(disk.freeBytes, greaterThanOrEqualTo(0));
      expect(disk.freeBytes!, lessThanOrEqualTo(disk.totalBytes!));
    });

    test('a volume root also answers', () {
      final root = Platform.isWindows ? r'C:\' : Directory.current.path;
      final disk = windowsDiskUsage(root);
      expect(disk?.available, isTrue);
      expect(disk?.totalBytes, greaterThan(0));
    });
  });
}
