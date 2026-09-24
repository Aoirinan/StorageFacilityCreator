import 'package:firebase_auth/firebase_auth.dart';

/// Makes sure the ID token Firestore sees says [user]'s email is verified
/// when Auth says it is.
///
/// The invite rules only let a verified email list the invites addressed to
/// it. Firestore reads that from the ID token, and a token minted before the
/// user clicked the verification link keeps saying "not verified" until it
/// refreshes, up to an hour later: a fresh signup could not find their invite
/// until then. A token that already says so costs no round trip.
Future<void> refreshStaleEmailVerifiedClaim(User user) async {
  if (!user.emailVerified) return;
  final claims = (await user.getIdTokenResult()).claims;
  if (claims?['email_verified'] == true) return;
  await user.getIdToken(true);
}
