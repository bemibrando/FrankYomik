/// Whether the server's burned/rendered image should be swapped into the
/// reader WebView for a given pipeline.
///
/// Furigana pages are read in the interactive viewer instead, so we do not
/// overwrite the original page image in Kindle.
bool shouldApplyBurnedOverlay(String? pipeline) {
  return pipeline != 'manga_furigana';
}
