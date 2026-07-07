# Interactive Furigana Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a non-destructive, interactive furigana reader to the Flutter client: it shows the original manga page with per-word furigana revealed over each bubble, backed by an on-device vocabulary list that overrides model readings and hides furigana for words you mark as known.

**Architecture:** Entirely client-side. The `manga_furigana` server pipeline is unchanged; the client consumes the per-region metadata it already emits (`bbox_norm` + `transformed.furigana_segments`) and renders an interactive overlay over the original captured page image in a native Flutter view. A file-backed on-device `VocabRepository` supplies reading overrides and known/unknown flags. For furigana pages the client stops swapping the server's burned image into the Kindle WebView.

**Tech Stack:** Flutter / Dart, `flutter_riverpod` (state), `path_provider` (on-device file), `http` (existing `ApiService`), `flutter_test` (tests). No new packages.

## Global Constraints

- Scope is the `manga_furigana` pipeline only. Do **not** touch `manga_translate` or `webtoon` behavior.
- **No server changes.** Everything is in `client/`.
- Non-destructive: never modify or re-render the source image; furigana is a live overlay only.
- Vocab is stored **on-device** (Flutter), in a JSON file. No server-side vocab, no cross-device sync.
- Server metadata JSON uses **snake_case** keys: `bbox_norm`, `needs_furigana`, and `transformed = {"kind": "furigana_segments", "value": [...]}`. Parsers must read these exact keys.
- Meta endpoint path is exactly `/api/v1/cache/by-hash/{pipeline}/{source_hash}/meta` and requires the `Authorization: Bearer <token>` header.
- Default behavior: **show** furigana. A word only loses its furigana when its vocab entry has `known == true`.
- Run all tests with: `cd client && flutter test`. Run a single file with `cd client && flutter test test/<file>.dart`.
- Follow existing client conventions: plain Dart model classes with `fromJson`/`toJson`, Riverpod providers in `lib/providers/`, screens in `lib/screens/`.

---

## File Structure

New files (all under `client/`):

- `lib/models/furigana_region.dart` — `FuriganaSegment`, `FuriganaRegion`, `FuriganaPageMeta` + `FuriganaPageMeta.parse(String)`.
- `lib/models/vocab_entry.dart` — `VocabEntry` value object (word, readingOverride, known, updatedAt) with JSON round-trip + `copyWith`.
- `lib/services/vocab_repository.dart` — file-backed `ChangeNotifier` store of `VocabEntry`.
- `lib/furigana/furigana_resolver.dart` — pure `FuriganaDisplay resolveFurigana(FuriganaSegment, VocabEntry?)`.
- `lib/furigana/overlay_policy.dart` — pure `bool shouldApplyBurnedOverlay(String? pipeline)`.
- `lib/providers/vocab_provider.dart` — `vocabRepositoryProvider` (Riverpod `ChangeNotifierProvider`).
- `lib/widgets/furigana_word.dart` — `FuriganaWord` widget (renders one resolved segment, tappable).
- `lib/screens/furigana_view_screen.dart` — presentational `FuriganaView` (meta + image → interactive overlay + focus panel) and `FuriganaPageLoader` (fetches meta then shows `FuriganaView`).

Modified files:

- `lib/services/api_service.dart` — add `metaPath(...)` + `fetchMeta(...)`.
- `lib/screens/reader_screen.dart` — gate burned overlay for furigana pages; add entry-point FAB.

New test files (under `client/test/`):

- `test/furigana_meta_test.dart`
- `test/vocab_entry_test.dart`
- `test/vocab_repository_test.dart`
- `test/furigana_resolver_test.dart`
- `test/overlay_policy_test.dart`
- `test/api_meta_path_test.dart`
- `test/furigana_word_test.dart`
- `test/furigana_view_test.dart`

---

## Task 1: Furigana metadata models + parser

**Files:**
- Create: `client/lib/models/furigana_region.dart`
- Test: `client/test/furigana_meta_test.dart`

**Interfaces:**
- Produces:
  - `class FuriganaSegment { final String text; final String? furigana; final bool needsFurigana; const FuriganaSegment({required this.text, this.furigana, required this.needsFurigana}); }`
  - `class FuriganaRegion { final String id; final List<double> bboxNorm; final List<FuriganaSegment> segments; }` (`bboxNorm` is `[x1,y1,x2,y2]`, each 0..1)
  - `class FuriganaPageMeta { final int imageWidth; final int imageHeight; final List<FuriganaRegion> regions; static FuriganaPageMeta parse(String jsonStr); }`

