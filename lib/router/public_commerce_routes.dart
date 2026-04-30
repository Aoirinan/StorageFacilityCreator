import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/public_facility_map_screen.dart';
import '../screens/public_facility_page_screen.dart';
import '../screens/public_move_in_screen.dart';
import '../screens/public_rental_portal_screen.dart';
import 'app_route.dart';
import 'route_helpers.dart';

List<RouteBase> buildPublicCommerceRoutes() {
  return [
    GoRoute(
      path: AppRoute.publicRental,
      name: 'public-rental',
      builder: (context, state) {
        final facilityId = state.uri.queryParameters['facilityId'];
        return PublicRentalPortalScreen(facilityId: facilityId);
      },
    ),
    GoRoute(
      path: '${AppRoute.publicFacilityRentalBase}/:facilitySlug/rent',
      name: 'public-rental-by-slug',
      builder: (context, state) {
        final slug = state.pathParameters['facilitySlug'];
        if (slug == null || slug.isEmpty) {
          return NotFoundPage(state: state);
        }
        return _RedirectToWebsiteUnitsPage(slug: slug);
      },
    ),
    GoRoute(
      path: '${AppRoute.publicFacilityRentalBase}/:facilitySlug/available-units',
      name: 'public-available-units-by-slug',
      builder: (context, state) {
        final slug = state.pathParameters['facilitySlug'];
        if (slug == null || slug.isEmpty) {
          return NotFoundPage(state: state);
        }
        return _RedirectToWebsiteUnitsPage(slug: slug);
      },
    ),
    GoRoute(
      path: '${AppRoute.publicFacilityRentalBase}/:facilitySlug/:categorySlug',
      name: 'public-rental-category-by-slug',
      builder: (context, state) {
        final slug = state.pathParameters['facilitySlug'];
        final categorySlug = state.pathParameters['categorySlug'];
        if (slug == null ||
            slug.isEmpty ||
            categorySlug == null ||
            categorySlug.isEmpty) {
          return NotFoundPage(state: state);
        }
        return PublicRentalPortalScreen(
          facilitySlug: slug,
          initialCategorySlug: categorySlug,
        );
      },
    ),
    GoRoute(
      path: AppRoute.publicMoveIn,
      name: 'public-move-in',
      builder: (context, state) {
        final token = state.uri.queryParameters['token'];
        if (token == null || token.isEmpty) {
          return NotFoundPage(state: state);
        }
        return PublicMoveInScreen(token: token);
      },
    ),
    GoRoute(
      path: '${AppRoute.publicFacility}/:facilityId',
      name: 'public-facility',
      builder: (context, state) {
        final facilityId =
            state.pathParameters['facilityId'] ?? state.uri.queryParameters['facilityId'];
        if (facilityId == null || facilityId.isEmpty) {
          return NotFoundPage(state: state);
        }
        return PublicFacilityPageScreen(facilityId: facilityId);
      },
    ),
    GoRoute(
      path: '${AppRoute.publicMapBase}/:facilitySlug/map',
      name: 'public-facility-map',
      builder: (context, state) {
        final slug = state.pathParameters['facilitySlug'];
        if (slug == null || slug.isEmpty) {
          return NotFoundPage(state: state);
        }
        return PublicFacilityMapScreen(facilitySlug: slug);
      },
    ),
  ];
}

class _RedirectToWebsiteUnitsPage extends StatefulWidget {
  final String slug;

  const _RedirectToWebsiteUnitsPage({required this.slug});

  @override
  State<_RedirectToWebsiteUnitsPage> createState() =>
      _RedirectToWebsiteUnitsPageState();
}

class _RedirectToWebsiteUnitsPageState extends State<_RedirectToWebsiteUnitsPage> {
  bool _launched = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_launched) return;
    _launched = true;
    final target = Uri.parse(
      '${Uri.base.origin}/w/${widget.slug}#unit-list',
    );
    Future<void>.microtask(() async {
      await launchUrl(
        target,
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_self',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
