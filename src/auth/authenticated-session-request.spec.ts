
import {
  describe,
  expect,
  it,
} from 'vitest';

import {
  createVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

import {
  isAuthenticatedSessionRequest,
} from './authenticated-session-request.js';

describe('Gym Pro Authenticated Session Request', () => {
  const validIdentity = {
    userId: '11111111-1111-4111-8111-111111111111',
    tenantId: '22222222-2222-4222-8222-222222222222',
    membershipId: '33333333-3333-4333-8333-333333333333',
  };

  const validRequest = () => ({
    eligibility: createVerifiedLoginEligibility({
      ...validIdentity,
    }),
    tokenHash: Buffer.alloc(32, 0xab),
  });

  it('R01: accepts valid branded eligibility and digest', () => {
    expect(
      isAuthenticatedSessionRequest(validRequest()),
    ).toBe(true);
  });

  it('R02: rejects plain unbranded eligibility', () => {
    expect(
      isAuthenticatedSessionRequest({
        eligibility: { ...validIdentity },
        tokenHash: Buffer.alloc(32),
      }),
    ).toBe(false);
  });

  it('R03: rejects missing eligibility', () => {
    expect(
      isAuthenticatedSessionRequest({
        tokenHash: Buffer.alloc(32),
      }),
    ).toBe(false);
  });

  it('R04: rejects invalid user UUID', () => {
    const request = validRequest();

    const invalid = {
      ...request,
      eligibility: createVerifiedLoginEligibility({
        ...validIdentity,
        userId: 'invalid-user',
      }),
    };

    expect(
      isAuthenticatedSessionRequest(invalid),
    ).toBe(false);
  });

  it('R05: rejects invalid tenant UUID', () => {
    const request = validRequest();

    expect(
      isAuthenticatedSessionRequest({
        ...request,
        eligibility: createVerifiedLoginEligibility({
          ...validIdentity,
          tenantId: 'invalid-tenant',
        }),
      }),
    ).toBe(false);
  });

  it('R06: rejects invalid membership UUID', () => {
    const request = validRequest();

    expect(
      isAuthenticatedSessionRequest({
        ...request,
        eligibility: createVerifiedLoginEligibility({
          ...validIdentity,
          membershipId: 'invalid-membership',
        }),
      }),
    ).toBe(false);
  });

  it('R07: rejects 16-byte digest', () => {
    expect(
      isAuthenticatedSessionRequest({
        ...validRequest(),
        tokenHash: Buffer.alloc(16),
      }),
    ).toBe(false);
  });

  it('R08: rejects 64-byte digest', () => {
    expect(
      isAuthenticatedSessionRequest({
        ...validRequest(),
        tokenHash: Buffer.alloc(64),
      }),
    ).toBe(false);
  });

  it('R09: rejects string token hash', () => {
    expect(
      isAuthenticatedSessionRequest({
        ...validRequest(),
        tokenHash: 'not-a-buffer',
      }),
    ).toBe(false);
  });

  it('R10: rejects missing token hash', () => {
    expect(
      isAuthenticatedSessionRequest({
        eligibility: validRequest().eligibility,
      }),
    ).toBe(false);
  });

  it('R11: rejects null and undefined', () => {
    expect(
      isAuthenticatedSessionRequest(null),
    ).toBe(false);

    expect(
      isAuthenticatedSessionRequest(undefined),
    ).toBe(false);
  });

  it('R12: rejects serialized eligibility', () => {
    const original = validRequest();

    const restoredEligibility: unknown =
      JSON.parse(JSON.stringify(original.eligibility));

    expect(
      isAuthenticatedSessionRequest({
        eligibility: restoredEligibility,
        tokenHash: Buffer.alloc(32),
      }),
    ).toBe(false);
  });
});
