/// Helpers for Kindle latest-page prioritization.
///
/// Keep this logic mirrored with the Chromium extension Kindle metadata: both
/// clients send a stable Kindle session group and a root page token so the
/// server can demote stale high-priority pages during rapid page flips.
class KindlePriorityMetadata {
  final String sourceSite;
  final String latestGroup;
  final String latestToken;
  final int latestSeq;

  const KindlePriorityMetadata({
    this.sourceSite = 'kindle',
    required this.latestGroup,
    required this.latestToken,
    required this.latestSeq,
  });
}

String? kindleSessionFromPageId(String pageId) {
  final match = RegExp(r'^kindle-([^-]+)-\d+').firstMatch(pageId);
  return match?.group(1);
}

int? kindleSequenceFromPageId(String pageId) {
  final match = RegExp(r'^kindle-[^-]+-(\d+)').firstMatch(pageId);
  return int.tryParse(match?.group(1) ?? '');
}

String kindleLatestTokenForPage(String pageId) {
  return pageId.replaceFirst(RegExp(r'-(L|R|left|right)$'), '').trim();
}

KindlePriorityMetadata? kindlePriorityMetadataForPage({
  required String pageId,
  String? title,
}) {
  final sessionId = kindleSessionFromPageId(pageId);
  final sequence = kindleSequenceFromPageId(pageId);
  if (sessionId == null || sessionId.isEmpty || sequence == null) return null;
  final safeTitle = _safeOpaque(title, fallback: 'kindle', maxLength: 80);
  return KindlePriorityMetadata(
    latestGroup: 'kindle:$safeTitle:$sessionId',
    latestToken: kindleLatestTokenForPage(pageId),
    latestSeq: sequence,
  );
}

String _safeOpaque(
  String? value, {
  required String fallback,
  required int maxLength,
}) {
  final trimmed = (value ?? '').trim();
  final text = trimmed.isEmpty ? fallback : trimmed;
  final withoutControls = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
  if (withoutControls.length <= maxLength) return withoutControls;
  return withoutControls.substring(0, maxLength);
}
