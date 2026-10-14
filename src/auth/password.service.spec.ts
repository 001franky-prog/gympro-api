
import { describe, it, expect } from 'vitest';
import { randomBytes } from 'node:crypto';
import { PasswordService } from './password.service.js';

describe('Gym Pro PasswordService', () => {
  const service = new PasswordService();

  // Generate a test-only password in memory.
  const password = randomBytes(24).toString('hex');

  it('P01: creates an Argon2id hash', async () => {
    const hash = await service.hashPassword(password);

    expect(hash).toMatch(/^\$argon2id\$/);
    expect(hash).not.toContain(password);
  });

  it('P02: accepts the correct password', async () => {
    const hash = await service.hashPassword(password);

    const valid = await service.verifyPassword(
      hash,
      password,
    );

    expect(valid).toBe(true);
  });

  it('P03: rejects an incorrect password', async () => {
    const hash = await service.hashPassword(password);

    const valid = await service.verifyPassword(
      hash,
      password + '-incorrect',
    );

    expect(valid).toBe(false);
  });

  it('P04: rejects a malformed hash', async () => {
    const valid = await service.verifyPassword(
      'invalid-hash',
      password,
    );

    expect(valid).toBe(false);
  });

  it('P05: generates different salted hashes', async () => {
    const first = await service.hashPassword(password);
    const second = await service.hashPassword(password);

    expect(first).not.toBe(second);

    expect(
      await service.verifyPassword(first, password),
    ).toBe(true);

    expect(
      await service.verifyPassword(second, password),
    ).toBe(true);
  });
});
