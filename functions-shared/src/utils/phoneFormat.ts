/**
 * Normalize a US phone number to E.164 (`+1XXXXXXXXXX`).
 * Returns `null` if the input cannot be coerced to a recognizable format.
 *
 * - 10 digits → assume US, prefix `+1`
 * - 11 digits starting with `1` → prefix `+`
 * - Already starts with `+` → returned untouched
 */
export function formatPhoneNumber(phone: string): string | null {
  const digits = phone.replace(/\D/g, '');

  if (digits.length === 11 && digits.startsWith('1')) {
    return `+${digits}`;
  }

  if (digits.length === 10) {
    return `+1${digits}`;
  }

  if (phone.startsWith('+')) {
    return phone;
  }

  return null;
}