- [ ] **Step 1: Write the failing test**

Create `client/test/furigana_meta_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd client && flutter test test/furigana_meta_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../furigana_region.dart'`.

- [ ] **Step 3: Write minimal implementation**

Create `client/lib/models/furigana_region.dart`:

```dart
import 'dart:convert';

/// One word-segment of a bubble's text, as produced by the furigana pipeline.
class FuriganaSegment {
  final String text;
  final String? furigana;
  final bool needsFurigana;

  const FuriganaSegment({
    required this.text,
    this.furigana,
    required this.needsFurigana,
  });

  static FuriganaSegment? fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    if (text is! String || text.isEmpty) return null;
    final fura = json['furigana'];
    return FuriganaSegment(
      text: text,
      furigana: fura is String && fura.isNotEmpty ? fura : null,
      needsFurigana: json['needs_furigana'] == true,
    );
  }
}

/// One detected bubble/region with its normalized box and segmented text.
class FuriganaRegion {
  final String id;
  final List<double> bboxNorm; // [x1, y1, x2, y2], each 0..1
  final List<FuriganaSegment> segments;

  const FuriganaRegion({
    required this.id,
    required this.bboxNorm,
    required this.segments,
  });

  static FuriganaRegion? fromJson(Map<String, dynamic> json) {
    final transformed = json['transformed'];
    if (transformed is! Map || transformed['kind'] != 'furigana_segments') {
      return null;
    }
    final rawBox = json['bbox_norm'];
    if (rawBox is! List || rawBox.length != 4) return null;
    final box = <double>[];
    for (final v in rawBox) {
      if (v is num) {
        box.add(v.toDouble());
      } else {
        return null;
      }
    }
    final rawSegs = transformed['value'];
    if (rawSegs is! List) return null;
    final segs = <FuriganaSegment>[];
    for (final s in rawSegs) {
      if (s is Map) {
        final seg = FuriganaSegment.fromJson(Map<String, dynamic>.from(s));
        if (seg != null) segs.add(seg);
      }
    }
    if (segs.isEmpty) return null;
    return FuriganaRegion(
      id: json['id']?.toString() ?? '',
      bboxNorm: box,
      segments: segs,
    );
  }
}

/// A full page of furigana metadata.
class FuriganaPageMeta {
  final int imageWidth;
  final int imageHeight;
  final List<FuriganaRegion> regions;

  const FuriganaPageMeta({
    required this.imageWidth,
    required this.imageHeight,
    required this.regions,
  });

  static FuriganaPageMeta parse(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map) {
      return const FuriganaPageMeta(imageWidth: 0, imageHeight: 0, regions: []);
    }
    final image = decoded['image'];
    final width = (image is Map && image['width'] is num)
        ? (image['width'] as num).toInt()
        : 0;
    final height = (image is Map && image['height'] is num)
        ? (image['height'] as num).toInt()
        : 0;
    final regions = <FuriganaRegion>[];
    final rawRegions = decoded['regions'];
    if (rawRegions is List) {
      for (final r in rawRegions) {
        if (r is Map) {
          final region = FuriganaRegion.fromJson(Map<String, dynamic>.from(r));
          if (region != null) regions.add(region);
        }
      }
    }
    return FuriganaPageMeta(
      imageWidth: width,
      imageHeight: height,
      regions: regions,
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd client && flutter test test/furigana_meta_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/models/furigana_region.dart client/test/furigana_meta_test.dart
git commit -m "feat(furigana): add furigana metadata models + parser"
```

---

## Task 2: VocabEntry model

**Files:**
- Create: `client/lib/models/vocab_entry.dart`
- Test: `client/test/vocab_entry_test.dart`

**Interfaces:**
- Produces:
  - `class VocabEntry { final String word; final String? readingOverride; final bool known; final DateTime updatedAt; }`
  - `VocabEntry.copyWith({String? readingOverride, bool clearOverride, bool? known, DateTime? updatedAt})`
  - `Map<String, dynamic> toJson()` / `static VocabEntry? fromJson(Map<String, dynamic>)`

- [ ] **Step 1: Write the failing test**

Create `client/test/vocab_entry_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd client && flutter test test/vocab_entry_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `client/lib/models/vocab_entry.dart`:

```dart
/// A single vocabulary entry, keyed on the surface form of a word.
class VocabEntry {
  final String word;
  final String? readingOverride;
  final bool known;
  final DateTime updatedAt;

  const VocabEntry({
    required this.word,
    this.readingOverride,
    required this.known,
    required this.updatedAt,
  });

