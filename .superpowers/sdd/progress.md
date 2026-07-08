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
- Task 8: complete (code d7b20fa; test/widget fix e00836d). 2/2 tests pass, full suite 85/85, analyze clean.
- Task 9: complete (reader entry FAB + burned-overlay suppression). Full suite 85/85, full-project analyze clean, no server/ changes in branch. No new test file (pure wiring over Task 5's tested logic, per plan).

## Minor findings (for final review triage)
- Task 8 tests hung (not env): real dart:io I/O (`Directory.systemTemp.createTemp`, `repo.load()`) ran directly in the `testWidgets` fake-async zone, so the awaited futures never completed. Fixed by wrapping setup I/O in `tester.runAsync()`.
- Task 8 widget: `_FocusPanel` handlers awaited `repo.setKnown`/`setReadingOverride` (which do disk writes) before `Navigator.pop`, blocking sheet dismissal on persistence — hung the fake-async test and is a real UX smell. Changed to optimistic UI: in-memory update + `notifyListeners()` fire synchronously, panel closes immediately, write persists in background via `unawaited(...)`. Repo persistence is already best-effort (try/catch).
- Removed unused `dart:typed_data` import from furigana_view_test.dart.

## Post-plan additions
- Local folder reader (desktop): `client/lib/screens/local_folder_screen.dart` — read a local folder of manga raws (e.g. docs/adult) with interactive furigana, no Kindle/WebView. dart:io path read (desktop only), submits each page to the manga_furigana pipeline, then shows Task 8 `FuriganaView`. Home entry added. Pure `sortedImageNames` helper unit-tested (4 tests). Full suite 89/89, analyze clean. NOT runtime-verified on a desktop GUI (headless container) — network loader follows the untested-by-design `FuriganaPageLoader` precedent; needs Flutter desktop toolchain + running server to actually run.

## Test environment note
Flutter/Dart not installed on host; tests run in Docker. The OneDrive-backed bind mount deadlocks Flutter's build I/O (0% CPU hang). Reliable approach: warm container `furi_warm` that copies source into container-local fs (excluding build/.dart_tool/.git), runs `pub get` once, then `docker exec` individual `flutter test` runs (~8s each) instead of re-provisioning per run.
