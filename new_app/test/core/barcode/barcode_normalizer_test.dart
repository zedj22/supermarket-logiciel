import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/barcode/barcode_normalizer.dart';

void main() {
  test('normalizes the documented AZERTY samples', () {
    expect(normalizeBarcode('-&"é"-é-àà(\'\''), '6132362600544');
    expect(normalizeBarcode('-&"\'__&ààà-&\''), '6134881000614');
    expect(normalizeBarcode('-&"("çàààààèé'), '6135390000072');
  });

  test('scanner-confirmed tokens may mix ASCII digits and AZERTY symbols', () {
    expect(normalizeScannerBarcode('4445((---'), '444555666');
    expect(normalizeBarcode('4445((---'), '4445((---');
  });

  test('preserves ASCII digits and leading zeroes', () {
    expect(normalizeBarcode('00123450'), '00123450');
  });

  test('normalizes Arabic-Indic and Eastern Arabic-Indic digits', () {
    expect(normalizeBarcode('٠١٢٣٤٥٦٧٨٩'), '0123456789');
    expect(normalizeBarcode('۰۱۲۳۴۵۶۷۸۹'), '0123456789');
    expect(normalizeBarcode('SKU-١٢٣'), 'SKU-123');
  });

  test('removes scanner whitespace framing for numeric tokens', () {
    expect(normalizeBarcode('\r-&"é"-é-àà(\'\'\r\n'), '6132362600544');
    expect(normalizeBarcode('123 456'), '123 456');
  });

  test('keeps alphanumeric codes and unrelated search text intact', () {
    expect(normalizeBarcode('AB-1234'), 'AB-1234');
    expect(normalizeBarcode('é-1234'), 'é-1234');
    expect(normalizeBarcode('café & thé'), 'café & thé');
  });
}
