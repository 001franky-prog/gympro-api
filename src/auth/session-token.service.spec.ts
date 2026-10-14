
import {
  describe,
  it,
  expect,
} from 'vitest';

import {
  SessionTokenService,
} from './session-token.service.js';

describe('Gym Pro SessionTokenService', () => {
  const service = new SessionTokenService();

  it('T01: generates a valid Base64url token', () => {
    const result = service.generateToken();

    expect(result.token).toMatch(
      /^[A-Za-z0-9_-]{43}$/,
    );

    expect(
      Buffer.from(result.token, 'base64url').length,
    ).toBe(32);
  });

  it('T02: generates unique tokens', () => {
    const first = service.generateToken();
    const second = service.generateToken();

    expect(first.token).not.toBe(second.token);
    expect(first.tokenHash.equals(second.tokenHash))
      .toBe(false);
  });

  it('T03: produces consistent hashes', () => {
    const { token } = service.generateToken();

    const hash1 = service.hashToken(token);
    const hash2 = service.hashToken(token);

    expect(hash1.equals(hash2)).toBe(true);
  });

  it('T04: produces different hashes for different tokens', () => {
    const first = service.generateToken();
    const second = service.generateToken();

    const hash1 = service.hashToken(first.token);
    const hash2 = service.hashToken(second.token);

    expect(hash1.equals(hash2)).toBe(false);
  });

  it('T05: produces a 32-byte SHA-256 digest', () => {
    const result = service.generateToken();

    expect(Buffer.isBuffer(result.tokenHash))
      .toBe(true);

    expect(result.tokenHash.length).toBe(32);
  });

  it('T06: does not store the plaintext token in the digest', () => {
    const result = service.generateToken();

    const digest = result.tokenHash.toString('hex');

    expect(digest).toMatch(/^[a-f0-9]{64}$/);
    expect(digest).not.toContain(result.token);
  });
});
