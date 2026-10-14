
import {
  describe,
  expect,
  it,
} from 'vitest';

import {
  createVerifiedLoginEligibility,
  isVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

describe('Gym Pro Verified Login Eligibility Guard', () => {
  const eligibility = {
    userId: '11111111-1111-4111-8111-111111111111',
    tenantId: '22222222-2222-4222-8222-222222222222',
    membershipId: '33333333-3333-4333-8333-333333333333',
  };

  it('E01: accepts a factory-created eligibility object', () => {
    const verified =
      createVerifiedLoginEligibility(eligibility);

    expect(isVerifiedLoginEligibility(verified))
      .toBe(true);

    expect(verified.userId).toBe(eligibility.userId);
    expect(verified.tenantId).toBe(eligibility.tenantId);
    expect(verified.membershipId)
      .toBe(eligibility.membershipId);
  });

  it('E02: rejects an ordinary plain object', () => {
    const plain = { ...eligibility };

    expect(isVerifiedLoginEligibility(plain))
      .toBe(false);
  });

  it('E03: rejects null and undefined', () => {
    expect(isVerifiedLoginEligibility(null))
      .toBe(false);

    expect(isVerifiedLoginEligibility(undefined))
      .toBe(false);
  });

  it('E04: rejects an object missing membershipId', () => {
    const incomplete = {
      userId: eligibility.userId,
      tenantId: eligibility.tenantId,
    };

    expect(isVerifiedLoginEligibility(incomplete))
      .toBe(false);
  });

  it('E05: rejects objects with a fake brand', () => {
    const fake = {
      ...eligibility,
      verified: true,
      brand: true,
      authenticated: true,
    };

    expect(isVerifiedLoginEligibility(fake))
      .toBe(false);
  });

  it('E06: factory-created eligibility is frozen', () => {
    const verified =
      createVerifiedLoginEligibility(eligibility);

    expect(Object.isFrozen(verified)).toBe(true);

    expect(() => {
      Object.assign(verified, {
        membershipId:
          '44444444-4444-4444-8444-444444444444',
      });
    }).toThrow(TypeError);

    expect(verified.membershipId)
      .toBe(eligibility.membershipId);
  });

  it('E07: serialized eligibility loses its brand', () => {
    const verified =
      createVerifiedLoginEligibility(eligibility);

    const serialized = JSON.stringify(verified);
    const restored: unknown = JSON.parse(serialized);

    expect(isVerifiedLoginEligibility(restored))
      .toBe(false);

    expect(isVerifiedLoginEligibility(verified))
      .toBe(true);
  });
});
