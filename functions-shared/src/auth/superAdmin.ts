/**
 * Super admin email list (case-insensitive checks via helper).
 * Can be overridden via SUPER_ADMIN_EMAILS env var (comma-separated).
 * Must match lib/services/superadmin_service.dart, firestore.rules, and storage.rules
 */
export const SUPER_ADMIN_EMAILS_HARDCODED = [
  'russell_forsyth_1992@outlook.com',
  'russellforsyth09091992@gmail.com',
  'kennethgriggs03@gmail.com',
];

export function getSuperAdminEmails(): string[] {
  const envValue = process.env.SUPER_ADMIN_EMAILS;
  return envValue && envValue.trim()
    ? envValue.split(',').map((e: string) => e.trim()).filter((e: string) => e.length > 0)
    : SUPER_ADMIN_EMAILS_HARDCODED;
}

/** Check if a user is a super admin */
export function isSuperAdmin(userEmail: string | undefined): boolean {
  if (!userEmail) return false;
  const lowerEmail = userEmail.toLowerCase();
  const adminEmails = getSuperAdminEmails();
  return adminEmails.some((adminEmail: string) => adminEmail.toLowerCase() === lowerEmail);
}
