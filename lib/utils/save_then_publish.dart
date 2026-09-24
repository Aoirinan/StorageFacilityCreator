/// The settings were saved, but publishing the public map after them failed.
///
/// The website and online-rental settings screens save the settings and then
/// publish the map. A failed publish used to read "Failed to save settings",
/// although the settings were already saved: the owner would re-enter and
/// re-save them when only the publish needed retrying.
class PublishAfterSaveException implements Exception {
  PublishAfterSaveException(this.cause);

  final Object cause;

  String get message => 'Settings saved, but publishing the map failed: $cause';

  @override
  String toString() => message;
}

/// Runs [save], then [publish]. A failure in [publish] is rethrown as a
/// [PublishAfterSaveException]; a failure in [save] is rethrown as it is,
/// and nothing is published.
Future<void> saveThenPublish({
  required Future<void> Function() save,
  required Future<void> Function() publish,
}) async {
  await save();
  try {
    await publish();
  } catch (e) {
    throw PublishAfterSaveException(e);
  }
}

/// The error line for a failed [saveThenPublish]: "[saveFailed]: ..." only
/// when the save itself failed.
String saveThenPublishErrorText(Object error, {required String saveFailed}) =>
    error is PublishAfterSaveException ? error.message : '$saveFailed: $error';
