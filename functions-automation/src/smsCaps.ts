/** Mirrors default `functions` SMS env caps for monthly reset jobs. */
const SMS_LIMIT_PER_FACILITY = parseInt(process.env.SMS_LIMIT_PER_FACILITY || '1000', 10);
const SMS_LIMIT_PER_ACCOUNT = parseInt(process.env.SMS_LIMIT_PER_ACCOUNT || '3000', 10);
const SMS_COST_PER_MESSAGE = parseFloat(process.env.SMS_COST_PER_MESSAGE || '0.01');
const SMS_MAX_COST_PER_FACILITY = parseFloat(process.env.SMS_MAX_COST_PER_FACILITY || '40');

export function capSmsLimit(limit: number): number {
  if (limit <= 0) return 0;
  const maxMessages = Math.floor(SMS_MAX_COST_PER_FACILITY / SMS_COST_PER_MESSAGE);
  return Math.min(limit, maxMessages);
}

export { SMS_LIMIT_PER_ACCOUNT, SMS_LIMIT_PER_FACILITY };
