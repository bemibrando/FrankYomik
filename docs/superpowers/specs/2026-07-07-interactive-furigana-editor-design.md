# Interactive Furigana Editor — Design

**Date:** 2026-07-07
**Status:** Approved (design); pending implementation plan
**Scope:** Manga furigana pipeline only (not `manga_translate`, not `webtoon`)

## Problem

Today the `manga_furigana` pipeline **bakes** vertical furigana into a rendered
PNG, and the Flutter reader swaps the whole Kindle page `<img>` for that blob.
The result is destructive (readings are burned into a flat image) and
non-interactive (you can't correct a wrong reading, and you can't tell the app
which words you already know).

We want an **editor/reader** that, instead of overwriting the page:

- keeps the original manga image intact and shows furigana as a live,
  toggleable layer;
- reveals furigana per word and lets you focus a word to inspect/correct it;
- lets you keep a personal vocabulary list that **overrides** the model's
  reading when they disagree;
- lets you mark words known/unknown — **known words hide their furigana**
  (default is to show furigana).

## Key constraints discovered

- **manga-ocr returns only a text string per bubble — no per-word/per-character
  geometry.** We know each bubble's bounding box and its full text (which
  `kindle/furigana.py` already splits into word segments), but not where each
  word sits in the image. So furigana cannot be pixel-aligned to individual
  glyphs; interaction is at the **bubble** level for geometry and the **word**
  level for furigana/vocab.
- The furigana metadata the client needs **already exists and is already
  served.** Each result carries a `MetaURL`
  (`GET /api/v1/cache/by-hash/{pipeline}/{source_hash}/meta`) whose `regions[]`
  include `ocr_text`, `bbox_norm`, `is_valid`, `kind`, and
  `transformed = {kind: "furigana_segments", value: [ {text, furigana,
  needs_furigana}, ... ]}`. **No new server pipeline work is required.**

## Decisions

| Decision | Choice |
|---|---|
| Scope | `manga_furigana` pipeline only |
| Destructiveness | Non-destructive — source image never modified; furigana is a live toggleable layer, never baked into the cache by this feature |
| Reveal UX | Always-on faint furigana over bubbles; tap a word to focus it |
| Known words | Default show furigana; mark a word "known" → hide its furigana |
| Corrections | Your saved vocab reading auto-overrides the model; the model's differing reading is shown as a dismissible alternative |
| Vocab storage | On-device (Flutter), JSON-file-backed. No server changes |
| Server pipeline | Unchanged. Server keeps burning the furigana image; the client ignores that image for furigana pages in this feature |

## Approach: staged

**Stage 1 (this spec): dedicated interactive Flutter view.** The hard logic
(furigana rendering, vocab, known/override application) lives in a
self-contained Flutter module surfaced through a native page viewer. Both the
image and the overlay are Flutter, so zoom/pan alignment is robust and the
correcting UX is the best available.

**Stage 2 (future, out of scope here): in-place always-on overlay.** Layer the
same module's faint furigana directly over the Kindle page inside the WebView so
furigana appears while flipping pages in Kindle. Deferred because keeping an
injected DOM overlay aligned through Kindle's pinch-zoom/pan is fragile; the
current image-swap dodges this only because it lives *inside* the `<img>`, which
a furigana layer cannot.

## Architecture (Stage 1)

Entirely client-side plus on-device storage. No server changes.

For a **furigana**-pipeline result, the client **stops swapping the burned image
into the Kindle WebView** and instead makes the interactive view available. The
server still produces the burned image (skipping that render is a later
optimization); the client simply does not overlay it for furigana pages.

The dedicated view renders the **original captured page image** — which the
client already holds in memory at submit time — in an `InteractiveViewer`, with
the furigana/vocab overlay composited on top.

## Components (all new, Flutter)

- **Models** — `FuriganaRegion` and `FuriganaSegment`, parsed from the meta
  JSON. A region has a normalized bubble box (`bbox_norm`), `kind`, `ocr_text`,
  and an ordered list of segments; a segment has `text`, `furigana` (nullable),
  and `needsFurigana`.
