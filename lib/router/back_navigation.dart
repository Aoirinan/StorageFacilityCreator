import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Leaves the current page: back to the page underneath it, or to [fallback]
/// when nothing is underneath (the page was opened by a reload or a link).
///
/// Use this for in-page back arrows and for "cancel and leave" after a dialog
/// has closed, always with the page's own context. Pushing or going instead
/// lost the page underneath: the ledger's back pushed a second tenant page,
/// so the top-bar back returned to the ledger. Popping a second time from a
/// dialog's context hit the root navigator, removed the whole app shell and
/// left a blank screen.
void popOrGo(BuildContext context, String fallback) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(fallback);
  }
}
