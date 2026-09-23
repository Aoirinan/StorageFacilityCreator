import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/screens/facility_edit_screen.dart';
import 'package:sfcapp/services/facility_service.dart';

/// `/facilities/edit?facilityId=` when no [FacilityModel] came in `extra`
/// (a hard reload, a deep link, or the ledger's Edit button).
///
/// The facility is resolved once, in [State.initState]. The route builder used
/// to create a `FutureBuilder(future: FacilityService.getFacility(id))` itself,
/// so every router rebuild (the auth refresh, locale and theme loading) started
/// a new read and put the spinner back.
///
/// Key it by facility id so a rebuild keeps this state and a different
/// facility gets a fresh lookup.
class FacilityEditRoute extends ConsumerStatefulWidget {
  const FacilityEditRoute({
    super.key,
    required this.facilityId,
    required this.notFound,
    this.currentUid,
    this.loadFacility,
    this.buildEditor,
  });

  final String facilityId;

  /// Shown when the facility does not exist or the user may not read it.
  final Widget notFound;

  /// Test seams. Production reads the Firebase user, loads through
  /// [FacilityService.getFacility] and shows [FacilityEditScreen].
  final String? Function()? currentUid;
  final Future<FacilityModel?> Function(String facilityId)? loadFacility;
  final Widget Function(FacilityModel facility)? buildEditor;

  @override
  ConsumerState<FacilityEditRoute> createState() => _FacilityEditRouteState();
}

class _FacilityEditRouteState extends ConsumerState<FacilityEditRoute> {
  FacilityModel? _alreadyLoaded;
  Future<FacilityModel?>? _lookup;

  @override
  void initState() {
    super.initState();
    _alreadyLoaded = _fromLoadedFacilityList();
    if (_alreadyLoaded == null) {
      final load = widget.loadFacility ?? FacilityService.getFacility;
      _lookup = load(widget.facilityId);
    }
  }

  /// The facility from the user's facility list, if a screen already loaded
  /// it. That list only holds facilities the user owns or has a role on, the
  /// same access rule [FacilityService.getFacility] applies.
  ///
  /// Read once, never watched: the editor copies the facility into its text
  /// fields in its own initState, so swapping in a newer copy later would
  /// throw away whatever the user had typed.
  FacilityModel? _fromLoadedFacilityList() {
    final uid = (widget.currentUid ?? () => FirebaseAuth.instance.currentUser?.uid)();
    if (uid == null || uid.isEmpty) return null;
    final provider = userFacilitiesProvider(uid);
    // Only reuse a list something else already holds; reading it here would
    // open a new Firestore listener just to pick one facility out of it.
    if (!ref.exists(provider)) return null;
    final facilities = ref.read(provider).value;
    if (facilities == null) return null;
    for (final facility in facilities) {
      if (facility.id == widget.facilityId) return facility;
    }
    return null;
  }

  Widget _editor(FacilityModel facility) =>
      widget.buildEditor?.call(facility) ?? FacilityEditScreen(facility: facility);

  @override
  Widget build(BuildContext context) {
    final alreadyLoaded = _alreadyLoaded;
    if (alreadyLoaded != null) return _editor(alreadyLoaded);

    return FutureBuilder<FacilityModel?>(
      future: _lookup,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final facility = snapshot.data;
        if (snapshot.hasError || facility == null) {
          return widget.notFound;
        }
        return _editor(facility);
      },
    );
  }
}
