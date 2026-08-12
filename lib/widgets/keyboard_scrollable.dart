import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wrapper widget that enables keyboard scrolling (arrow keys, page up/down) for any scrollable content
///
/// Deliberately does *not* rely on `PrimaryScrollController` inheritance:
/// every route go_router pushes is itself a `ModalRoute`, and `ModalRoute`
/// wraps its content in its own per-route `PrimaryScrollController` that
/// only auto-inherits into descendant ScrollViews on mobile platforms
/// (`TargetPlatformVariant.mobile`) — that route-level controller sits
/// between this widget and the actual list on *every* screen, so any
/// ScrollView found via `PrimaryScrollController.of`/`primary: true` here
/// would always be a dead end on desktop/web. Instead this listens for
/// `ScrollMetricsNotification`s, which every Scrollable dispatches on
/// layout (not just when actively scrolled), to find the nearest actual
/// Scrollable in the subtree directly — a mechanism unaffected by
/// PrimaryScrollController scoping altogether.
class KeyboardScrollable extends StatefulWidget {
  final Widget child;
  final ScrollController? controller;

  const KeyboardScrollable({
    super.key,
    required this.child,
    this.controller,
  });

  @override
  State<KeyboardScrollable> createState() => _KeyboardScrollableState();
}

class _KeyboardScrollableState extends State<KeyboardScrollable> {
  // Every live KeyboardScrollable's focus node, so instances can tell "the
  // current focus holder is another KeyboardScrollable whose own content
  // has since scrolled off-screen" (safe to steal back) apart from "the
  // user actually clicked into a text field" (never steal).
  static final Set<FocusNode> _autoFocusNodes = <FocusNode>{};

  final FocusNode _focusNode = FocusNode(debugLabel: 'KeyboardScrollable');
  BuildContext? _scrollableContext;

  @override
  void initState() {
    super.initState();
    _autoFocusNodes.add(_focusNode);
  }

  @override
  void dispose() {
    _autoFocusNodes.remove(_focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  bool _handleMetrics(ScrollMetricsNotification notification) {
    // Notifications bubble through *every* ancestor NotificationListener,
    // not just the nearest one — including from horizontal Scrollables
    // (e.g. the PageView backing a TabBarView) nested anywhere below.
    // Arrow/Page Up/Down are a vertical-scroll gesture, so a horizontal
    // Scrollable's metrics would otherwise overwrite the real target and
    // make keyboard scrolling nudge the tab view sideways instead.
    if (notification.metrics.axis != Axis.vertical) return false;
    _scrollableContext = notification.context;
    if (!_focusNode.hasFocus) {
      final current = FocusManager.instance.primaryFocus;
      // Only a live text field should block us — the widget the user is
      // actually mid-interaction with. Buttons, tabs, and nav items are
      // momentarily focused after a click/tap too (that's how the user got
      // here), but arrow keys don't mean anything to them, so treat that
      // as safe to redirect. Without this, clicking a tab to navigate to a
      // page would permanently block keyboard scrolling on it, since that
      // click's residual focus reads as "something real is focused" and a
      // page reached only by clicking (i.e. every normal navigation) would
      // never get a chance to claim it.
      // The FocusNode context for a focused TextField is the internal
      // `Focus` wrapper *inside* EditableText, not EditableText itself —
      // `context.widget is EditableText` never matches a real text field.
      // Walk up for an EditableText ancestor instead.
      final currentIsTextInput = current?.context
              ?.findAncestorWidgetOfExactType<EditableText>() !=
          null;
      final nothingRealFocused = current == null ||
          current == FocusManager.instance.rootScope ||
          _autoFocusNodes.contains(current) ||
          !currentIsTextInput;
      if (nothingRealFocused) {
        _focusNode.requestFocus();
      }
    }
    return false; // don't consume — let it keep bubbling
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final scrollContext = _scrollableContext;
    if (scrollContext == null) return KeyEventResult.ignored;
    final scrollable = Scrollable.maybeOf(scrollContext);
    if (scrollable == null) return KeyEventResult.ignored;

    const scrollAmount = 100.0; // pixels to scroll per arrow key press
    const pageScrollAmount = 500.0; // pixels to scroll per page up/down

    double? delta;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        delta = -scrollAmount;
      case LogicalKeyboardKey.arrowDown:
        delta = scrollAmount;
      case LogicalKeyboardKey.pageUp:
        delta = -pageScrollAmount;
      case LogicalKeyboardKey.pageDown:
        delta = pageScrollAmount;
      default:
        return KeyEventResult.ignored;
    }

    final position = scrollable.position;
    final target =
        (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) {
      position.animateTo(
        target,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: _handleMetrics,
        child: widget.child,
      ),
    );
  }
}