- **`VocabRepository`** — on-device JSON-file-backed store with an in-memory map
  and `ChangeNotifier`. Entry shape: `{word, readingOverride?, known: bool,
  updatedAt}`, keyed by surface word. Loads on startup; saves on mutation;
  tolerates a corrupt/missing file by falling back to empty.
- **`ApiService.fetchMeta(metaUrl)`** — the one missing HTTP method. Fetches and
  parses the region metadata, reusing the existing retry/backoff and auth
  patterns in `api_service.dart` / `jobs_provider.dart`.
- **`FuriganaView` screen** — renders the original page image in an
  `InteractiveViewer` and overlays each region's segments as faint ruby-style
  furigana, applying vocab state.
- **Word focus panel** — a bottom sheet opened by tapping a word: shows the
  effective reading, the model's reading as a dismissible alternative when it
  differs from a saved override, an edit-reading control, and a known/unknown
  toggle.
- **Reader entry point** — on a furigana-pipeline page, a control in
  `reader_screen.dart` opens `FuriganaView` for that page.

## Data & vocab flow

1. Furigana page is processed exactly as today; the client receives the result
   plus its `MetaURL` and retains the source image bytes it submitted.
2. User opens the interactive view → `fetchMeta(metaUrl)` → render the original
   image + overlay.
3. For each segment where `needsFurigana` is true, look up `vocab[segment.text]`:
   - if the entry is **known** → hide that segment's furigana;
   - if the entry has a **readingOverride** that differs from the model's
     `furigana` → show the override as the primary reading and the model's
     reading as a dismissible alternative.
4. Tap a word → focus panel → edit reading and/or mark known/unknown →
   `VocabRepository.save(...)` → overlay rebuilds live via the notifier.
5. Vocab persists on-device across sessions and app restarts.

## Vocab application logic (pure, unit-testable)

Given a `FuriganaSegment` and an optional `VocabEntry`, resolve display state:

- `needsFurigana == false` → no furigana, not interactive as vocab.
- entry is `known` → base text only, furigana hidden.
- entry has `readingOverride` → primary reading = override; if
  `override != segment.furigana`, expose the model reading as `alt`.
- otherwise → primary reading = `segment.furigana`, no alt.

This resolver is a pure function so it can be unit-tested independently of any
widget.

## Error handling

- **Meta fetch fails** → render the page image with no overlay plus a retry
  affordance (reuse `_withRetry` backoff).
- **Malformed region/segment** (missing bbox, non-list segments, bad types) →
  skip that region/segment; never crash the view.
- **Corrupt or missing vocab file** → fall back to an empty vocab; log and
  continue.
- **Source image unavailable** (see limitations) → the view is not offered for
  that page; show a brief explanation.

## Testing (all `cd client && flutter test`; no server test changes)

- **Unit**: meta JSON parsing (well-formed, empty, malformed); `VocabRepository`
  load/save round-trip and corrupt-file fallback; the vocab application resolver
  (known hides furigana, override replaces reading and surfaces alt, no-override
  passthrough).
- **Widget**: `FuriganaView` renders segments for a fixture page; tapping a word
  opens the focus panel; marking known hides that word's furigana; setting an
  override shows the model reading as the dismissible alternative.

## Known limitations (accepted for v1)

- **Homographs**: vocab is keyed on surface form, so a word with two
  context-dependent readings stores only one. A `(surface, model_reading)` (or
  lemma-based) key is a later refinement.
- **Alignment**: faint furigana sits within the bubble box, approximately over
  the text, not pixel-aligned to the underlying art glyphs.
- **Session scope**: the view needs the source image, so v1 targets pages
  captured in the current session; rendering the original for a previously
  cached page is a later add.
- **Server still burns the furigana image**; that wasted render is left in place
  to avoid server churn and can be skipped as a later optimization.

## Out of scope

- Stage 2 in-place WebView overlay.
- Any change to `manga_translate` or `webtoon` pipelines.
- Server-side vocab storage or cross-device sync.
- Editing/correcting the base OCR text (only readings and known/unknown here).
