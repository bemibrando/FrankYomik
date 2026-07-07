import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frank_client/services/vocab_repository.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vocab_test');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  File vocabFile() => File('${tmp.path}/vocab.json');

  test('setKnown persists and reloads', () async {
    final repo = VocabRepository(file: vocabFile());
    await repo.load();
    await repo.setKnown('食べ', true);
    expect(repo.entryFor('食べ')!.known, true);

    final repo2 = VocabRepository(file: vocabFile());
    await repo2.load();
    expect(repo2.entryFor('食べ')!.known, true);
  });

  test('setReadingOverride stores and clears', () async {
    final repo = VocabRepository(file: vocabFile());
    await repo.load();
    await repo.setReadingOverride('水', 'みず');
    expect(repo.entryFor('水')!.readingOverride, 'みず');
    await repo.setReadingOverride('水', null);
    expect(repo.entryFor('水')!.readingOverride, isNull);
  });

  test('notifies listeners on mutation', () async {
    final repo = VocabRepository(file: vocabFile());
    await repo.load();
    var notified = 0;
    repo.addListener(() => notified++);
    await repo.setKnown('水', true);
    expect(notified, greaterThan(0));
  });

  test('corrupt file falls back to empty', () async {
    await vocabFile().writeAsString('{not valid json');
    final repo = VocabRepository(file: vocabFile());
    await repo.load();
    expect(repo.entries, isEmpty);
    // still usable after corrupt load
    await repo.setKnown('火', true);
    expect(repo.entryFor('火')!.known, true);
  });

  test('missing file loads empty', () async {
    final repo = VocabRepository(file: vocabFile());
    await repo.load();
    expect(repo.entries, isEmpty);
  });
}
