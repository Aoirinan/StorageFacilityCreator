import 'package:flutter/material.dart';

import 'package:sfcapp/models/stays/stays_callable_models.dart';

/// What to tell the owner when a Stays call fails. The server's messages are
/// written for her; anything without one gets a plain fallback.
String staysErrorMessage(Object error) {
  if (error is StaysCallableException) {
    final message = error.message?.trim();
    switch (error.reason) {
      case StaysErrorReason.staysPaused:
        return 'Stays is paused for maintenance. Nothing was changed; try again later.';
      case StaysErrorReason.moduleNotAvailable:
        return 'Stays is not available for this facility yet.';
      case StaysErrorReason.rateLimited:
        return message?.isNotEmpty == true ? message! : 'Too many tries. Wait a minute and try again.';
      case StaysErrorReason.unknown:
        return 'Could not reach Stays. Check your connection and try again.';
      default:
        if (message != null && message.isNotEmpty) return message;
        return 'That did not work (${error.reason.wire}). Try again.';
    }
  }
  return 'Something went wrong. Try again.';
}

void showStaysSnack(BuildContext context, String text, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: error ? scheme.error : null,
    ));
}

/// A note that edits are shown to the whole team (viewers read stay docs).
const String staysTeamVisibleNote = 'Visible to everyone on your team, viewers included.';
