import 'dart:async';
import 'dart:typed_data';

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
class FuriganaView extends ConsumerWidget {
  const FuriganaView({super.key, required this.meta, required this.imageBytes});

  final FuriganaPageMeta meta;
  final Uint8List imageBytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuild when vocab changes.
    ref.watch(vocabRepositoryProvider);
    final repo = ref.read(vocabRepositoryProvider);

    final aspect = (meta.imageWidth > 0 && meta.imageHeight > 0)
        ? meta.imageWidth / meta.imageHeight
        : 1.0;

    return Scaffold(
      appBar: AppBar(title: const Text('Furigana')),
      backgroundColor: Colors.black,
      body: Center(
        child: InteractiveViewer(
          maxScale: 6,
          child: AspectRatio(
            aspectRatio: aspect,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;
                return Stack(
                  children: [
                    Positioned.fill(
                      child: Image.memory(imageBytes, fit: BoxFit.fill),
                    ),
                    for (final region in meta.regions)
                      Positioned(
                        left: region.bboxNorm[0] * w,
                        top: region.bboxNorm[1] * h,
                        width:
                            (region.bboxNorm[2] - region.bboxNorm[0]) * w,
                        height:
                            (region.bboxNorm[3] - region.bboxNorm[1]) * h,
                        child: _RegionOverlay(
                          region: region,
                          repo: repo,
                          onWordTap: (seg) =>
                              _openFocusPanel(context, repo, seg),
                        ),
                      ),
                  ],
                );
              },
            ),
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

/// Lays out one bubble's segments as tappable furigana words.
class _RegionOverlay extends StatelessWidget {
  const _RegionOverlay({
    required this.region,
    required this.repo,
    required this.onWordTap,
  });

  final FuriganaRegion region;
  final VocabRepository repo;
  final void Function(FuriganaSegment) onWordTap;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final seg in region.segments)
            FuriganaWord(
              display: resolveFurigana(seg, repo.entryFor(seg.text)),
              onTap: seg.needsFurigana ? () => onWordTap(seg) : null,
            ),
        ],
      ),
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
