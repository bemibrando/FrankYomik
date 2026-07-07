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
          Text(
            display.reading!,
            style: const TextStyle(
              fontSize: 13,
              height: 1.05,
              color: Colors.amberAccent,
              fontWeight: FontWeight.w700,
            ),
          ),
        Text(
          display.baseText,
          style: const TextStyle(
            fontSize: 20,
            height: 1.05,
            color: Colors.white,
          ),
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
