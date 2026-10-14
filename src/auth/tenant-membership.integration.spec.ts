
import 'dotenv/config';

import {
  describe,
  it,
  expect,
  beforeAll,
  afterAll,
} from 'vitest';

import { ConfigService } from '@nestjs/config';
import { Client } from 'pg';

import {
  AuthDatabaseService,
} from './auth-database.service.js';

interface UserRecord {
  id: string;
  status: string;
}

interface TenantRecord {
  id: string;
  status: string;
}

interface MembershipRecord {
  id: string;
  status: string;
}

describe('Gym Pro Tenant Membership Integration', () => {
  let authDatabase: AuthDatabaseService;
  let adminDatabase: Client;

  let adminAId: string;
  let sharedUserId: string;

  let gym001Id: string;
  let gym002Id: string;

  let adminAStatus: string;
  let gym001Status: string;
  let adminAMembershipId: string | null;
  let adminAMembershipStatus: string | null;

  beforeAll(async () => {
    const introspectionUrl =
      process.env.INTROSPECT_DATABASE_URL;

    if (!introspectionUrl) {
      throw new Error(
        'INTROSPECT_DATABASE_URL is not configured',
      );
    }

    authDatabase = new AuthDatabaseService(
      new ConfigService(),
    );

    await authDatabase.onModuleInit();

    adminDatabase = new Client({
      connectionString: introspectionUrl,
    });

    await adminDatabase.connect();

    const users = await adminDatabase.query<
      UserRecord & { email: string }
    >(
      `
        SELECT id, email, status
        FROM app.users
        WHERE lower(email) = ANY($1::text[])
      `,
      [[
        'admin.a@example.com',
        'shared@example.com',
      ]],
    );

    const adminA = users.rows.find(
      (u) =>
        u.email.toLowerCase() ===
        'admin.a@example.com',
    );

    const shared = users.rows.find(
      (u) =>
        u.email.toLowerCase() ===
        'shared@example.com',
    );

    adminAId = adminA?.id ?? '';
    adminAStatus = adminA?.status ?? '';
    sharedUserId = shared?.id ?? '';

    const tenants = await adminDatabase.query<
      TenantRecord & { tenant_code: string }
    >(
      `
        SELECT id, tenant_code, status
        FROM platform.tenants
        WHERE tenant_code = ANY($1::text[])
      `,
      [['GYM001', 'GYM002']],
    );

    const gym001 = tenants.rows.find(
      (t) => t.tenant_code === 'GYM001',
    );

    const gym002 = tenants.rows.find(
      (t) => t.tenant_code === 'GYM002',
    );

    gym001Id = gym001?.id ?? '';
    gym001Status = gym001?.status ?? '';
    gym002Id = gym002?.id ?? '';

    if (
      !adminAId ||
      !sharedUserId ||
      !gym001Id ||
      !gym002Id
    ) {
      throw new Error(
        'Missing development test fixtures',
      );
    }

    const membership = await adminDatabase.query<
      MembershipRecord
    >(
      `
        SELECT id, status
        FROM app.tenant_memberships
        WHERE user_id = $1::uuid
          AND tenant_id = $2::uuid
      `,
      [adminAId, gym001Id],
    );

    adminAMembershipId =
      membership.rows[0]?.id ?? null;

    adminAMembershipStatus =
      membership.rows[0]?.status ?? null;
  });

  afterAll(async () => {
    if (adminDatabase) {
      await adminDatabase.end();
    }

    if (authDatabase) {
      await authDatabase.onModuleDestroy();
    }
  });

  it('M01: matches Admin A current authorization state', async () => {
    const membership =
      await authDatabase.verifyActiveTenantMembership(
        adminAId,
        gym001Id,
      );

    const shouldBeAuthorized =
      adminAStatus === 'active' &&
      gym001Status === 'active' &&
      adminAMembershipStatus === 'active';

    if (shouldBeAuthorized) {
      expect(membership).toBe(
        adminAMembershipId,
      );
    } else {
      expect(membership).toBeNull();
    }
  });

  it('M02: rejects invited Shared User in GYM002', async () => {
    const membership =
      await authDatabase.verifyActiveTenantMembership(
        sharedUserId,
        gym002Id,
      );

    expect(membership).toBeNull();
  });

  it('M03: rejects Admin A in another tenant', async () => {
    const membership =
      await authDatabase.verifyActiveTenantMembership(
        adminAId,
        gym002Id,
      );

    expect(membership).toBeNull();
  });

  it('M04: rejects invalid user UUID', async () => {
    const membership =
      await authDatabase.verifyActiveTenantMembership(
        'not-a-uuid',
        gym001Id,
      );

    expect(membership).toBeNull();
  });

  it('M05: rejects invalid tenant UUID', async () => {
    const membership =
      await authDatabase.verifyActiveTenantMembership(
        adminAId,
        'invalid-tenant',
      );

    expect(membership).toBeNull();
  });
});
