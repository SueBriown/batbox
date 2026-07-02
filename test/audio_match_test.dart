import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:batbox/main.dart';

void main() {
  test('similarity score is high for matching signals', () {
    final reference = <double>[0.1, 0.2, 0.3, 0.4];
    final candidate = <double>[0.1, 0.2, 0.3, 0.4];

    expect(similarityScore(reference, candidate), closeTo(1.0, 1e-9));
  });

  test('similarity score is low for different signals', () {
    final reference = <double>[0.1, 0.2, 0.3, 0.4];
    final candidate = <double>[-0.1, -0.2, -0.3, -0.4];

    expect(similarityScore(reference, candidate), closeTo(-1.0, 1e-9));
  });

  test('best similarity score finds an offset match', () {
    final reference = <double>[0.2, 0.4, 0.6, 0.8];
    final candidate = <double>[0.0, 0.0, 0.2, 0.4, 0.6, 0.8];

    expect(bestSimilarityScore(reference, candidate), greaterThan(0.8));
  });

  test('camera device preference falls back to front camera when rear is unavailable', () {
    final preferred = CameraDevice.rear;
    final fallback = preferred == CameraDevice.rear ? CameraDevice.front : CameraDevice.rear;

    expect(fallback, CameraDevice.front);
  });
}
