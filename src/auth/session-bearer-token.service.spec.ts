import {
  beforeEach,
  describe,
  expect,
  it,
} from 'vitest';

import {
  UnauthorizedException,
} from '@nestjs/common';

import {
  createHash,
  randomBytes,
} from 'node:crypto';

import {
  SessionBearerTokenService,
} from './session-bearer-token.service.js';

describe(
  'Gym Pro Secure Bearer Token Validation',
  () => {
    let service: SessionBearerTokenService;

    beforeEach(() => {
      service =
        new SessionBearerTokenService();
    });

    const token = () =>
      randomBytes(32).toString('base64url');

    it(
      'T01: accepts a valid 256-bit token',
      () => {
        const value = token();

        expect(
          service.extractToken(
            `Bearer ${value}`,
          ),
        ).toBe(value);
      },
    );

    it(
      'T02: creates the expected SHA-256 hash',
      () => {
        const value = token();

        const expected = createHash('sha256')
          .update(value, 'utf8')
          .digest();

        const actual =
          service.hashAuthorization(
            `Bearer ${value}`,
          );

        expect(actual.equals(expected))
          .toBe(true);

        expect(actual.length).toBe(32);
      },
    );

    it(
      'T03: rejects missing authorization',
      () => {
        expect(() =>
          service.extractToken(undefined),
        ).toThrow(UnauthorizedException);
      },
    );

    it(
      'T04: rejects an empty header',
      () => {
        expect(() =>
          service.extractToken(''),
        ).toThrow(UnauthorizedException);
      },
    );

    it(
      'T05: rejects unsupported schemes',
      () => {
        expect(() =>
          service.extractToken(
            `Basic ${token()}`,
          ),
        ).toThrow(UnauthorizedException);
      },
    );

    it(
      'T06: rejects a short token',
      () => {
        expect(() =>
          service.extractToken(
            'Bearer abc123',
          ),
        ).toThrow(UnauthorizedException);
      },
    );

    it(
      'T07: rejects extra spaces',
      () => {
        const value = token();

        expect(() =>
          service.extractToken(
            `Bearer  ${value}`,
          ),
        ).toThrow(UnauthorizedException);
      },
    );

    it(
      'T08: rejects trailing content',
      () => {
        const value = token();

        expect(() =>
          service.extractToken(
            `Bearer ${value} extra`,
          ),
        ).toThrow(UnauthorizedException);
      },
    );

    it(
      'T09: rejects non-string input',
      () => {
        expect(() =>
          service.extractToken({
            authorization: token(),
          }),
        ).toThrow(UnauthorizedException);
      },
    );

    it(
      'T10: rejects noncanonical encoding',
      () => {
        // For a 32-byte token, the final base64url
        // character has only 4 significant bits.
        // Altering unused bits changes the text,
        // but can decode to the same bytes.

        const value = token();
        const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

        const last = value.at(-1);
        if (!last) {
          throw new Error('Unexpected empty token');
        }

        const index = alphabet.indexOf(last);

        const alternate =
          value.slice(0, -1) +
          alphabet[(index & ~3) | ((index + 1) & 3)];

        expect(() =>
          service.extractToken(
            `Bearer ${alternate}`,
          ),
        ).toThrow(UnauthorizedException);
      },
    );

    it(
      'T11: rejects padding characters',
      () => {
        expect(() =>
          service.extractToken(
            `Bearer ${token()}=`,
          ),
        ).toThrow(UnauthorizedException);
      },
    );

    it(
      'T12: accepts case-insensitive Bearer scheme',
      () => {
        const value = token();

        expect(
          service.extractToken(
            `bearer ${value}`,
          ),
        ).toBe(value);
      },
    );
  },
);