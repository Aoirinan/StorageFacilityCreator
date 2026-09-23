import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Leaves the current page: back to the page underneath it (handing it
/// [result]), or to [fallback] when nothing is underneath (the page was
/// opened by a reload, a link or `context.go`).
///
/// Use this for in-page back arrows, for leaving after a save, and for
/// "cancel and leave" after a dialog has closed, with the page's own context
/// (a dialog's context is dead after an await). It pops whatever is on top
/// of the router, so only call it while the page is the one on top.
///
/// A bare `context.pop()` throws "There is nothing to pop" when the page was
/// opened with go or a link. A save that then reported the throw as its own
/// failure invited a retry that saved twice. Pushing or going back instead
/// lost the page underneath: the ledger's back pushed a second tenant page,
/// so the top-bar back returned to the ledger. Popping a second time from a
/// dialog's context hit the root navigator, removed the whole app shell and
/// left a blank screen.
void popOrGo<T extends Object?>(
  BuildContext context,
  String fallback, [
  T? result,
]) {
  if (context.canPop()) {
    context.pop<T>(result);
  } else {
    context.go(fallback);
  }
}
