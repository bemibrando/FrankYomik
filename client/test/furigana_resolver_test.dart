import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/models/furigana_region.dart';
import 'package:frank_client/models/vocab_entry.dart';
import 'package:frank_client/furigana/furigana_resolver.dart';

VocabEntry _entry({String? override, bool known = false}) => VocabEntry(
      word: '食べ',
      readingOverride: override,
      known: known,
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  const kanji =
      FuriganaSegment(text: '食べ', furigana: 'たべ', needsFurigana: true);
  const kana = FuriganaSegment(text: 'る', furigana: null, needsFurigana: false);

  group('resolveFurigana', () {
    test('kana segment is not a vocab word and shows no reading', () {
      final d = resolveFurigana(kana, null);
      expect(d.baseText, 'る');
      expect(d.reading, isNull);
      expect(d.isVocabWord, false);
      expect(d.altReading, isNull);
    });

    test('no vocab entry shows model reading', () {
      final d = resolveFurigana(kanji, null);
      expect(d.reading, 'たべ');
      expect(d.altReading, isNull);
      expect(d.isVocabWord, true);
      expect(d.known, false);
    });

    test('known word hides furigana', () {
      final d = resolveFurigana(kanji, _entry(known: true));
      expect(d.reading, isNull);
      expect(d.known, true);
      expect(d.isVocabWord, true);
    });

    test('override differing from model shows override + alt', () {
      final d = resolveFurigana(kanji, _entry(override: 'く'));
      expect(d.reading, 'く');
      expect(d.altReading, 'たべ');
    });

    test('override equal to model has no alt', () {
      final d = resolveFurigana(kanji, _entry(override: 'たべ'));
      expect(d.reading, 'たべ');
      expect(d.altReading, isNull);
    });

    test('known override still hides furigana', () {
      final d = resolveFurigana(kanji, _entry(override: 'く', known: true));
      expect(d.reading, isNull);
      expect(d.known, true);
    });
  });

  group('distributeRuby', () {
    List<(String, String?)> pairs(String base, String? reading) =>
        distributeRuby(base, reading).map((u) => (u.base, u.furigana)).toList();

    test('anchors on kana in the base (抜け出 / ぬけだ)', () {
      expect(pairs('抜け出', 'ぬけだ'),
          [('抜', 'ぬ'), ('け', null), ('出', 'だ')]);
    });

    test('splits an all-kanji run 1:1 (意味 / いみ)', () {
      expect(pairs('意味', 'いみ'), [('意', 'い'), ('味', 'み')]);
    });

    test('keeps a kanji run grouped when lengths differ (一人 / ひとり)', () {
      expect(pairs('一人', 'ひとり'), [('一人', 'ひとり')]);
    });

    test('no reading => each character bare', () {
      expect(pairs('する', null), [('す', null), ('る', null)]);
    });
  });
}
