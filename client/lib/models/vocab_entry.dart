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
