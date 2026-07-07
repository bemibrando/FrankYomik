import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/furigana/romaji_kana.dart';

void main() {
  group('romajiToHiragana', () {
    test('basic syllables', () {
      expect(romajiToHiragana('tabe'), 'たべ');
      expect(romajiToHiragana('nihongo'), 'にほんご');
      expect(romajiToHiragana('sushi'), 'すし');
    });

    test('youon (small ya/yu/yo)', () {
      expect(romajiToHiragana('kyou'), 'きょう');
      expect(romajiToHiragana('sha'), 'しゃ');
      expect(romajiToHiragana('honya'), 'ほにゃ'); // nya matches before ん
    });

    test('sokuon (doubled consonant)', () {
      expect(romajiToHiragana('gakkou'), 'がっこう');
      expect(romajiToHiragana('kitte'), 'きって');
    });

    test('n handling', () {
      expect(romajiToHiragana('nn'), 'ん'); // double n -> standalone ん
      expect(romajiToHiragana('kanji'), 'かんじ'); // n before consonant -> ん
      expect(romajiToHiragana('shinbun'), 'しんぶn'); // trailing n left as-is
    });

    test('passes non-romaji through unchanged', () {
      expect(romajiToHiragana('たべ'), 'たべ');
      expect(romajiToHiragana('食べ'), '食べ');
    });

    test('leaves a trailing incomplete syllable', () {
      expect(romajiToHiragana('tab'), 'たb');
      expect(romajiToHiragana('k'), 'k');
    });
  });
}
