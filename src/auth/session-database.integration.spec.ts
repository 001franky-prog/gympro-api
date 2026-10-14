
import 'dotenv/config';

import {
  describe,
  expect,
  it,
  beforeAll,
  afterAll,
} from 'vitest';

import { ConfigService } from '@nestjs/config';

import { SessionDatabaseService } from './session-database.service.js';

/**
 * Gym Pro SaaS
 * Session Database Security Integration Tests
 *
 * Database role: gympro_session
 *
 * Tests are read-only.
 * PostgreSQL pool is closed exactly once
 * during afterAll cleanup.
 */

describe('Gym Pro Session Database Security', () => {
  let sessionDatabase: SessionDatabaseService;

  beforeAll(() => {
    sessionDatabase = new SessionDatabaseService(
      new ConfigService(),
    );
  });

  afterAll(async () => {
    if (sessionDatabase) {
      await sessionDatabase.onModuleDestroy();
    }
  });

  it('DB01: connects to the correct database and role', async () => {
    await expect(
      sessionDatabase.onModuleInit(),
    ).resolves.toBeUndefined();
  });

  it('DB02: verifies all protected session privileges are denied', async () => {
    const verified =
      await sessionDatabase.verifySessionPrivileges();

    expect(verified).toBe(true);
  });

  it('DB03: maintains the connection for controlled cleanup', async () => {
    const verified =
      await sessionDatabase.verifySessionPrivileges();

    expect(verified).toBe(true);

    // The PostgreSQL pool will be closed
    // by afterAll() exactly once.
  });
});
