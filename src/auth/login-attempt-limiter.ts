import { createHmac, randomBytes } from 'node:crypto';

type Bucket = { hits: number; resetsAt: number };
/** Per-process fixed-window admission control. Does not authenticate or lock accounts. */
export class LoginAttemptLimiter {
  private readonly buckets = new Map<string, Bucket>();
  private readonly secret = randomBytes(32);
  constructor(private readonly windowMs = 60_000, private readonly capacity = 10_000) {}

  consume(peer: string, body: unknown, now = performance.now()): number {
    const ip = peer.startsWith('::ffff:') ? peer.slice(7) : peer;
    const keys: Array<{ key: string; limit: number }> = [
      { key: this.key(['peer', ip]), limit: 15 },
    ];
    if (body && typeof body === 'object' && !Array.isArray(body)) {
      const input = body as Record<string, unknown>;
      if (typeof input.tenantId === 'string' && input.tenantId.length <= 64 &&
          typeof input.email === 'string' && input.email.length <= 255) {
        keys.push({ key: this.key(['identity', ip, input.tenantId.toLowerCase(), input.email.trim().toLowerCase()]), limit: 5 });
      }
    }
    if (this.buckets.size + keys.length > this.capacity) {
      for (const [key, bucket] of this.buckets) if (bucket.resetsAt <= now) this.buckets.delete(key);
    }
    let retryMs = 0;
    for (const { key, limit } of keys) {
      const bucket = this.buckets.get(key);
      if (bucket && bucket.resetsAt > now && bucket.hits >= limit) retryMs = Math.max(retryMs, bucket.resetsAt - now);
    }
    if (retryMs > 0) return Math.ceil(retryMs / 1000);
    const missing = keys.filter(({key}) => !this.buckets.has(key)).length;
    if (this.buckets.size + missing > this.capacity) return Math.ceil(this.windowMs / 1000);
    for (const {key} of keys) {
      const bucket = this.buckets.get(key);
      if (!bucket || bucket.resetsAt <= now) this.buckets.set(key, { hits: 1, resetsAt: now + this.windowMs });
      else bucket.hits++;
    }
    return 0;
  }
  private key(parts: string[]): string {
    return createHmac('sha256', this.secret).update(JSON.stringify(parts)).digest('hex');
  }
}
