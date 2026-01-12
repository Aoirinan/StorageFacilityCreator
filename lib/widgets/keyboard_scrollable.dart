import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wrapper widget that enables keyboard scrolling (arrow keys, page up/down) for any scrollable content
class KeyboardScrollable extends StatelessWidget {
  final Widget child;
  final ScrollController? controller;

  const KeyboardScrollable({
    super.key,
    required this.child,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          final scrollController = controller ?? PrimaryScrollController.of(context);
          if (scrollController == null || !scrollController.hasClients) {
            return KeyEventResult.ignored;
          }

          const scrollAmount = 100.0; // pixels to scroll per arrow key press
          const pageScrollAmount = 500.0; // pixels to scroll per page up/down

          switch (event.logicalKey) {
            case LogicalKeyboardKey.arrowUp:
              scrollController.animateTo(
                (scrollController.offset - scrollAmount).clamp(0.0, scrollController.position.maxScrollExtent),
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeOut,
              );
              return KeyEventResult.handled;

            case LogicalKeyboardKey.arrowDown:
              scrollController.animateTo(
                (scrollController.offset + scrollAmount).clamp(0.0, scrollController.position.maxScrollExtent),
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeOut,
              );
              return KeyEventResult.handled;

            case LogicalKeyboardKey.pageUp:
              scrollController.animateTo(
                (scrollController.offset - pageScrollAmount).clamp(0.0, scrollController.position.maxScrollExtent),
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
              );
              return KeyEventResult.handled;

            case LogicalKeyboardKey.pageDown:
              scrollController.animateTo(
                (scrollController.offset + pageScrollAmount).clamp(0.0, scrollController.position.maxScrollExtent),
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
              );
              return KeyEventResult.handled;

            default:
              return KeyEventResult.ignored;
          }
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

