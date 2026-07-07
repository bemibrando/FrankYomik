import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/models/furigana_region.dart';
import 'package:frank_client/providers/vocab_provider.dart';
import 'package:frank_client/screens/furigana_view_screen.dart';
import 'package:frank_client/services/vocab_repository.dart';

// 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

FuriganaPageMeta _meta() => FuriganaPageMeta.parse('''
{
  "image": {"width": 100, "height": 100},
  "regions": [
    {"id": "r1", "bbox_norm": [0.1, 0.45, 0.9, 0.55],
     "transformed": {"kind": "furigana_segments", "value": [
       {"text": "食べ", "furigana": "たべ", "needs_furigana": true},
       {"text": "る", "furigana": null, "needs_furigana": false}
     ]}}
  ]
}''');

void main() {
  testWidgets('renders furigana reading over a bubble', (tester) async {
    // Real filesystem I/O must run outside the fake-async test zone, or the
    // awaited dart:io futures never complete and the test hangs.
    late final VocabRepository repo;
    await tester.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('furi_view');
      repo = VocabRepository(file: File('${tmp.path}/v.json'));
      await repo.load();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vocabRepositoryProvider.overrideWith((ref) => repo),
        ],
        child: MaterialApp(
          home: FuriganaView(meta: _meta(), imageBytes: _png),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('たべ'), findsOneWidget);
    expect(find.text('食べ'), findsOneWidget);
  });

  testWidgets('tap word opens focus panel; mark known hides furigana',
      (tester) async {
    late final VocabRepository repo;
    await tester.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('furi_view');
      repo = VocabRepository(file: File('${tmp.path}/v.json'));
      await repo.load();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vocabRepositoryProvider.overrideWith((ref) => repo),
        ],
        child: MaterialApp(
          home: FuriganaView(meta: _meta(), imageBytes: _png),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('食べ'));
    await tester.pumpAndSettle();
    // Panel exposes a "known" toggle button.
    expect(find.byKey(const ValueKey('vocab-mark-known')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('vocab-mark-known')));
    await tester.pumpAndSettle();

    // Every furigana word in the bubble is now known, so the whole overlay
    // is hidden (reading and base text both gone).
    expect(find.text('たべ'), findsNothing);
    expect(find.text('食べ'), findsNothing);
    expect(repo.entryFor('食べ')!.known, true);
  });
}
