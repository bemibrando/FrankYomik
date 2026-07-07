import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../furigana/furigana_resolver.dart';
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
  Widget _positionedOverlay(BuildContext context, FuriganaRegion region,
      double w, double h, VocabRepository repo) {
    final baseW = (region.bboxNorm[2] - region.bboxNorm[0]) * w;
    final baseH = (region.bboxNorm[3] - region.bboxNorm[1]) * h;
    // Vertical (縦書き) when the bubble is taller than wide; horizontal
    // otherwise (e.g. wide caption/title text).
    final vertical = baseH >= baseW;
    // Give the overlay box 10% more room than the detected bubble so the
    // furigana + text has space and isn't clipped, keeping it centered.
    final rw = baseW * 1.1;
    final rh = baseH * 1.1;
    // Scale the original font to the on-screen page so the overlay matches
    // the source size and wraps like it.
    final scale =
        widget.meta.imageHeight > 0 ? h / widget.meta.imageHeight : 1.0;
    final rawFont = (region.sourceFontSize ?? 16.0) * scale;
    // Cap so a bubble's text can't overflow its box (which would clip tap
    // targets): horizontal rows are ~1.7x font tall, vertical columns ~1.5x
    // font wide.
    final cap = vertical ? rw / 1.5 : rh / 1.7;
    final fontSize = rawFont.clamp(9.0, cap < 9.0 ? 9.0 : cap).toDouble();
    return Positioned(
      left: region.bboxNorm[0] * w - baseW * 0.05,
      top: region.bboxNorm[1] * h - baseH * 0.05,
      width: rw,
      height: rh,
      child: _RegionOverlay(
        region: region,
        repo: repo,
        vertical: vertical,
        fontSize: fontSize,
        onWordTap: (seg) => _openFocusPanel(context, repo, seg),
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
  });

  final FuriganaRegion region;
  final VocabRepository repo;
  final void Function(FuriganaSegment) onWordTap;
  final bool vertical;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final displays = [
      for (final seg in region.segments)
        resolveFurigana(seg, repo.entryFor(seg.text)),
    ];
    // Once every furigana word in the bubble is known there is nothing left to
    // read, so hide the whole overlay and let the original bubble show through.
    if (!displays.any((d) => d.reading != null)) {
      return const SizedBox.shrink();
    }

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
    // legible over any artwork.
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.all(2),
      alignment: Alignment.center,
      child: ClipRect(child: content),
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
