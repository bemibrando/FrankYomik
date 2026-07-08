import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/screens/local_folder_screen.dart';

void main() {
  group('sortedImageNames', () {
    test('keeps only image files', () {
      final result = sortedImageNames([
        'page1.jpg',
        'notes.txt',
        'cover.PNG',
        'archive.zip',
        'panel.webp',
        'README',
      ]);
      expect(result, ['cover.PNG', 'page1.jpg', 'panel.webp']);
    });

    test('orders numbers naturally, not lexically', () {
      final result = sortedImageNames([
        'page0010.jpg',
        'page0002.jpg',
        'page0001.jpg',
        'page0100.jpg',
      ]);
      expect(result, [
        'page0001.jpg',
        'page0002.jpg',
        'page0010.jpg',
        'page0100.jpg',
      ]);
    });

    test('handles unpadded numbers naturally', () {
      final result = sortedImageNames(['p10.png', 'p2.png', 'p1.png']);
      expect(result, ['p1.png', 'p2.png', 'p10.png']);
    });

    test('empty when no images present', () {
      expect(sortedImageNames(['a.txt', 'b.md']), isEmpty);
    });
  });
}
