/** Base URL for OAuth redirects (set PUBLIC_APP_URL in functions env if not using default). */
export function getPublicAppUrl(): string {
  const v = process.env.PUBLIC_APP_URL?.trim();
  const base = v && v.length > 0 ? v : 'https://app.storagefacilitycreator.com';
  return base.replace(/\/$/, '');
}
