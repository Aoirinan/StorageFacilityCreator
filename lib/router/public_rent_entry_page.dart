import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:sfcapp/screens/public_rental_portal_screen.dart';
import 'package:sfcapp/services/public_website_status.dart';

/// `/f/{slug}/rent` and `/f/{slug}/available-units`: the Main Rent Link and
/// All Available Units Link that Edit Facility gives owners for their site,
/// emails and texts, and where its Preview Public Page button goes.
///
/// When the facility's website is live these open its unit list
/// (`/w/{slug}#unit-list`). When it is not, that page is "Website not found",
/// but online rentals do not need the website (the move-in callables check
/// only publicRentalsEnabled), so these show the rental portal instead.
///
/// The question is asked once, in [State.initState], so router rebuilds do
/// not ask again. Key it by slug so a different facility gets a fresh answer.
class PublicRentEntryPage extends StatefulWidget {
  const PublicRentEntryPage({
    super.key,
    required this.slug,
    this.availableOnly = false,
    this.websiteIsLive,
    this.openWebsite,
    this.buildPortal,
  });

  final String slug;

  /// `/available-units`: the portal lists only available and reserved units.
  final bool availableOnly;

  /// Test seams. Production asks [PublicWebsiteStatus.isLive], opens the
  /// website in this tab and shows [PublicRentalPortalScreen].
  final Future<bool> Function(String slug)? websiteIsLive;
  final Future<bool> Function(Uri target)? openWebsite;
  final WidgetBuilder? buildPortal;

  @override
  State<PublicRentEntryPage> createState() => _PublicRentEntryPageState();
}

class _PublicRentEntryPageState extends State<PublicRentEntryPage> {
  /// False while asking, and while the browser leaves for the website.
  bool _showPortal = false;
  bool _websiteLive = false;

  @override
  void initState() {
    super.initState();
    _route();
  }

  Future<void> _route() async {
    final ask = widget.websiteIsLive ?? PublicWebsiteStatus.isLive;
    bool live;
    try {
      live = await ask(widget.slug);
    } catch (_) {
      live = false;
    }
    if (!mounted) return;
    _websiteLive = live;
    if (live) {
      final open = widget.openWebsite ?? _openInThisTab;
      bool opened;
      try {
        opened = await open(PublicWebsiteStatus.websiteUnitsUrl(widget.slug));
      } catch (_) {
        opened = false;
      }
      // A browser that would not leave gets the portal rather than a
      // spinner that never ends.
      if (opened || !mounted) return;
    }
    setState(() => _showPortal = true);
  }

  static Future<bool> _openInThisTab(Uri target) => launchUrl(
        target,
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_self',
      );

  @override
  Widget build(BuildContext context) {
    if (!_showPortal) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final build = widget.buildPortal;
    if (build != null) return build(context);
    return PublicRentalPortalScreen(
      facilitySlug: widget.slug,
      availableOnly: widget.availableOnly,
      // Asked above; the portal need not ask again.
      websiteLive: _websiteLive,
    );
  }
}
