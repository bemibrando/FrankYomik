# SDD Progress — Interactive Furigana Editor

Plan: docs/superpowers/plans/2026-07-07-interactive-furigana-editor.md
Branch: feat/interactive-furigana-editor
Base commit (before Task 1): ac747f5

## Tasks
- Task 1: complete (commits ac747f5..6cb8794, 4/4 tests pass in Docker, review clean)
- Task 2: complete (commits 6cb8794..799f02a, 5/5 tests pass in Docker, review clean)
- Task 3: complete (commits 799f02a..6855a4b, 5/5 tests pass in Docker, review clean)
- Task 4: complete (commits 6855a4b..1259845, 6/6 tests pass in Docker, review clean)
- Task 5: complete (commit 36b9ff4, 4/4 tests pass in Docker, controller review clean)
- Task 6: complete (commit 50b2e93, full suite 80/80 pass in Docker, review clean)
- Task 7: complete (commit 704725e, 3/3 widget tests pass in Docker, review clean)
- Task 8: code committed (d7b20fa); tests fixed post-commit, 2/2 pass + full suite 85/85 in warm Docker container, analyze clean. Fix NOT yet committed — awaiting review.
- Task 9: pending

## Minor findings (for final review triage)
- Task 8 tests hung (not env): real dart:io I/O (`Directory.systemTemp.createTemp`, `repo.load()`) ran directly in the `testWidgets` fake-async zone, so the awaited futures never completed. Fixed by wrapping setup I/O in `tester.runAsync()`.
- Task 8 widget: `_FocusPanel` handlers awaited `repo.setKnown`/`setReadingOverride` (which do disk writes) before `Navigator.pop`, blocking sheet dismissal on persistence — hung the fake-async test and is a real UX smell. Changed to optimistic UI: in-memory update + `notifyListeners()` fire synchronously, panel closes immediately, write persists in background via `unawaited(...)`. Repo persistence is already best-effort (try/catch).
- Removed unused `dart:typed_data` import from furigana_view_test.dart.

## Test environment note
Flutter/Dart not installed on host; tests run in Docker. The OneDrive-backed bind mount deadlocks Flutter's build I/O (0% CPU hang). Reliable approach: warm container `furi_warm` that copies source into container-local fs (excluding build/.dart_tool/.git), runs `pub get` once, then `docker exec` individual `flutter test` runs (~8s each) instead of re-provisioning per run.
