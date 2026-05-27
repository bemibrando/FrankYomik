import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/utils/kindle_priority.dart';

void main() {
  group('Kindle priority metadata', () {
    test('extracts session from Kindle page id', () {
      expect(kindleSessionFromPageId('kindle-mpofu9qjdzgz-1'), 'mpofu9qjdzgz');
      expect(
        kindleSessionFromPageId('kindle-mpofu9qjdzgz-2-spread'),
        'mpofu9qjdzgz',
      );
      expect(kindleSessionFromPageId('wt-1'), isNull);
      expect(kindleSequenceFromPageId('kindle-mpofu9qjdzgz-2-spread'), 2);
    });

    test('uses spread root token for split halves', () {
      expect(
        kindleLatestTokenForPage('kindle-session-2-spread-L'),
        'kindle-session-2-spread',
      );
      expect(
        kindleLatestTokenForPage('kindle-session-2-spread-R'),
        'kindle-session-2-spread',
      );
      expect(
        kindleLatestTokenForPage('kindle-session-2-spread-left'),
        'kindle-session-2-spread',
      );
    });

    test('builds stable latest group and token', () {
      final meta = kindlePriorityMetadataForPage(
        pageId: 'kindle-sessionabc-7-spread-L',
        title: 'B000000001',
      );
      expect(meta, isNotNull);
      expect(meta!.sourceSite, 'kindle');
      expect(meta.latestGroup, 'kindle:B000000001:sessionabc');
      expect(meta.latestToken, 'kindle-sessionabc-7-spread');
      expect(meta.latestSeq, 7);
    });
  });
}
