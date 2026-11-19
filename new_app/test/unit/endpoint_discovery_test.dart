import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/devices/device_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('endpoint_discovery_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  File writeDescriptor(Directory dir, String contents, {String? name}) {
    final file = File(
      '${dir.path}${Platform.pathSeparator}${name ?? 'supermarket_endpoint.json'}',
    );
    file.writeAsStringSync(contents);
    return file;
  }

  group('descriptor paths', () {
    test('exe-dir descriptor sits next to the resolved executable', () {
      final file = localBackendEndpointFile();
      expect(file.path.split(Platform.pathSeparator).last,
          endpointFileName);
      expect(file.parent.path,
          File(Platform.resolvedExecutable).parent.path);
    });

    test('data descriptor matches the R1 ProgramData layout', () {
      final programData = Platform.environment['ProgramData'];
      final file = localBackendEndpointDataFile();
      if (programData == null || programData.isEmpty) {
        expect(file, isNull);
        return;
      }
      expect(file, isNotNull);
      final parts = file!.path.split(Platform.pathSeparator);
      expect(parts.sublist(parts.length - 4), [
        programData.split(Platform.pathSeparator).last,
        'SupermarketPro',
        'config',
        endpointFileName,
      ]);
    });
  });

  group('readEndpointBaseUrlFrom', () {
    test('returns the first valid descriptor in candidate order',
        () async {
      final first = writeDescriptor(
        tempDir,
        jsonEncode({'base_url': 'http://127.0.0.1:18000'}),
      );
      final secondDir = Directory('${tempDir.path}${Platform.pathSeparator}b')
        ..createSync();
      final second = writeDescriptor(
        secondDir,
        jsonEncode({'base_url': 'http://127.0.0.1:8000'}),
      );

      expect(
        await readEndpointBaseUrlFrom([first, second]),
        'http://127.0.0.1:18000',
      );
      expect(
        await readEndpointBaseUrlFrom([second, first]),
        'http://127.0.0.1:8000',
      );
    });

    test('skips missing files and returns null for no candidates',
        () async {
      final missing = File(
        '${tempDir.path}${Platform.pathSeparator}absent.json',
      );
      expect(await readEndpointBaseUrlFrom([missing]), isNull);
      expect(await readEndpointBaseUrlFrom(const []), isNull);
    });

    test('skips malformed JSON', () async {
      final broken = writeDescriptor(tempDir, '{not json');
      expect(await readEndpointBaseUrlFrom([broken]), isNull);
    });

    test('skips non-object payloads', () async {
      final list = writeDescriptor(tempDir, jsonEncode(['a', 'b']));
      final scalar = writeDescriptor(tempDir, jsonEncode('url'));
      expect(await readEndpointBaseUrlFrom([list]), isNull);
      expect(await readEndpointBaseUrlFrom([scalar]), isNull);
    });

    test('skips missing or non-http base_url values', () async {
      final noKey = writeDescriptor(tempDir, jsonEncode({'host': 'x'}));
      final notString = writeDescriptor(
        tempDir,
        jsonEncode({'base_url': 123}),
      );
      final notHttp = writeDescriptor(
        tempDir,
        jsonEncode({'base_url': 'ftp://x'}),
      );
      final empty = writeDescriptor(
        tempDir,
        jsonEncode({'base_url': ''}),
      );
      expect(await readEndpointBaseUrlFrom([noKey]), isNull);
      expect(await readEndpointBaseUrlFrom([notString]), isNull);
      expect(await readEndpointBaseUrlFrom([notHttp]), isNull);
      expect(await readEndpointBaseUrlFrom([empty]), isNull);
    });

    test('falls through to a later valid candidate', () async {
      final broken = writeDescriptor(tempDir, 'garbage');
      final goodDir = Directory('${tempDir.path}${Platform.pathSeparator}g')
        ..createSync();
      final good = writeDescriptor(
        goodDir,
        jsonEncode({'base_url': 'http://localhost:8443'}),
      );

      expect(
        await readEndpointBaseUrlFrom([broken, good]),
        'http://localhost:8443',
      );
    });
  });

  group('readLocalBackendBaseUrl', () {
    test('is null when neither candidate exists', () async {
      final exeFile = localBackendEndpointFile();
      final dataFile = localBackendEndpointDataFile();
      if (await exeFile.exists() ||
          (dataFile != null && await dataFile.exists())) {
        markTestSkipped(
          'host already has a descriptor file; ordering is covered by '
          'readEndpointBaseUrlFrom tests',
        );
        return;
      }
      expect(await readLocalBackendBaseUrl(), isNull);
    });
  });
}
