/// Public App Check / reCAPTCHA v3 **site** key (client-side; restrict domains in
/// Google reCAPTCHA Admin + Firebase App Check). Not a secret.
///
/// Listed in `.gitleaks.toml` allowlist so secret scanners skip this file — the
/// value is still a deploy-time identifier, not a server credential.
library;

const String kAppCheckRecaptchaSiteKey =
    '6LeQ_0osAAAAAHiMJCujnzWG8ldPZhrKbgADZ2wH';
