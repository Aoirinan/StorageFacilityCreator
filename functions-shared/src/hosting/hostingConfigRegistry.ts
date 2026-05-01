export interface HostingConfig {
  getProjectId: () => string;
  getSiteId: () => string;
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
