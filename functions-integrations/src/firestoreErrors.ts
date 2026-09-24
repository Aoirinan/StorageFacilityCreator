/** True for Firestore's ALREADY_EXISTS (a `create()` on a document that exists). */
export function isAlreadyExistsError(error: unknown): boolean {
  const e = error as { code?: unknown; message?: unknown } | null;
  if (!e) return false;
  if (e.code === 6 || e.code === 'already-exists' || e.code === 'ALREADY_EXISTS') return true;
  return typeof e.message === 'string' && e.message.includes('ALREADY_EXISTS');
}
