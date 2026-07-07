import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/furigana/furigana_resolver.dart';
import 'package:frank_client/widgets/furigana_word.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('shows reading above base text when present', (tester) async {
    const display = FuriganaDisplay(
      baseText: '食べ',
      reading: 'たべ',
      altReading: null,
      isVocabWord: true,
      known: false,
    );
    await tester.pumpWidget(_host(const FuriganaWord(display: display)));
    expect(find.text('たべ'), findsOneWidget);
    expect(find.text('食べ'), findsOneWidget);
  });

  testWidgets('hides reading when null (known word)', (tester) async {
    const display = FuriganaDisplay(
      baseText: '食べ',
      reading: null,
      altReading: null,
      isVocabWord: true,
      known: true,
    );
    await tester.pumpWidget(_host(const FuriganaWord(display: display)));
    expect(find.text('食べ'), findsOneWidget);
    expect(find.text('たべ'), findsNothing);
  });

  testWidgets('fires onTap for vocab word', (tester) async {
    var tapped = 0;
    const display = FuriganaDisplay(
      baseText: '食べ',
      reading: 'たべ',
      altReading: null,
      isVocabWord: true,
      known: false,
    );
    await tester.pumpWidget(
      _host(FuriganaWord(display: display, onTap: () => tapped++)),
    );
    await tester.tap(find.text('食べ'));
    expect(tapped, 1);
  });
}
