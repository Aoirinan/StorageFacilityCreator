/// Lead source types for tracking where tenants come from
enum LeadSource {
  walkIn, // Walk-in customer
  referral, // Referred by existing tenant
  online, // Found online (website, social media, etc.)
  phone, // Phone inquiry
  email, // Email inquiry
  driveBy, // Drove by facility
  sign, // Saw facility sign
  other, // Other source

  // Common online sources
  google,
  facebook,
  instagram,
  yelp,
  storageForum, // Storage forum/community
  competitor, // Switched from competitor
}

extension LeadSourceExtension on LeadSource {
  String get displayName {
    switch (this) {
      case LeadSource.walkIn:
        return 'Walk-In';
      case LeadSource.referral:
        return 'Referral';
      case LeadSource.online:
        return 'Online';
      case LeadSource.phone:
        return 'Phone';
      case LeadSource.email:
        return 'Email';
      case LeadSource.driveBy:
        return 'Drive-By';
      case LeadSource.sign:
        return 'Sign';
      case LeadSource.other:
        return 'Other';
      case LeadSource.google:
        return 'Google';
      case LeadSource.facebook:
        return 'Facebook';
      case LeadSource.instagram:
        return 'Instagram';
      case LeadSource.yelp:
        return 'Yelp';
      case LeadSource.storageForum:
        return 'Storage Forum';
      case LeadSource.competitor:
        return 'Competitor';
    }
  }

  String get category {
    switch (this) {
      case LeadSource.walkIn:
      case LeadSource.driveBy:
      case LeadSource.sign:
        return 'Physical';
      case LeadSource.referral:
        return 'Referral';
      case LeadSource.online:
      case LeadSource.google:
      case LeadSource.facebook:
      case LeadSource.instagram:
      case LeadSource.yelp:
      case LeadSource.storageForum:
        return 'Online';
      case LeadSource.phone:
      case LeadSource.email:
        return 'Direct Contact';
      case LeadSource.competitor:
        return 'Competitor';
      case LeadSource.other:
        return 'Other';
    }
  }
}

/// Lead source statistics
class LeadSourceStats {
  final LeadSource source;
  final int count;
  final int convertedCount; // How many became tenants
  final double conversionRate; // Percentage converted

  const LeadSourceStats({
    required this.source,
    required this.count,
    required this.convertedCount,
    required this.conversionRate,
  });
}