  VocabEntry copyWith({
    String? readingOverride,
    bool clearOverride = false,
    bool? known,
    DateTime? updatedAt,
  }) {
    return VocabEntry(
      word: word,
      readingOverride:
          clearOverride ? null : (readingOverride ?? this.readingOverride),
      known: known ?? this.known,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'word': word,
        if (readingOverride != null) 'reading_override': readingOverride,
        'known': known,
        'updated_at': updatedAt.toIso8601String(),
      };

  static VocabEntry? fromJson(Map<String, dynamic> json) {
    final word = json['word'];
    if (word is! String || word.isEmpty) return null;
    final reading = json['reading_override'];
    final updated = json['updated_at'];
    return VocabEntry(
      word: word,
      readingOverride:
          reading is String && reading.isNotEmpty ? reading : null,
      known: json['known'] == true,
      updatedAt: updated is String
          ? (DateTime.tryParse(updated) ?? DateTime.fromMillisecondsSinceEpoch(0))
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd client && flutter test test/vocab_entry_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/models/vocab_entry.dart client/test/vocab_entry_test.dart
git commit -m "feat(furigana): add VocabEntry model"
```

---

## Task 3: VocabRepository (file-backed store)

**Files:**
- Create: `client/lib/services/vocab_repository.dart`
- Test: `client/test/vocab_repository_test.dart`

**Interfaces:**
- Consumes: `VocabEntry` (Task 2).
- Produces:
  - `class VocabRepository extends ChangeNotifier`
  - `VocabRepository({File? file})` — when `file` is null, `load()` resolves a default path via `path_provider`.
  - `Future<void> load()`
  - `VocabEntry? entryFor(String word)`
  - `Future<void> setKnown(String word, bool known)`
  - `Future<void> setReadingOverride(String word, String? reading)` (empty/null clears override)
  - `Map<String, VocabEntry> get entries` (unmodifiable)

- [ ] **Step 1: Write the failing test**

Create `client/test/vocab_repository_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd client && flutter test test/vocab_repository_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `client/lib/services/vocab_repository.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/vocab_entry.dart';

/// On-device vocabulary store, backed by a JSON file.
///
/// Keyed on the surface form of a word. Tolerates a missing or corrupt
/// backing file by starting empty.
class VocabRepository extends ChangeNotifier {
  VocabRepository({File? file}) : _file = file;

  File? _file;
  final Map<String, VocabEntry> _entries = {};
  bool _loaded = false;

  Map<String, VocabEntry> get entries => Map.unmodifiable(_entries);

  VocabEntry? entryFor(String word) => _entries[word];

  Future<void> load() async {
    _file ??= await _defaultFile();
    _entries.clear();
    try {
      if (await _file!.exists()) {
        final raw = await _file!.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final entry =
                  VocabEntry.fromJson(Map<String, dynamic>.from(item));
              if (entry != null) _entries[entry.word] = entry;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[Vocab] load failed, starting empty: $e');
      _entries.clear();
    }
    _loaded = true;
  }

  Future<void> setKnown(String word, bool known) async {
    final existing = _entries[word];
    _entries[word] = (existing ??
            VocabEntry(word: word, known: false, updatedAt: DateTime.now()))
        .copyWith(known: known, updatedAt: DateTime.now());
    await _persist();
  }

  Future<void> setReadingOverride(String word, String? reading) async {
    final existing = _entries[word];
    final normalized = (reading != null && reading.trim().isNotEmpty)
        ? reading.trim()
        : null;
    final base = existing ??
        VocabEntry(word: word, known: false, updatedAt: DateTime.now());
    _entries[word] = normalized == null
        ? base.copyWith(clearOverride: true, updatedAt: DateTime.now())
        : base.copyWith(readingOverride: normalized, updatedAt: DateTime.now());
    await _persist();
  }

  Future<void> _persist() async {
    notifyListeners();
    try {
      _file ??= await _defaultFile();
      final list = _entries.values.map((e) => e.toJson()).toList();
      await _file!.writeAsString(jsonEncode(list));
    } catch (e) {
      debugPrint('[Vocab] persist failed: $e');
    }
  }

  Future<File> _defaultFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'frank_vocab.json'));
  }

  bool get isLoaded => _loaded;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd client && flutter test test/vocab_repository_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/services/vocab_repository.dart client/test/vocab_repository_test.dart
git commit -m "feat(furigana): add file-backed VocabRepository"
```

---

## Task 4: Furigana display resolver (pure)

**Files:**
- Create: `client/lib/furigana/furigana_resolver.dart`
- Test: `client/test/furigana_resolver_test.dart`

**Interfaces:**
- Consumes: `FuriganaSegment` (Task 1), `VocabEntry` (Task 2).
- Produces:
  - `class FuriganaDisplay { final String baseText; final String? reading; final String? altReading; final bool isVocabWord; final bool known; }`
  - `FuriganaDisplay resolveFurigana(FuriganaSegment segment, VocabEntry? entry)`
  - Rules: non-kanji segment → not a vocab word, no reading. Known → reading hidden. Override present → reading = override, and `altReading` = model reading when it differs. No override & not known → reading = model furigana.

- [ ] **Step 1: Write the failing test**

Create `client/test/furigana_resolver_test.dart`:

```dart
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd client && flutter test test/furigana_resolver_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `client/lib/furigana/furigana_resolver.dart`:

```dart
import '../models/furigana_region.dart';
import '../models/vocab_entry.dart';

/// Resolved display state for a single segment, combining the model's
/// furigana with the user's vocab entry.
class FuriganaDisplay {
  final String baseText;
  final String? reading; // null => no furigana shown
  final String? altReading; // model reading when overridden and different
  final bool isVocabWord; // interactive (contains kanji)
  final bool known;

  const FuriganaDisplay({
    required this.baseText,
    required this.reading,
    required this.altReading,
    required this.isVocabWord,
    required this.known,
  });
}

/// Pure resolver: given a segment and optional vocab entry, decide what to show.
FuriganaDisplay resolveFurigana(FuriganaSegment segment, VocabEntry? entry) {
  if (!segment.needsFurigana) {
    return FuriganaDisplay(
      baseText: segment.text,
      reading: null,
      altReading: null,
      isVocabWord: false,
      known: false,
    );
  }

  final known = entry?.known ?? false;
  final override = entry?.readingOverride;

  if (known) {
    return FuriganaDisplay(
      baseText: segment.text,
      reading: null,
      altReading: null,
      isVocabWord: true,
      known: true,
    );
  }

  if (override != null && override.isNotEmpty) {
    return FuriganaDisplay(
      baseText: segment.text,
      reading: override,
      altReading: override != segment.furigana ? segment.furigana : null,
      isVocabWord: true,
      known: false,
    );
  }

  return FuriganaDisplay(
    baseText: segment.text,
    reading: segment.furigana,
    altReading: null,
    isVocabWord: true,
    known: false,
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd client && flutter test test/furigana_resolver_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/furigana/furigana_resolver.dart client/test/furigana_resolver_test.dart
git commit -m "feat(furigana): add pure furigana display resolver"
```

---

## Task 5: Burned-overlay policy (pure)

**Files:**
- Create: `client/lib/furigana/overlay_policy.dart`
- Test: `client/test/overlay_policy_test.dart`

**Interfaces:**
- Produces: `bool shouldApplyBurnedOverlay(String? pipeline)` — returns `false` only for `'manga_furigana'`, `true` otherwise (including null/unknown).

- [ ] **Step 1: Write the failing test**

Create `client/test/overlay_policy_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd client && flutter test test/overlay_policy_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `client/lib/furigana/overlay_policy.dart`:

```dart
/// Whether the server's burned/rendered image should be swapped into the
/// reader WebView for a given pipeline.
///
/// Furigana pages are read in the interactive viewer instead, so we do not
/// overwrite the original page image in Kindle.
bool shouldApplyBurnedOverlay(String? pipeline) {
  return pipeline != 'manga_furigana';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd client && flutter test test/overlay_policy_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/furigana/overlay_policy.dart client/test/overlay_policy_test.dart
git commit -m "feat(furigana): add burned-overlay suppression policy"
```

---

## Task 6: ApiService.metaPath + fetchMeta

**Files:**
- Modify: `client/lib/services/api_service.dart`
- Test: `client/test/api_meta_path_test.dart`

**Interfaces:**
- Consumes: `FuriganaPageMeta` (Task 1), existing `ServerSettings`, `ApiException`.
- Produces (add to `ApiService`):
  - `static String metaPath(String pipeline, String sourceHash)` → `/api/v1/cache/by-hash/<pipeline>/<sourceHash>/meta`
  - `Future<FuriganaPageMeta> fetchMeta({required ServerSettings settings, required String metaUrl})`

- [ ] **Step 1: Write the failing test**

Create `client/test/api_meta_path_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd client && flutter test test/api_meta_path_test.dart`
Expected: FAIL — `metaPath` is not defined on `ApiService`.

- [ ] **Step 3: Write minimal implementation**

In `client/lib/services/api_service.dart`, add the import at the top with the other imports:

```dart
import '../models/furigana_region.dart';
```

Then add these two members inside the `ApiService` class (e.g. immediately after `getJobImage`):

```dart
  /// Build the relative meta endpoint path for a cached page.
  static String metaPath(String pipeline, String sourceHash) {
    final p = Uri.encodeComponent(pipeline);
    final h = Uri.encodeComponent(sourceHash);
    return '/api/v1/cache/by-hash/$p/$h/meta';
  }

  /// Fetch and parse furigana region metadata for a cached page.
  Future<FuriganaPageMeta> fetchMeta({
    required ServerSettings settings,
    required String metaUrl,
  }) async {
    final uri = metaUrl.startsWith('http')
        ? Uri.parse(metaUrl)
        : Uri.parse('${settings.serverUrl}$metaUrl');
    final response = await _client
        .get(uri, headers: _headers(settings))
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw ApiException(
        'Meta fetch failed (${response.statusCode})',
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500,
      );
    }
    return FuriganaPageMeta.parse(response.body);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd client && flutter test test/api_meta_path_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `cd client && flutter test`
Expected: PASS (all existing + new tests).

- [ ] **Step 6: Commit**

```bash
git add client/lib/services/api_service.dart client/test/api_meta_path_test.dart
git commit -m "feat(furigana): add ApiService.metaPath + fetchMeta"
```

---

## Task 7: vocabRepositoryProvider + FuriganaWord widget

**Files:**
- Create: `client/lib/providers/vocab_provider.dart`
- Create: `client/lib/widgets/furigana_word.dart`
- Test: `client/test/furigana_word_test.dart`

**Interfaces:**
- Consumes: `VocabRepository` (Task 3), `FuriganaDisplay` + `resolveFurigana` (Task 4).
- Produces:
  - `final vocabRepositoryProvider = ChangeNotifierProvider<VocabRepository>(...)`
  - `class FuriganaWord extends StatelessWidget { const FuriganaWord({required this.display, this.onTap}); final FuriganaDisplay display; final VoidCallback? onTap; }`

- [ ] **Step 1: Write the failing test**

Create `client/test/furigana_word_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd client && flutter test test/furigana_word_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write minimal implementations**

Create `client/lib/providers/vocab_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/vocab_repository.dart';

/// App-wide on-device vocabulary store. Kicks off an async load immediately;
/// widgets rebuild via ChangeNotifier once entries change.
final vocabRepositoryProvider = ChangeNotifierProvider<VocabRepository>((ref) {
  final repo = VocabRepository();
  repo.load();
  return repo;
});
```

Create `client/lib/widgets/furigana_word.dart`:

```dart
import 'package:flutter/material.dart';
import '../furigana/furigana_resolver.dart';

/// Renders a single word segment: faint furigana reading above the base text.
/// Tapping a vocab word invokes [onTap].
class FuriganaWord extends StatelessWidget {
  const FuriganaWord({super.key, required this.display, this.onTap});

  final FuriganaDisplay display;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (display.reading != null)
          Opacity(
            opacity: 0.7,
            child: Text(
              display.reading!,
              style: const TextStyle(
                fontSize: 9,
                height: 1.0,
                color: Colors.redAccent,
              ),
            ),
          ),
        Text(
          display.baseText,
          style: const TextStyle(fontSize: 16, height: 1.0),
        ),
      ],
    );

    if (!display.isVocabWord) return content;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: content,
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd client && flutter test test/furigana_word_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add client/lib/providers/vocab_provider.dart client/lib/widgets/furigana_word.dart client/test/furigana_word_test.dart
git commit -m "feat(furigana): add vocab provider + FuriganaWord widget"
```

---

## Task 8: FuriganaView screen + focus panel

**Files:**
- Create: `client/lib/screens/furigana_view_screen.dart`
- Test: `client/test/furigana_view_test.dart`

**Interfaces:**
- Consumes: `FuriganaPageMeta`/`FuriganaRegion`/`FuriganaSegment` (Task 1), `vocabRepositoryProvider` (Task 7), `resolveFurigana` (Task 4), `FuriganaWord` (Task 7), `VocabRepository` (Task 3), `ApiService.fetchMeta`/`metaPath` (Task 6), existing `PageJob`, `apiServiceProvider`, `settingsProvider`.
- Produces:
  - `class FuriganaView extends ConsumerWidget { const FuriganaView({required this.meta, required this.imageBytes}); final FuriganaPageMeta meta; final Uint8List imageBytes; }` — presentational; renders image + overlay; opens focus panel on word tap.
  - `class FuriganaPageLoader extends ConsumerStatefulWidget { const FuriganaPageLoader({required this.job}); final PageJob job; }` — fetches meta then shows `FuriganaView`.

Note: `apiServiceProvider` and `settingsProvider` already exist (see `lib/providers/jobs_provider.dart` and `lib/providers/settings_provider.dart`). `PageJob` exposes `originalImage`, `pipeline`, and `sourceHash`.

- [ ] **Step 1: Write the failing test**

Create `client/test/furigana_view_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';
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
    {"id": "r1", "bbox_norm": [0.1, 0.1, 0.9, 0.9],
     "transformed": {"kind": "furigana_segments", "value": [
       {"text": "食べ", "furigana": "たべ", "needs_furigana": true},
       {"text": "る", "furigana": null, "needs_furigana": false}
     ]}}
  ]
}''');

void main() {
  testWidgets('renders furigana reading over a bubble', (tester) async {
    final repo = VocabRepository(file: null);
    await repo.load();
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
    final repo = VocabRepository(file: null);
    await repo.load();
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

    // Furigana for that word is now hidden.
    expect(find.text('たべ'), findsNothing);
    expect(repo.entryFor('食べ')!.known, true);
  });
}
```

Note on `VocabRepository(file: null)` in tests: passing `file: null` makes `load()` try `path_provider`, which is unavailable in `flutter test`. To keep the repo purely in-memory for widget tests, add a temp file instead:

```dart
import 'dart:io';
// ...
final tmp = await Directory.systemTemp.createTemp('furi_view');
final repo = VocabRepository(file: File('${tmp.path}/v.json'));
await repo.load();
```

Use the temp-file form in **both** tests above (replace the `file: null` lines).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd client && flutter test test/furigana_view_test.dart`
Expected: FAIL — URI does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `client/lib/screens/furigana_view_screen.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../furigana/furigana_resolver.dart';
import '../models/furigana_region.dart';
import '../models/page_job.dart';
import '../providers/connection_provider.dart' show apiServiceProvider;
import '../providers/settings_provider.dart';
import '../providers/vocab_provider.dart';
import '../services/vocab_repository.dart';
import '../widgets/furigana_word.dart';

/// Presentational interactive furigana view: original page image with a
/// per-bubble furigana overlay. Non-destructive — the image is never modified.
class FuriganaView extends ConsumerWidget {
  const FuriganaView({super.key, required this.meta, required this.imageBytes});

  final FuriganaPageMeta meta;
  final Uint8List imageBytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuild when vocab changes.
    ref.watch(vocabRepositoryProvider);
    final repo = ref.read(vocabRepositoryProvider);

    final aspect = (meta.imageWidth > 0 && meta.imageHeight > 0)
        ? meta.imageWidth / meta.imageHeight
        : 1.0;

    return Scaffold(
      appBar: AppBar(title: const Text('Furigana')),
      backgroundColor: Colors.black,
      body: Center(
        child: InteractiveViewer(
          maxScale: 6,
          child: AspectRatio(
            aspectRatio: aspect,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;
                return Stack(
                  children: [
                    Positioned.fill(
                      child: Image.memory(imageBytes, fit: BoxFit.fill),
                    ),
                    for (final region in meta.regions)
                      Positioned(
                        left: region.bboxNorm[0] * w,
                        top: region.bboxNorm[1] * h,
                        width:
                            (region.bboxNorm[2] - region.bboxNorm[0]) * w,
                        height:
                            (region.bboxNorm[3] - region.bboxNorm[1]) * h,
                        child: _RegionOverlay(
                          region: region,
                          repo: repo,
                          onWordTap: (seg) =>
                              _openFocusPanel(context, repo, seg),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _openFocusPanel(
    BuildContext context,
    VocabRepository repo,
    FuriganaSegment segment,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _FocusPanel(repo: repo, segment: segment),
    );
  }
}

/// Lays out one bubble's segments as tappable furigana words.
class _RegionOverlay extends StatelessWidget {
  const _RegionOverlay({
    required this.region,
    required this.repo,
    required this.onWordTap,
  });

  final FuriganaRegion region;
  final VocabRepository repo;
  final void Function(FuriganaSegment) onWordTap;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final seg in region.segments)
            FuriganaWord(
              display: resolveFurigana(seg, repo.entryFor(seg.text)),
              onTap: seg.needsFurigana ? () => onWordTap(seg) : null,
            ),
        ],
      ),
    );
  }
}

/// Bottom-sheet controls for a single word: reading, override, known toggle.
class _FocusPanel extends StatefulWidget {
  const _FocusPanel({required this.repo, required this.segment});

  final VocabRepository repo;
  final FuriganaSegment segment;

  @override
  State<_FocusPanel> createState() => _FocusPanelState();
}

class _FocusPanelState extends State<_FocusPanel> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final entry = widget.repo.entryFor(widget.segment.text);
    _controller = TextEditingController(
      text: entry?.readingOverride ?? widget.segment.furigana ?? '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.repo.entryFor(widget.segment.text);
    final known = entry?.known ?? false;
    final display = resolveFurigana(widget.segment, entry);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.segment.text,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (display.altReading != null)
            Text('Model reading: ${display.altReading}',
                style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'Reading (your override)',
            ),
            onSubmitted: (value) async {
              await widget.repo.setReadingOverride(widget.segment.text, value);
              if (context.mounted) Navigator.pop(context);
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton(
                key: const ValueKey('vocab-mark-known'),
                onPressed: () async {
                  await widget.repo.setKnown(widget.segment.text, !known);
                  if (context.mounted) Navigator.pop(context);
                },
                child: Text(known ? 'Mark as unknown' : 'I know this word'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () async {
                  await widget.repo
                      .setReadingOverride(widget.segment.text, _controller.text);
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Save reading'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Fetches furigana metadata for [job], then shows [FuriganaView].
class FuriganaPageLoader extends ConsumerStatefulWidget {
  const FuriganaPageLoader({super.key, required this.job});

  final PageJob job;

  @override
  ConsumerState<FuriganaPageLoader> createState() => _FuriganaPageLoaderState();
}

class _FuriganaPageLoaderState extends ConsumerState<FuriganaPageLoader> {
  FuriganaPageMeta? _meta;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final settings = ref.read(settingsProvider);
      final api = ref.read(apiServiceProvider);
      final pipeline = widget.job.pipeline ?? 'manga_furigana';
      final hash = widget.job.sourceHash;
      if (hash == null || hash.isEmpty) {
        throw StateError('Page has no source hash yet');
      }
      final meta = await api.fetchMeta(
        settings: settings,
        metaUrl: ApiServiceMetaPath(pipeline, hash).path,
      );
      if (mounted) setState(() => _meta = meta);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.job.originalImage;
    if (image == null) {
      return const Scaffold(
        body: Center(child: Text('Original page image is unavailable.')),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Furigana')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load furigana: $_error'),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final meta = _meta;
    if (meta == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return FuriganaView(meta: meta, imageBytes: image);
  }
}

/// Tiny helper so the loader can build the meta path without importing
/// ApiService statics into the widget layer directly.
class ApiServiceMetaPath {
  ApiServiceMetaPath(this.pipeline, this.sourceHash);
  final String pipeline;
  final String sourceHash;
  String get path {
    final p = Uri.encodeComponent(pipeline);
    final h = Uri.encodeComponent(sourceHash);
    return '/api/v1/cache/by-hash/$p/$h/meta';
  }
}
```

Note: `apiServiceProvider` is defined in `lib/providers/connection_provider.dart` (verified). If a linter flags the small `ApiServiceMetaPath` helper as redundant with `ApiService.metaPath`, replace `ApiServiceMetaPath(pipeline, hash).path` with `ApiService.metaPath(pipeline, hash)` and import `../services/api_service.dart`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd client && flutter test test/furigana_view_test.dart`
Expected: PASS (2 tests). If the image decode warns, the `await tester.pump()` after mounting handles it; the 1x1 PNG decodes synchronously enough for `find.text` assertions which do not depend on the image.

- [ ] **Step 5: Run the full suite**

Run: `cd client && flutter test`
Expected: PASS (all).

- [ ] **Step 6: Commit**

```bash
git add client/lib/screens/furigana_view_screen.dart client/test/furigana_view_test.dart
git commit -m "feat(furigana): add interactive FuriganaView + focus panel"
```

---

## Task 9: Reader entry point + suppress burned overlay for furigana

**Files:**
- Modify: `client/lib/screens/reader_screen.dart`
- Test: (covered by `test/overlay_policy_test.dart` from Task 5; no new test file — this task wires pure, already-tested logic into the reader and adds a navigation affordance that the existing suite does not unit-test, consistent with the reader's current WebView-heavy, source-level testing approach.)

**Interfaces:**
- Consumes: `shouldApplyBurnedOverlay` (Task 5), `FuriganaPageLoader` (Task 8), existing `PageJob`, `jobsProvider`, `_currentKindlePageId`.

- [ ] **Step 1: Add imports**

At the top of `client/lib/screens/reader_screen.dart`, with the other local imports, add:

```dart
import '../furigana/overlay_policy.dart';
import 'furigana_view_screen.dart';
```

- [ ] **Step 2: Suppress the burned overlay for furigana pages**

In `_applyOverlay` (starts at `Future<void> _applyOverlay(String pageId, Uint8List imageBytes) async {`), insert a guard as the first statements inside the method, right after the existing `final controller = _webController; if (controller == null) return;` lines:

```dart
    // Furigana pages are read in the interactive viewer, not overwritten in Kindle.
    final job = ref.read(jobsProvider)[pageId];
    if (!shouldApplyBurnedOverlay(job?.pipeline)) {
      return;
    }
```

- [ ] **Step 3: Add the entry-point FAB**

The `build` method returns `Scaffold(body: SafeArea(...))` (around line 149). Add a `floatingActionButton` argument to that `Scaffold` (as a sibling of `body:`):

```dart
      floatingActionButton: _buildFuriganaFab(),
```

Then add this method to the reader state class (near `_applyOverlay`):

```dart
  Widget? _buildFuriganaFab() {
    final pageId = _currentKindlePageId;
    if (pageId == null) return null;
    final job = ref.watch(jobsProvider)[pageId];
    if (job == null ||
        !job.isComplete ||
        job.pipeline != 'manga_furigana' ||
        job.originalImage == null) {
      return null;
    }
    return FloatingActionButton.extended(
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FuriganaPageLoader(job: job),
          ),
        );
      },
      icon: const Icon(Icons.menu_book),
      label: const Text('Furigana'),
    );
  }
```

Note: confirm the field name holding the current Kindle page id. This plan assumes `_currentKindlePageId` (referenced at reader_screen.dart:462 and :831). If the reader class is a `ConsumerState`, `ref.watch` is available in `build`; if the FAB is built outside `build`, use `ref.read` and trigger rebuilds through the existing job-completion `setState` path already present in the file.

- [ ] **Step 4: Verify it compiles and existing tests pass**

Run: `cd client && flutter analyze` then `cd client && flutter test`
Expected: analyze reports no new errors; all tests PASS.

- [ ] **Step 5: Manual smoke check (documented, not automated)**

On a device/emulator with a running server:
1. Open a Kindle manga page with the pipeline set to `manga_furigana`.
2. Confirm the page is **not** overwritten with burned furigana (original stays).
3. Confirm the "Furigana" FAB appears once the job completes; tap it.
4. In the viewer: confirm faint furigana appears over bubbles; tap a word; mark it known; confirm its furigana disappears and stays gone after reopening the viewer.

- [ ] **Step 6: Commit**

```bash
git add client/lib/screens/reader_screen.dart
git commit -m "feat(furigana): open interactive viewer from reader; suppress burned furigana overlay"
```

---

## Final verification

- [ ] Run the whole client suite: `cd client && flutter test` → all PASS.
- [ ] Run `cd client && flutter analyze` → no new warnings/errors.
- [ ] Confirm no files under `server/` were modified: `git diff --name-only master -- server/` prints nothing.

---

## Self-Review notes (for the planner)

- **Spec coverage:** non-destructive original image (Task 8 `FuriganaView` uses `job.originalImage`, never re-renders); always-on faint furigana + tap-to-focus (Tasks 7–8); known → hide furigana (Task 4 resolver + Task 8 rebuild); vocab override with model shown as alt (Task 4 + `_FocusPanel`); on-device storage (Task 3); consumes existing MetaURL, no server changes (Task 6, Global Constraints); suppress burned overlay for furigana (Tasks 5, 9); error handling — meta fetch retry (Task 8 loader), malformed regions skipped (Task 1), corrupt vocab fallback (Task 3), missing source image (Task 8 loader). Homograph/alignment/session-scope limitations are inherent to the design and not implemented away.
- **Naming consistency:** `resolveFurigana`, `FuriganaDisplay`, `FuriganaPageMeta.parse`, `shouldApplyBurnedOverlay`, `VocabRepository.{load,entryFor,setKnown,setReadingOverride}`, `vocabRepositoryProvider`, `FuriganaWord`, `FuriganaView`, `FuriganaPageLoader` are used identically across tasks.
- **Known implementation risk to watch:** the exact identifiers `_currentKindlePageId`, `apiServiceProvider`, and `settingsProvider` are assumed from the current source; each task that touches them includes a note to confirm/adjust the reference.
```
