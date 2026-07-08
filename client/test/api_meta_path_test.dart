import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/services/api_service.dart';

void main() {
  group('ApiService.metaPath', () {
    test('builds by-hash meta path', () {
      expect(
        ApiService.metaPath('manga_furigana', 'abc123'),
        '/api/v1/cache/by-hash/manga_furigana/abc123/meta',
      );
    });

    test('url-encodes components', () {
      expect(
        ApiService.metaPath('manga_furigana', 'a/b c'),
        '/api/v1/cache/by-hash/manga_furigana/a%2Fb%20c/meta',
      );
    });
  });
}
