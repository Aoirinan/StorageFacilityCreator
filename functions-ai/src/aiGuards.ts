import * as crypto from 'crypto';

export const MAX_INPUT_CHARS = 2000;
export const MAX_OUTPUT_TOKENS = 380;
export const MAX_REQUESTS_PER_USER_PER_MINUTE = 5;
export const OPENAI_CHAT_MODEL = 'gpt-4o-mini';

const MIN_MESSAGE_LENGTH = 3;
const MAX_REPEATED_CHARS = 10;
const SUSPICIOUS_PATTERN_THRESHOLD = 3;

const STORAGE_RELATED_KEYWORDS = [
  'storage',
  'facility',
  'facilities',
  'tenant',
  'tenants',
  'unit',
  'units',
  'occupancy',
  'payment',
  'payments',
  'rent',
  'lease',
  'contract',
  'move-in',
  'move-out',
  'gate',
  'access',
  'auction',
  'lien',
  'delinquency',
  'pricing',
  'yield',
  'insurance',
  'dnr',
  'reservation',
  'vacancy',
  'deposit',
  'billing',
  'stripe',
  'report',
  'reports',
  'late fee',
  'self-storage',
  'self storage',
  'management',
  'app ',
  'feature',
  'how do i',
  'how to',
  'property',
  'properties',
  'location',
  'business',
  'customer',
  'rental',
  'space',
  'locker',
  'owner',
  'operate',
  'operating',
  'running',
  'best practice',
  'setup',
  'set up',
  'tips',
  'advice',
  'monthly',
  'overdue',
  'collections',
  'evict',
  'overlock',
  'lock out',
  'lockout',
  'charge',
  'charges',
  'fee',
  'fees',
  'price',
  'rates',
  'revenue',
  'income',
];

const OFF_TOPIC_KEYWORDS = [
  'star trek',
  'startrek',
  'star wars',
  'movie',
  'movies',
  'film',
  'recipe',
  'recipes',
  'cook',
  'sports',
  'football',
  'basketball',
  'game of thrones',
  'lotr',
  'music',
  'celebrity',
  'joke',
  'jokes',
  'meme',
  'trivia',
  'recipe for',
  ' dog ',
  ' cat ',
  ' puppy',
  ' kitten',
  ' dog named',
  ' cat named',
  'a dog',
  'a cat',
];

const PERSONALIZED_MESSAGE_PATTERNS = [
  /(?:give me|write|draft|send|email)\s+(?:a\s+)?(?:message|email|reminder|notice)\s+to\s+/i,
  /(?:message|email|reminder|notice)\s+to\s+send\s+to\s+/i,
  /(?:send|write)\s+(?:a\s+)?(?:message|email)\s+to\s+/i,
  /\b(?:hi|dear|hello)\s+[a-z]+\s*[,.]\s*(?:rent|payment|due)/i,
];

const PROMPT_INJECTION_PATTERNS = [
  /ignore\s+(?:previous|all|above)\s+(?:instructions?|prompts?|rules?)/i,
  /forget\s+(?:previous|all|above)\s+(?:instructions?|prompts?|rules?)/i,
  /you\s+are\s+now\s+(?:a|an)\s+/i,
  /system\s*:\s*you\s+are/i,
  /new\s+instructions?\s*:/i,
  /override\s+(?:previous|system)/i,
  /act\s+as\s+if/i,
  /pretend\s+to\s+be/i,
  /roleplay\s+as/i,
  /\[system\]/i,
  /<\|system\|>/i,
  /###\s*instructions?\s*:/i,
];

const SUSPICIOUS_PATTERNS = [
  /(.)\1{9,}/,
  /[^\x20-\x7E]{5,}/,
  /(?:http|https|ftp):\/\//i,
  /<script|javascript:|onerror=|onclick=/i,
  /eval\(|exec\(|system\(/i,
  /password|secret|api[_\s]?key|token|credential/i,
  /\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/,
];

export function hashUserId(userId: string): string {
  return crypto.createHash('sha256').update(userId, 'utf8').digest('hex').slice(0, 16);
}

/** Currently unused by handlers; kept for parity with legacy index. */
export function isStorageFacilityRelated(message: string): boolean {
  const m = message.toLowerCase().trim();
  if (m.length < MIN_MESSAGE_LENGTH) return false;
  const hasStorage = STORAGE_RELATED_KEYWORDS.some((kw) => m.includes(kw));
  const hasOffTopic = OFF_TOPIC_KEYWORDS.some((kw) => m.includes(kw));
  if (hasOffTopic && !hasStorage) return false;
  if (hasStorage) return true;
  if (m.length <= 35 && !hasOffTopic) return true;
  return false;
}

export function containsPromptInjection(message: string): boolean {
  return PROMPT_INJECTION_PATTERNS.some((pattern) => pattern.test(message));
}

export function containsSuspiciousPatterns(message: string): { detected: boolean; patterns: string[] } {
  const detectedPatterns: string[] = [];

  for (const pattern of SUSPICIOUS_PATTERNS) {
    if (pattern.test(message)) {
      detectedPatterns.push(pattern.toString());
    }
  }

  const repeatedCharMatch = message.match(/(.)\1{9,}/);
  if (repeatedCharMatch) {
    detectedPatterns.push('repeated_characters');
  }

  return {
    detected: detectedPatterns.length >= SUSPICIOUS_PATTERN_THRESHOLD,
    patterns: detectedPatterns,
  };
}

export function isValidMessageStructure(message: string): { valid: boolean; reason?: string } {
  const trimmed = message.trim();

  if (trimmed.length < MIN_MESSAGE_LENGTH) {
    return { valid: false, reason: 'Message too short' };
  }

  const repeatedCharMatch = trimmed.match(/(.)\1{9,}/);
  if (repeatedCharMatch) {
    return { valid: false, reason: 'Invalid message format' };
  }

  if (trimmed.split(/\s+/).length > 200) {
    return { valid: false, reason: 'Message too long' };
  }

  return { valid: true };
}

function containsPersonalizedMessageRequest(message: string): boolean {
  return PERSONALIZED_MESSAGE_PATTERNS.some((re) => re.test(message));
}

export function containsNonsenseOrPersonalizedRequest(message: string): boolean {
  const m = message.toLowerCase();
  if (containsPersonalizedMessageRequest(message)) return true;
  const hasPet = /\b(dog|cat|puppy|kitten|pet)\b/.test(m);
  const hasTenantContext = /\b(rent|tenant|late|payment|message to|send to|email to)\b/.test(m);
  if (hasPet && hasTenantContext) return true;
  return false;
}
