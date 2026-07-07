import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/models/vocab_entry.dart';

void main() {
  group('VocabEntry', () {
    test('json round-trip', () {
      final entry = VocabEntry(
        word: '食べ',
        readingOverride: 'たべ',
        known: true,
        updatedAt: DateTime.utc(2026, 7, 7, 12, 0, 0),
      );
      final decoded = VocabEntry.fromJson(entry.toJson());
      expect(decoded, isNotNull);
      expect(decoded!.word, '食べ');
      expect(decoded.readingOverride, 'たべ');
      expect(decoded.known, true);
      expect(decoded.updatedAt, DateTime.utc(2026, 7, 7, 12, 0, 0));
    });

    test('fromJson returns null when word missing', () {
      expect(VocabEntry.fromJson({'known': true}), isNull);
    });

    test('fromJson tolerates missing optional fields', () {
      final e = VocabEntry.fromJson({'word': '水'});
      expect(e, isNotNull);
      expect(e!.word, '水');
      expect(e.readingOverride, isNull);
      expect(e.known, false);
    });

    test('copyWith updates known and keeps override', () {
      final e = VocabEntry(
        word: '水',
        readingOverride: 'みず',
        known: false,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      final e2 = e.copyWith(known: true, updatedAt: DateTime.utc(2026, 2, 2));
      expect(e2.known, true);
      expect(e2.readingOverride, 'みず');
      expect(e2.updatedAt, DateTime.utc(2026, 2, 2));
    });

    test('copyWith clearOverride removes reading', () {
      final e = VocabEntry(
        word: '水',
        readingOverride: 'みず',
        known: false,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      final e2 = e.copyWith(clearOverride: true);
      expect(e2.readingOverride, isNull);
    });
  });
}
