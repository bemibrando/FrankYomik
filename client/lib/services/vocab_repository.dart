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
