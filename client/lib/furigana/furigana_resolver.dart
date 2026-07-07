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
