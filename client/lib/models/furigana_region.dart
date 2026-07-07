import 'dart:convert';

/// One word-segment of a bubble's text, as produced by the furigana pipeline.
class FuriganaSegment {
  final String text;
  final String? furigana;
  final bool needsFurigana;

  const FuriganaSegment({
    required this.text,
    this.furigana,
    required this.needsFurigana,
  });

  static FuriganaSegment? fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    if (text is! String || text.isEmpty) return null;
    final fura = json['furigana'];
    return FuriganaSegment(
      text: text,
      furigana: fura is String && fura.isNotEmpty ? fura : null,
      needsFurigana: json['needs_furigana'] == true,
    );
  }
}

/// One detected bubble/region with its normalized box and segmented text.
class FuriganaRegion {
  final String id;
  final List<double> bboxNorm; // [x1, y1, x2, y2], each 0..1
  final List<FuriganaSegment> segments;
  final double? sourceFontSize; // original text height in px, if known

  const FuriganaRegion({
    required this.id,
    required this.bboxNorm,
    required this.segments,
    this.sourceFontSize,
  });

  static FuriganaRegion? fromJson(Map<String, dynamic> json) {
    final transformed = json['transformed'];
    if (transformed is! Map || transformed['kind'] != 'furigana_segments') {
      return null;
    }
    final rawBox = json['bbox_norm'];
    if (rawBox is! List || rawBox.length != 4) return null;
    final box = <double>[];
    for (final v in rawBox) {
      if (v is num) {
        box.add(v.toDouble());
      } else {
        return null;
      }
    }
    final rawSegs = transformed['value'];
    if (rawSegs is! List) return null;
    final segs = <FuriganaSegment>[];
    for (final s in rawSegs) {
      if (s is Map) {
        final seg = FuriganaSegment.fromJson(Map<String, dynamic>.from(s));
        if (seg != null) segs.add(seg);
      }
    }
    if (segs.isEmpty) return null;
    final rawFont = json['source_font_size'];
    return FuriganaRegion(
      id: json['id']?.toString() ?? '',
      bboxNorm: box,
      segments: segs,
      sourceFontSize: rawFont is num ? rawFont.toDouble() : null,
    );
  }
}

/// A full page of furigana metadata.
class FuriganaPageMeta {
  final int imageWidth;
  final int imageHeight;
  final List<FuriganaRegion> regions;

  const FuriganaPageMeta({
    required this.imageWidth,
    required this.imageHeight,
    required this.regions,
  });

  static FuriganaPageMeta parse(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map) {
      return const FuriganaPageMeta(imageWidth: 0, imageHeight: 0, regions: []);
    }
    // The cache meta endpoint wraps the page under "metadata"
    // ({"content_hash":..., "metadata":{"image":..., "regions":[...]}}).
    // Accept either that envelope or a bare {"image":..., "regions":[...]}.
    final Map root =
        decoded['metadata'] is Map ? decoded['metadata'] as Map : decoded;
    final image = root['image'];
    final width = (image is Map && image['width'] is num)
        ? (image['width'] as num).toInt()
        : 0;
    final height = (image is Map && image['height'] is num)
        ? (image['height'] as num).toInt()
        : 0;
    final regions = <FuriganaRegion>[];
    final rawRegions = root['regions'];
    if (rawRegions is List) {
      for (final r in rawRegions) {
        if (r is Map) {
          final region = FuriganaRegion.fromJson(Map<String, dynamic>.from(r));
          if (region != null) regions.add(region);
        }
      }
    }
    return FuriganaPageMeta(
      imageWidth: width,
      imageHeight: height,
      regions: regions,
    );
  }
}
