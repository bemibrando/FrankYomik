import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/furigana_region.dart';
import '../providers/connection_provider.dart' show apiServiceProvider;
import '../providers/settings_provider.dart';
import 'furigana_view_screen.dart';

const _imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};

/// Filters [names] to image files and orders them "naturally" so that, e.g.,
/// `page0002` sorts before `page0010`. Pure so it can be unit-tested.
List<String> sortedImageNames(Iterable<String> names) {
  final images = names.where((name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExtensions.contains(name.substring(dot).toLowerCase());
  }).toList();
  images.sort(_naturalCompare);
  return images;
}

final _chunk = RegExp(r'\d+|\D+');

int _naturalCompare(String a, String b) {
  final ax = _chunk.allMatches(a).map((m) => m.group(0)!).toList();
  final bx = _chunk.allMatches(b).map((m) => m.group(0)!).toList();
  for (var i = 0; i < ax.length && i < bx.length; i++) {
    final na = int.tryParse(ax[i]);
    final nb = int.tryParse(bx[i]);
    final c = (na != null && nb != null)
        ? na.compareTo(nb)
        : ax[i].toLowerCase().compareTo(bx[i].toLowerCase());
    if (c != 0) return c;
  }
  return ax.length.compareTo(bx.length);
}

/// Desktop-only entry point for reading a local folder of manga pages with
/// interactive furigana. Reads the folder directly via dart:io (no plugin),
/// so it works on Windows/Linux/macOS desktop builds.
class LocalFolderScreen extends ConsumerStatefulWidget {
  const LocalFolderScreen({super.key});

  @override
  ConsumerState<LocalFolderScreen> createState() => _LocalFolderScreenState();
}

class _LocalFolderScreenState extends ConsumerState<LocalFolderScreen> {
  // Pre-fill from FRANK_FOLDER when set (e.g. the Docker mount /data/adult);
  // empty on a plain desktop build so the user types their own path.
  final _pathController =
      TextEditingController(text: Platform.environment['FRANK_FOLDER'] ?? '');
  List<File> _pages = [];
  String? _error;
  String _folderName = '';

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final path = _pathController.text.trim();
    setState(() {
      _error = null;
      _pages = [];
    });
    if (path.isEmpty) {
      setState(() => _error = 'Enter a folder path.');
      return;
    }
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        setState(() => _error = 'Folder not found: $path');
        return;
      }
      final names = dir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .toList();
      final ordered = sortedImageNames(names);
      if (ordered.isEmpty) {
        setState(() => _error = 'No images found in $path');
        return;
      }
      setState(() {
        _pages = ordered.map((n) => File(p.join(path, n))).toList();
        _folderName = p.basename(path.replaceAll(RegExp(r'[\\/]+$'), ''));
      });
    } catch (e) {
      setState(() => _error = 'Could not read folder: $e');
    }
  }

  void _openPage(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocalFuriganaLoader(
          file: _pages[index],
          title: _folderName,
          pageNumber: '${index + 1}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Local folder')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pathController,
                    decoration: const InputDecoration(
                      labelText: 'Folder path',
                      hintText: r'e.g. C:\...\FrankYomik\docs\adult',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.folder_open),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _load, child: const Text('Load')),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.redAccent)),
            ),
          Expanded(
            child: _pages.isEmpty
                ? const Center(
                    child: Text('Load a folder to list its pages.'),
                  )
                : ListView.builder(
                    itemCount: _pages.length,
                    itemBuilder: (context, i) {
                      final name = p.basename(_pages[i].path);
                      return ListTile(
                        leading: CircleAvatar(child: Text('${i + 1}')),
                        title: Text(name),
                        trailing: const Icon(Icons.menu_book),
                        onTap: () => _openPage(i),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Submits a local image to the furigana pipeline, waits for the result, then
/// shows it in [FuriganaView]. Network-bound (mirrors [FuriganaPageLoader]).
class LocalFuriganaLoader extends ConsumerStatefulWidget {
  const LocalFuriganaLoader({
    super.key,
    required this.file,
    required this.title,
    required this.pageNumber,
  });

  final File file;
  final String title;
  final String pageNumber;

  @override
  ConsumerState<LocalFuriganaLoader> createState() =>
      _LocalFuriganaLoaderState();
}

class _LocalFuriganaLoaderState extends ConsumerState<LocalFuriganaLoader> {
  Uint8List? _bytes;
  FuriganaPageMeta? _meta;
  String? _error;
  String _status = 'Reading image…';

  @override
  void initState() {
    super.initState();
    _process();
  }

  Future<void> _process() async {
    setState(() {
      _error = null;
      _status = 'Reading image…';
    });
    try {
      final bytes = await widget.file.readAsBytes();
      _bytes = bytes;
      final settings = ref.read(settingsProvider);
      final api = ref.read(apiServiceProvider);

      setState(() => _status = 'Submitting…');
      final resp = await api.submitJob(
        settings: settings,
        imageBytes: bytes,
        pipeline: 'manga_furigana',
        title: widget.title.isEmpty ? 'local' : widget.title,
        pageNumber: widget.pageNumber,
        priority: 'high',
      );

      final jobId = resp['job_id'] as String;
      var status = resp['status'] as String? ?? 'queued';
      var metaUrl = resp['meta_url'] as String?;

      // Poll until the worker finishes (furigana OCR can take a few seconds).
      const maxTries = 60; // ~90s at 1.5s intervals
      var tries = 0;
      while (status != 'completed' && tries < maxTries) {
        await Future.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
        setState(() => _status = 'Processing furigana… (${tries + 1})');
        final st = await api.getJobStatus(settings: settings, jobId: jobId);
        status = st['status'] as String? ?? status;
        metaUrl = (st['meta_url'] as String?) ?? metaUrl;
        if (status == 'failed') {
          throw Exception(st['error'] as String? ?? 'Job failed');
        }
        tries++;
      }
      if (status != 'completed' || metaUrl == null) {
        throw Exception('Timed out waiting for furigana result.');
      }

      final meta = await api.fetchMeta(settings: settings, metaUrl: metaUrl);
      if (mounted) setState(() => _meta = meta);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Furigana')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load furigana: $_error',
                    textAlign: TextAlign.center),
              ),
              ElevatedButton(
                onPressed: _process,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final meta = _meta;
    final bytes = _bytes;
    if (meta == null || bytes == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Furigana')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_status),
            ],
          ),
        ),
      );
    }
    return FuriganaView(meta: meta, imageBytes: bytes);
  }
}
