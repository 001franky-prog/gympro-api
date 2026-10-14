
import 'dotenv/config';

import {
  describe,
  it,
  expect,
  beforeAll,
  afterAll,
} from 'vitest';

import { ConfigService } from '@nestjs/config';

import {
  AuthDatabaseService,
} from './auth-database.service.js';

/**
 * Gym Pro SaaS
 * AuthDatabaseService integration tests
 *
 * The Admin A development account may be pending
 * or active depending on earlier login testing.
 *
 * These tests verify user lookup without changing
 * database records or account statuses.
 */

describe('Gym Pro AuthDatabaseService', () => {
  let service: AuthDatabaseService;

  beforeAll(async () => {
    service = new AuthDatabaseService(
      new ConfigService(),
    );

    await service.onModuleInit();
  });

  afterAll(async () => {
    if (service) {
      await service.onModuleDestroy();
    }
  });

  it('A01: finds existing Admin A and returns a valid account status', async () => {
    const user =
      await service.findUserCredentials(
        'admin.a@example.com',
      );

    expect(user).not.toBeNull();

    expect(user?.user_id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );

    expect([
      'pending',
      'active',
      'suspended',
      'disabled',
    ]).toContain(user?.account_status);

    expect(
      user?.password_hash === null ||
      typeof user?.password_hash === 'string',
    ).toBe(true);
  });

  it('A02: finds the pending shared user', async () => {
    const user =
      await service.findUserCredentials(
        'shared@example.com',
      );

    expect(user).not.toBeNull();
    expect(user?.account_status).toBe('pending');
    expect(user?.password_hash).toBeNull();
  });

  it('A03: rejects an unknown email', async () => {
    const user =
      await service.findUserCredentials(
        'unknown@example.com',
      );

    expect(user).toBeNull();
  });

  it('A04: rejects an empty email', async () => {
    const user =
      await service.findUserCredentials('');

    expect(user).toBeNull();
  });
});
