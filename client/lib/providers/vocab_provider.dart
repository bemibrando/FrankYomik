import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/vocab_repository.dart';

/// App-wide on-device vocabulary store. Kicks off an async load immediately;
/// widgets rebuild via ChangeNotifier once entries change.
final vocabRepositoryProvider = ChangeNotifierProvider<VocabRepository>((ref) {
  final repo = VocabRepository();
  repo.load();
  return repo;
});
