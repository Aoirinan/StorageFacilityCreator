import 'package:sfcapp/utils/error_message_helper.dart';

/// What a bulk action over several items did, item by item.
class BulkActionResult {
  const BulkActionResult({required this.done, required this.failed});

  /// The ids it was done to, in order.
  final List<String> done;

  /// The ids it failed on, with why.
  final Map<String, Object> failed;

  int get attempted => done.length + failed.length;
}

/// Runs [action] on each of [ids] in turn, carrying on past a failure, and
/// says which were done.
///
/// The Units list's bulk Archive and Delete stopped at the first failure
/// and said only "Error archiving units": the units already done stayed
/// archived or deleted, still selected, and nothing said how many.
Future<BulkActionResult> runBulkAction(
  List<String> ids,
  Future<void> Function(String id) action,
) async {
  final done = <String>[];
  final failed = <String, Object>{};
  for (final id in ids) {
    try {
      await action(id);
      done.add(id);
    } catch (e) {
      failed[id] = e;
    }
  }
  return BulkActionResult(done: done, failed: failed);
}

/// "Archived 3 of 5 units. 2 were not: " and why, or [allDone] when every
/// one was done.
String bulkActionMessage(
  BulkActionResult result, {
  required String verb,
  required String noun,
  required String allDone,
}) {
  if (result.failed.isEmpty) return allDone;
  final why =
      ErrorMessageHelper.getUserFriendlyMessage(result.failed.values.first);
  final notDone = result.failed.length;
  return '$verb ${result.done.length} of ${result.attempted} $noun. '
      '$notDone ${notDone == 1 ? 'was' : 'were'} not: $why';
}
