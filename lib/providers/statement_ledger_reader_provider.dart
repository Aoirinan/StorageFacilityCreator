import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/services/bulk_statement_service.dart';

/// The ledger reader behind Tenants > Select Multiple > Print statements.
/// A provider so a screen test can hand the list a fake and open the
/// dialog without Firestore; the app reads facilities/{fid}/ledgers.
final statementLedgerReaderProvider = Provider<StatementLedgerReader>(
    (ref) => FirestoreStatementLedgerReader());
