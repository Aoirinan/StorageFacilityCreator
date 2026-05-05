/** Short numeric access code for gate access / tokens */
export function generateAccessCode(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}
