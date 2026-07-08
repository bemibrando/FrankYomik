import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../furigana/furigana_resolver.dart';
import '../furigana/romaji_kana.dart';
import '../models/furigana_region.dart';
import '../models/page_job.dart';
import '../providers/connection_provider.dart' show apiServiceProvider;
import '../providers/settings_provider.dart';
import '../providers/vocab_provider.dart';
import '../services/api_service.dart';
import '../services/vocab_repository.dart';
import '../widgets/furigana_word.dart';

/// Presentational interactive furigana view: original page image with a
/// per-bubble furigana overlay. Non-destructive — the image is never modified.
class FuriganaView extends ConsumerStatefulWidget {
  const FuriganaView({
    super.key,
    required this.meta,
    required this.imageBytes,
    this.onPreviousPage,
    this.onNextPage,
    this.pageLabel,
  });

  final FuriganaPageMeta meta;
  final Uint8List imageBytes;

  /// Called when the reader over-scrolls past the top / bottom edge (or taps
  /// the up / down buttons). Null disables that direction (at a boundary).
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;

  /// Shown in the app bar, e.g. "5 / 240".
  final String? pageLabel;

  @override
  ConsumerState<FuriganaView> createState() => _FuriganaViewState();
}

class _FuriganaViewState extends ConsumerState<FuriganaView> {
  // The page renders at full width and scrolls vertically. Over-scrolling past
  // an edge accumulates here; once the user "insists" past the threshold we
  // flip the page. Normal scrolling within the page resets it. Handled for
  // both touch/trackpad drags (OverscrollNotification) and the mouse wheel
  // (PointerScrollEvent) — the wheel does not reliably emit overscroll.
  final _controller = ScrollController();
  double _overscroll = 0;
  static const double _pageFlipThreshold = 160;

  // Per-bubble manual show/hide from double-tap. No entry = follow the default
  // (shown when the bubble has furigana to read). Reset when the page changes.
  final Map<String, bool> _override = {};

