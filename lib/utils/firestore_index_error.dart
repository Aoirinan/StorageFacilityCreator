/// Detects Firestore [failed-precondition] errors for indexes still building.
bool isFirestoreIndexBuildingError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('failed-precondition') &&
      (message.contains('index') || message.contains('not ready yet'));
}
