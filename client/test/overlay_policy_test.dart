import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/furigana/overlay_policy.dart';

void main() {
  group('shouldApplyBurnedOverlay', () {
    test('furigana pipeline suppresses burned overlay', () {
      expect(shouldApplyBurnedOverlay('manga_furigana'), false);
    });
    test('translate pipeline keeps burned overlay', () {
      expect(shouldApplyBurnedOverlay('manga_translate'), true);
    });
    test('webtoon pipeline keeps burned overlay', () {
      expect(shouldApplyBurnedOverlay('webtoon'), true);
    });
    test('null pipeline keeps burned overlay', () {
      expect(shouldApplyBurnedOverlay(null), true);
    });
  });
}
