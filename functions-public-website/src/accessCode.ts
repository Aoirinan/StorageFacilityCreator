import { randomInt } from 'node:crypto';

/**
 * Short numeric access code for gate access / tokens.
 *
 * Uses a cryptographic source, not `Math.random`. These codes open a physical
 * gate, and V8's `Math.random` is a seeded PRNG whose internal state can be
 * recovered from a handful of observed outputs drawn from the same warm
 * instance — so anyone who could see a couple of codes could predict others.
 */
export function generateAccessCode(): string {
  return String(randomInt(100000, 1000000));
}