  @override
  void didUpdateWidget(covariant FuriganaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.meta, widget.meta)) {
      _override.clear();
      _overscroll = 0;
    }
  }

  void _setRegionShown(String id, bool shown) {
    setState(() => _override[id] = shown);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _accumulate(double delta) {
    _overscroll += delta; // >0 past the bottom, <0 past the top
    if (_overscroll >= _pageFlipThreshold && widget.onNextPage != null) {
      _overscroll = 0;
      widget.onNextPage!();
    } else if (_overscroll <= -_pageFlipThreshold &&
        widget.onPreviousPage != null) {
      _overscroll = 0;
      widget.onPreviousPage!();
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n is OverscrollNotification) {
      _accumulate(n.overscroll);
    } else if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      _overscroll = 0;
    }
    return false;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_controller.hasClients) return;
    final pos = _controller.position;
    final dy = e.scrollDelta.dy;
    if (dy > 0 && pos.pixels >= pos.maxScrollExtent) {
      _accumulate(dy); // wheeling down at the bottom edge
    } else if (dy < 0 && pos.pixels <= pos.minScrollExtent) {
      _accumulate(dy); // wheeling up at the top edge
    } else {
      _overscroll = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when vocab changes.
    ref.watch(vocabRepositoryProvider);
    final repo = ref.read(vocabRepositoryProvider);
    final meta = widget.meta;

    final aspect = (meta.imageWidth > 0 && meta.imageHeight > 0)
        ? meta.imageWidth / meta.imageHeight
        : 1.0;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pageLabel ?? 'Furigana'),
        actions: [
          IconButton(
            tooltip: 'Previous page',
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: widget.onPreviousPage,
          ),
          IconButton(
            tooltip: 'Next page',
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: widget.onNextPage,
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = w / aspect; // full page width; taller pages scroll
          return Listener(
            onPointerSignal: _onPointerSignal,
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: SingleChildScrollView(
                controller: _controller,
                physics: const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                ),
                child: SizedBox(
                  width: w,
                  height: h,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child:
                            Image.memory(widget.imageBytes, fit: BoxFit.fill),
                      ),
                      for (final region in meta.regions)
                        _positionedOverlay(context, region, w, h, repo),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Positions one bubble's overlay and derives its orientation + text size.
  /// Double-tapping a bubble hides its overlay (revealing the original art);
  /// double-tapping the same spot again brings it back.
  Widget _positionedOverlay(BuildContext context, FuriganaRegion region,
      double w, double h, VocabRepository repo) {
    final baseW = (region.bboxNorm[2] - region.bboxNorm[0]) * w;
    final baseH = (region.bboxNorm[3] - region.bboxNorm[1]) * h;

    // Shown by default when there's something to read; a double-tap overrides
    // that either way — so even an all-known bubble can be brought back.
    final hasFurigana = region.segments
        .any((s) => resolveFurigana(s, repo.entryFor(s.text)).reading != null);
    final shown = _override[region.id] ?? hasFurigana;

    if (!shown) {
      // Transparent target over the bubble so a double-tap reveals it.
      return Positioned(
        left: region.bboxNorm[0] * w,
        top: region.bboxNorm[1] * h,
        width: baseW,
        height: baseH,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTap: () => _setRegionShown(region.id, true),
        ),
      );
    }

    // Vertical (縦書き) when the bubble is taller than wide; horizontal
    // otherwise (e.g. wide caption/title text).
    final vertical = baseH >= baseW;
    // Scale the original font to the on-screen page so the overlay matches
    // the source size (no fit-to-box cap — the box grows to show everything).
    final scale =
        widget.meta.imageHeight > 0 ? h / widget.meta.imageHeight : 1.0;
    final fontSize =
        ((region.sourceFontSize ?? 16.0) * scale).clamp(9.0, 96.0).toDouble();
    // Bound the wrap along the reading axis (to a slightly padded bubble) so it
    // wraps like the original; the box then grows freely along the other axis
    // to show every character, and is centered on the bubble.
    final wrapExtent = (vertical ? baseH : baseW) * 1.1;
    final cx = (region.bboxNorm[0] + region.bboxNorm[2]) / 2 * w;
    final cy = (region.bboxNorm[1] + region.bboxNorm[3]) / 2 * h;
    // Center the box on the bubble, but keep it within the page (with a
    // margin) and never larger than the page.
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _BubbleBoxLayout(center: Offset(cx, cy), margin: 6),
        // Double-tap toggles this bubble; single taps fall through to the
        // words (mark-known / override).
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onDoubleTap: () => _setRegionShown(region.id, false),
          child: _RegionOverlay(
            region: region,
            repo: repo,
            vertical: vertical,
            fontSize: fontSize,
            wrapExtent: wrapExtent,
            onWordTap: (seg) => _openFocusPanel(context, repo, seg),
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

/// Lays out one bubble's segments as tappable furigana words. Words flow in
/// the bubble's reading direction and wrap within its box: right-to-left
/// columns for vertical (縦書き) text, left-to-right rows for horizontal.
class _RegionOverlay extends StatelessWidget {
  const _RegionOverlay({
    required this.region,
    required this.repo,
    required this.onWordTap,
    required this.vertical,
    required this.fontSize,
    required this.wrapExtent,
  });

  final FuriganaRegion region;
  final VocabRepository repo;
  final void Function(FuriganaSegment) onWordTap;
  final bool vertical;
  final double fontSize;

  /// Max size along the reading axis before wrapping (columns for vertical,
  /// rows for horizontal). The box grows freely on the other axis.
  final double wrapExtent;

  @override
  Widget build(BuildContext context) {
    // Visibility (including auto-hide when every word is known) is decided by
    // the caller; here we just render the bubble's words + readings.
    final displays = [
      for (final seg in region.segments)
        resolveFurigana(seg, repo.entryFor(seg.text)),
    ];

    final Widget content;
    if (vertical) {
      // Vertical text: stack each character, with its furigana beside the
      // kanji, flowing into right-to-left columns.
      final units = <Widget>[];
      for (var s = 0; s < region.segments.length; s++) {
        final seg = region.segments[s];
        for (final u in distributeRuby(displays[s].baseText, displays[s].reading)) {
          Widget w =
              _VerticalRuby(base: u.base, furigana: u.furigana, fontSize: fontSize);
          if (seg.needsFurigana) {
            w = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onWordTap(seg),
              child: w,
            );
          }
          units.add(w);
        }
      }
      content = Wrap(
        direction: Axis.vertical,
        textDirection: TextDirection.rtl, // columns run right-to-left
        alignment: WrapAlignment.start,
        runAlignment: WrapAlignment.center,
        // Columns run right-to-left, so "end" is the left edge — this keeps the
        // base characters left-aligned in a straight line while the furigana
        // sits to their right.
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 1,
        runSpacing: 4,
        children: units,
      );
    } else {
      content = Wrap(
        alignment: WrapAlignment.center,
        runAlignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 3,
        runSpacing: 1,
        children: [
          for (var i = 0; i < region.segments.length; i++)
            FuriganaWord(
              display: displays[i],
              fontSize: fontSize,
              onTap: region.segments[i].needsFurigana
                  ? () => onWordTap(region.segments[i])
                  : null,
            ),
        ],
      );
    }

    // A translucent panel behind the reading so the furigana + base text stay
    // legible over any artwork. The panel sizes to its content; the wrap is
    // bounded only along the reading axis so the box grows to show everything.
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.all(3),
      child: ConstrainedBox(
        constraints: vertical
            ? BoxConstraints(maxHeight: wrapExtent)
            : BoxConstraints(maxWidth: wrapExtent),
        child: content,
      ),
    );
  }
}

/// A single vertically-stacked character with its furigana to the right
/// (縦書き ruby). For a grouped kanji run, base chars stack and the reading
/// stacks beside them.
class _VerticalRuby extends StatelessWidget {
  const _VerticalRuby({
    required this.base,
    required this.furigana,
    required this.fontSize,
  });

  final String base;
  final String? furigana;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    Widget column(String s, TextStyle style) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in s.runes)
              Text(String.fromCharCode(r), style: style),
          ],
        );

    final baseCol = column(
      base,
      TextStyle(fontSize: fontSize, height: 1.0, color: Colors.white),
    );
    if (furigana == null) return baseCol;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        baseCol,
        column(
          furigana!,
          TextStyle(
            fontSize: fontSize * 0.5,
            height: 1.0,
            color: Colors.amberAccent,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Lays out a furigana box centered on its bubble, but constrained to fit
/// within the page (minus [margin]) and clamped so it never spills off the
/// edge — so an expanded box near a border stays on the page.
class _BubbleBoxLayout extends SingleChildLayoutDelegate {
  const _BubbleBoxLayout({required this.center, required this.margin});

  final Offset center;
  final double margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxW = constraints.maxWidth - 2 * margin;
    final maxH = constraints.maxHeight - 2 * margin;
    return BoxConstraints(
      maxWidth: maxW < 0 ? 0 : maxW,
      maxHeight: maxH < 0 ? 0 : maxH,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double axis(double desired, double extent, double child) {
      final maxPos = extent - child - margin;
      if (maxPos <= margin) return margin;
      return desired.clamp(margin, maxPos);
    }

    return Offset(
      axis(center.dx - childSize.width / 2, size.width, childSize.width),
      axis(center.dy - childSize.height / 2, size.height, childSize.height),
    );
  }

  @override
  bool shouldRelayout(_BubbleBoxLayout old) =>
      center != old.center || margin != old.margin;
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
              helperText: 'Type romaji — it becomes kana (e.g. tabe → たべ)',
            ),
            // Convert romaji to hiragana as you type, so a reading can be
            // entered without a system IME.
            onChanged: (value) {
              final converted = romajiToHiragana(value);
              if (converted != value) {
                _controller.value = TextEditingValue(
                  text: converted,
                  selection:
                      TextSelection.collapsed(offset: converted.length),
                );
              }
            },
            onSubmitted: (value) {
              // Update in memory + notify synchronously, then close; the disk
              // write persists in the background (best-effort in the repo).
              unawaited(
                  widget.repo.setReadingOverride(widget.segment.text, value));
              Navigator.pop(context);
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton(
                key: const ValueKey('vocab-mark-known'),
                onPressed: () {
                  unawaited(widget.repo.setKnown(widget.segment.text, !known));
                  Navigator.pop(context);
                },
                child: Text(known ? 'Mark as unknown' : 'I know this word'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () {
                  unawaited(widget.repo.setReadingOverride(
                      widget.segment.text, _controller.text));
                  Navigator.pop(context);
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
        metaUrl: ApiService.metaPath(pipeline, hash),
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
