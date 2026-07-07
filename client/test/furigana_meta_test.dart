import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/models/furigana_region.dart';

void main() {
  group('FuriganaPageMeta.parse', () {
    test('parses regions with furigana_segments', () {
      const json = '''
      {
        "image": {"width": 800, "height": 1200},
        "regions": [
          {
            "id": "r1",
            "kind": "bubble",
            "bbox_norm": [0.1, 0.2, 0.3, 0.5],
            "ocr_text": "食べる",
            "transformed": {
              "kind": "furigana_segments",
              "value": [
                {"text": "食べ", "furigana": "たべ", "needs_furigana": true},
                {"text": "る", "furigana": null, "needs_furigana": false}
              ]
            }
          }
        ]
      }''';

      final meta = FuriganaPageMeta.parse(json);

      expect(meta.imageWidth, 800);
      expect(meta.imageHeight, 1200);
      expect(meta.regions.length, 1);
      final r = meta.regions.first;
      expect(r.id, 'r1');
      expect(r.bboxNorm, [0.1, 0.2, 0.3, 0.5]);
      expect(r.segments.length, 2);
      expect(r.segments[0].text, '食べ');
      expect(r.segments[0].furigana, 'たべ');
      expect(r.segments[0].needsFurigana, true);
      expect(r.segments[1].furigana, isNull);
      expect(r.segments[1].needsFurigana, false);
    });

    test('skips regions without furigana_segments', () {
      const json = '''
      {
        "image": {"width": 10, "height": 10},
        "regions": [
          {"id": "r1", "bbox_norm": [0,0,1,1],
           "transformed": {"kind": "text", "value": "hello"}},
          {"id": "r2", "bbox_norm": [0,0,1,1], "transformed": null}
        ]
      }''';
      final meta = FuriganaPageMeta.parse(json);
      expect(meta.regions, isEmpty);
    });

    test('skips malformed regions without throwing', () {
      const json = '''
      {
        "image": {"width": 10, "height": 10},
        "regions": [
          {"id": "bad", "bbox_norm": [0,0,1],
           "transformed": {"kind": "furigana_segments", "value": []}},
          {"id": "ok", "bbox_norm": [0,0,1,1],
           "transformed": {"kind": "furigana_segments",
             "value": [{"text": "水", "furigana": "みず", "needs_furigana": true}]}}
        ]
      }''';
      final meta = FuriganaPageMeta.parse(json);
      expect(meta.regions.length, 1);
      expect(meta.regions.first.id, 'ok');
    });

    test('tolerates missing image block', () {
      const json = '{"regions": []}';
      final meta = FuriganaPageMeta.parse(json);
      expect(meta.imageWidth, 0);
      expect(meta.imageHeight, 0);
      expect(meta.regions, isEmpty);
    });
  });
}
