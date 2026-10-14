import {
  describe,
  expect,
  it,
} from 'vitest';

import {
  ServiceUnavailableException,
} from '@nestjs/common';

import {
  SessionDatabaseService,
} from './session-database.service.js';

import {
  SESSION_SECURITY_POLICY,
} from './session-security-policy.js';

import type {
  ConfigService,
} from '@nestjs/config';

describe('Gym Pro Session Activation Safety', () => {
  it('S01: session persistence remains disabled', () => {
    expect(
      SESSION_SECURITY_POLICY.persistenceEnabled,
    ).toBe(false);
  });

  it('S02: session token hash length is 32 bytes', () => {
    expect(
      SESSION_SECURITY_POLICY.tokenHashBytes,
    ).toBe(32);
  });

  it('S03: dedicated session database role is configured', () => {
    expect(
      SESSION_SECURITY_POLICY.databaseRole,
    ).toBe('gympro_session');
  });

  it('S04: missing database configuration is rejected', () => {
    const config = {
      get: () => undefined,
    } as unknown as ConfigService;

    expect(
      () => new SessionDatabaseService(config),
    ).toThrow(
      'SESSION_DATABASE_URL is not configured',
    );
  });

  it('S05: active writes remain disabled', async () => {
    const config = {
      get: () => 'postgresql://test-only-placeholder',
    } as unknown as ConfigService;

    const service = new SessionDatabaseService(
      config,
    );

    await expect(
      service.createTenantSession(
        '33333333-3333-4333-8333-333333333333',
        Buffer.alloc(32, 0xab),
      ),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    await service.onModuleDestroy();
  });

  it('S06: malformed session input is rejected', async () => {
    const config = {
      get: () => 'postgresql://test-only-placeholder',
    } as unknown as ConfigService;

    const service = new SessionDatabaseService(
      config,
    );

    await expect(
      service.createTenantSession(
        'invalid-membership',
        Buffer.alloc(12, 0),
      ),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    await service.onModuleDestroy();
  });
});