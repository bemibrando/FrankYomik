import 'package:flutter/material.dart';
import '../furigana/furigana_resolver.dart';

/// Renders a single word segment: faint furigana reading above the base text.
/// Tapping a vocab word invokes [onTap].
class FuriganaWord extends StatelessWidget {
  const FuriganaWord({super.key, required this.display, this.onTap});

  final FuriganaDisplay display;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (display.reading != null)
          Opacity(
            opacity: 0.7,
            child: Text(
              display.reading!,
              style: const TextStyle(
                fontSize: 9,
                height: 1.0,
                color: Colors.redAccent,
              ),
            ),
          ),
        Text(
          display.baseText,
          style: const TextStyle(fontSize: 16, height: 1.0),
        ),
      ],
    );

    if (!display.isVocabWord) return content;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: content,
    );
  }
}
