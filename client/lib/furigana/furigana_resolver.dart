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

/// One character (or an unsplittable kanji run) with its own furigana, used to
/// stack characters vertically with ruby beside each kanji.
class RubyUnit {
  final String base;
  final String? furigana;
  const RubyUnit(this.base, this.furigana);
}

bool _isKana(int rune) => rune >= 0x3040 && rune <= 0x30FF;

/// Splits a word + its reading into per-character ruby units so vertical text
/// can stack each character with its own reading. Kana already present in the
/// base act as anchors to align the reading (e.g. 抜け出 / ぬけだ ->
/// 抜=ぬ, け, 出=だ). A kanji run whose length doesn't match its reading is
/// kept grouped (e.g. 一人 / ひとり stays together).
List<RubyUnit> distributeRuby(String base, String? reading) {
  final b = base.runes.toList();
  if (reading == null || reading.isEmpty) {
    return [for (final r in b) RubyUnit(String.fromCharCode(r), null)];
  }
  final rd = reading.runes.toList();
  final units = <RubyUnit>[];
  var i = 0, j = 0;
  while (i < b.length) {
    if (_isKana(b[i])) {
      if (j < rd.length && rd[j] == b[i]) j++; // consume the matching kana
      units.add(RubyUnit(String.fromCharCode(b[i]), null));
      i++;
      continue;
    }
    // A run of consecutive kanji; its reading runs up to the next kana anchor.
    final start = i;
    while (i < b.length && !_isKana(b[i])) {
      i++;
    }
    final run = b.sublist(start, i);
    int k;
    if (i < b.length) {
      final anchor = b[i];
      k = j;
      while (k < rd.length && rd[k] != anchor) {
        k++;
      }
    } else {
      k = rd.length;
    }
    final runReading = rd.sublist(j, k);
    j = k;
    if (run.length == runReading.length) {
      for (var m = 0; m < run.length; m++) {
        units.add(RubyUnit(
            String.fromCharCode(run[m]), String.fromCharCode(runReading[m])));
      }
    } else {
      units.add(RubyUnit(String.fromCharCodes(run),
          runReading.isEmpty ? null : String.fromCharCodes(runReading)));
    }
  }
  return units;
}
