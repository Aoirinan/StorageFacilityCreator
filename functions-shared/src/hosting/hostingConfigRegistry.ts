export interface HostingConfig {
  getProjectId: () => string;
  /** The operator app's Hosting site (serves the Flutter SPA). */
  getSiteId: () => string;
  /**
   * The Hosting site that serves facility websites on their own domains.
   *
   * Deliberately a different site from the operator app: Firebase Hosting
   * serves an exact static-file match before it evaluates rewrites, so on the
   * operator site "/" always resolves to the SPA's index.html and the
   * host-routing rewrite can never fire. Facility domains must be attached
   * here, not to the operator site.
   *
   * Optional so existing registrations keep working; callers fall back to the
   * operator site, which preserves old behaviour rather than silently
   * registering a domain against a site that may not exist.
   */
  getFacilitySiteId?: () => string;
}

let hostingConfig: HostingConfig | null = null;

/** Call once from the default functions entrypoint (with defineString().value() accessors). */
export function registerHostingConfigProvider(config: HostingConfig): void {
  hostingConfig = config;
}

export function requireHostingConfig(): HostingConfig {
  if (!hostingConfig) {
    throw new Error(
      'Hosting API not configured: call registerHostingConfigProvider({ getProjectId, getSiteId }) from your functions entrypoint before using shared Firebase Hosting custom domain helpers.',
    );
  }
  return hostingConfig;
}

/**
 * Site that facility custom domains attach to.
 *
 * Falls back to the operator site when unconfigured: registering a domain
 * against a site id that does not exist would fail confusingly, and the old
 * behaviour is at least the one the deployment already had.
 */
export function facilitySiteId(): string {
  const config = requireHostingConfig();
  const configured = config.getFacilitySiteId?.().trim();
  return configured || config.getSiteId().trim();
}
