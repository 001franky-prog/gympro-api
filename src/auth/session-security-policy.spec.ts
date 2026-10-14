
import {
  describe,
  expect,
  it,
} from 'vitest';

import {
  SESSION_SECURITY_POLICY,
  isValidSessionPersistenceInput,
  isSessionPersistenceEnabled,
} from './session-security-policy.js';

describe('Gym Pro Session Security Policy', () => {
  const identity = {
    userId: '11111111-1111-4111-8111-111111111111',
    tenantId: '22222222-2222-4222-8222-222222222222',
    membershipId: '33333333-3333-4333-8333-333333333333',
  };

  const validInput = () => ({
    identity: { ...identity },
    tokenHash: Buffer.alloc(32, 0xab),
  });

  it('P01: requires 32-byte session tokens', () => {
    expect(SESSION_SECURITY_POLICY.tokenBytes)
      .toBe(32);
  });

  it('P02: requires 32-byte SHA-256 hashes', () => {
    expect(SESSION_SECURITY_POLICY.tokenHashBytes)
      .toBe(32);

    expect(SESSION_SECURITY_POLICY.tokenHashAlgorithm)
      .toBe('sha256');
  });

  it('P03: configures eight-hour expiration', () => {
    expect(SESSION_SECURITY_POLICY.sessionLifetimeSeconds)
      .toBe(28800);
  });

  it('P04: uses the dedicated session database role', () => {
    expect(SESSION_SECURITY_POLICY.databaseRole)
      .toBe('gympro_session');
  });

  it('P05: accepts structurally valid input', () => {
    expect(
      isValidSessionPersistenceInput(validInput()),
    ).toBe(true);
  });

  it('P06: rejects an invalid user UUID', () => {
    expect(
      isValidSessionPersistenceInput({
        ...validInput(),
        identity: {
          ...identity,
          userId: 'invalid-user',
        },
      }),
    ).toBe(false);
  });

  it('P07: rejects an invalid tenant UUID', () => {
    expect(
      isValidSessionPersistenceInput({
        ...validInput(),
        identity: {
          ...identity,
          tenantId: 'invalid-tenant',
        },
      }),
    ).toBe(false);
  });

  it('P08: rejects an invalid membership UUID', () => {
    expect(
      isValidSessionPersistenceInput({
        ...validInput(),
        identity: {
          ...identity,
          membershipId: 'invalid-membership',
        },
      }),
    ).toBe(false);
  });

  it('P09: rejects short and long token hashes', () => {
    expect(
      isValidSessionPersistenceInput({
        ...validInput(),
        tokenHash: Buffer.alloc(16),
      }),
    ).toBe(false);

    expect(
      isValidSessionPersistenceInput({
        ...validInput(),
        tokenHash: Buffer.alloc(64),
      }),
    ).toBe(false);
  });

  it('P10: rejects non-Buffer token hashes', () => {
    expect(
      isValidSessionPersistenceInput({
        ...validInput(),
        tokenHash: 'not-a-buffer',
      }),
    ).toBe(false);

    expect(
      isValidSessionPersistenceInput({
        ...validInput(),
        tokenHash: new Uint8Array(32),
      }),
    ).toBe(false);
  });

  it('P11: rejects missing or malformed input', () => {
    expect(
      isValidSessionPersistenceInput(null),
    ).toBe(false);

    expect(
      isValidSessionPersistenceInput(undefined),
    ).toBe(false);

    expect(
      isValidSessionPersistenceInput({}),
    ).toBe(false);

    expect(
      isValidSessionPersistenceInput({
        tokenHash: Buffer.alloc(32),
      }),
    ).toBe(false);

    expect(
      isValidSessionPersistenceInput({
        identity: { ...identity },
      }),
    ).toBe(false);
  });

  it('P12: keeps session persistence disabled', () => {
    expect(
      SESSION_SECURITY_POLICY.persistenceEnabled,
    ).toBe(false);

    expect(
      isSessionPersistenceEnabled(),
    ).toBe(false);
  });

  it('P13: prevents ordinary policy mutation', () => {
    expect(
      Object.isFrozen(SESSION_SECURITY_POLICY),
    ).toBe(true);

    expect(() => {
      Object.assign(SESSION_SECURITY_POLICY, {
        persistenceEnabled: true,
      });
    }).toThrow(TypeError);

    expect(
      isSessionPersistenceEnabled(),
    ).toBe(false);
  });
});
