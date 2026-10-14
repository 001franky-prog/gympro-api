import 'reflect-metadata';

import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  BadRequestException,
  ForbiddenException,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import type { ConfigService } from '@nestjs/config';

import type {
  GymProAuthenticatedRequest,
} from '../auth/authenticated-session.guard.js';

import type {
  SessionBearerTokenService,
} from '../auth/session-bearer-token.service.js';

const database = vi.hoisted(() => ({
  query: vi.fn(),
  on: vi.fn(),
  end: vi.fn(),
}));

vi.mock('pg', () => ({
  default: {
    Pool: class {
      query = database.query;
      on = database.on;
      end = database.end;
    },
  },
}));

import {
  MemberRegistrationService,
} from './member-registration.service.js';

const tenantId = '11111111-1111-4111-8111-111111111111';
const otherTenantId = '22222222-2222-4222-8222-222222222222';
const branchId = '66666666-6666-4666-8666-666666666666';
const otherBranchId = '88888888-8888-4888-8888-888888888888';

const tokenHash = Buffer.alloc(32, 0xab);

const bearerTokenService = {
  hashAuthorization: vi.fn(),
};

const validBody = {
  fullName: '  U Aung Aung  ',
  phone: '09912345678',
  email: '  AUNG@EXAMPLE.INVALID  ',
};

const validIdentity = {
  database_name: 'gympro_saas',
  database_user: 'gympro_app',
  is_superuser: false,
  bypasses_rls: false,
  can_use_security_schema: true,
  can_register: true,
  can_select_members: false,
  can_insert_members: false,
  can_update_members: false,
  can_delete_members: false,
};

function authenticatedRequest(): GymProAuthenticatedRequest {
  return {
    headers: {
      authorization: 'Bearer test-only-token',
    },
    gymproSession: {
      sessionId: '33333333-3333-4333-8333-333333333333',
      userId: '44444444-4444-4444-8444-444444444444',
      tenantId,
      membershipId: '55555555-5555-4555-8555-555555555555',
    },
  };
}

function memberRecord(memberBranchId: string | null = null) {
  return {
    id: '77777777-7777-4777-8777-777777777777',
    tenant_id: tenantId,
    branch_id: memberBranchId,
    member_number: 'GP-0000000001',
    full_name: 'U Aung Aung',
    phone: '09912345678',
    email: 'aung@example.invalid',
    status: 'pending',
    created_at: new Date('2026-10-14T04:00:00.000Z'),
    updated_at: new Date('2026-10-14T04:00:00.000Z'),
  };
}

function createService(): MemberRegistrationService {
  const configuration = {
    get: vi.fn((key: string) =>
      key === 'DATABASE_URL'
        ? 'postgresql://gympro_app@127.0.0.1:1/gympro_saas'
        : undefined,
    ),
  };

  return new MemberRegistrationService(
    configuration as unknown as ConfigService,
    bearerTokenService as unknown as SessionBearerTokenService,
  );
}

describe('Gym Pro MemberRegistrationService', () => {
  let service: MemberRegistrationService;

  beforeEach(async () => {
    vi.resetAllMocks();

    bearerTokenService.hashAuthorization.mockReturnValue(
      tokenHash,
    );

    database.query.mockResolvedValueOnce({
      rows: [{ ...validIdentity }],
    });

    service = createService();
    await service.onModuleInit();

    database.query.mockReset();
  });

  it.each([
    { label: 'tenant-wide', selectedBranch: null },
    { label: 'branch-specific', selectedBranch: branchId },
  ])(
    'registers a $label member with normalized parameters',
    async ({ selectedBranch }) => {
      const row = memberRecord(selectedBranch);

      database.query.mockResolvedValueOnce({
        rows: [row],
      });

      const result = await service.register(
        authenticatedRequest(),
        tenantId,
        selectedBranch,
        validBody,
      );

      expect(database.query).toHaveBeenCalledTimes(1);

      expect(database.query).toHaveBeenCalledWith(
        expect.stringContaining('security.register_member'),
        [
          tokenHash,
          tenantId,
          selectedBranch,
          'U Aung Aung',
          '09912345678',
          'aung@example.invalid',
        ],
      );

      expect(result).toEqual({
        id: row.id,
        tenantId,
        branchId: selectedBranch,
        memberNumber: row.member_number,
        fullName: row.full_name,
        phone: row.phone,
        email: row.email,
        status: 'pending',
        createdAt: row.created_at,
        updatedAt: row.updated_at,
      });
    },
  );

  it('rejects a request without a verified session', async () => {
    await expect(
      service.register(
        { headers: { authorization: 'Bearer test-only-token' } },
        tenantId,
        null,
        validBody,
      ),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
    expect(bearerTokenService.hashAuthorization)
      .not.toHaveBeenCalled();
  });

  it('rejects a route belonging to another tenant', async () => {
    await expect(
      service.register(
        authenticatedRequest(),
        otherTenantId,
        null,
        validBody,
      ),
    ).rejects.toBeInstanceOf(ForbiddenException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    'tenantId',
    'branchId',
    'status',
    'memberNumber',
  ])('rejects client-controlled %s in the body', async (field) => {
    await expect(
      service.register(
        authenticatedRequest(),
        tenantId,
        null,
        {
          ...validBody,
          [field]: 'client-supplied-value',
        },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('maps missing contact details to a bad request', async () => {
    await expect(
      service.register(
        authenticatedRequest(),
        tenantId,
        null,
        { fullName: 'U Aung Aung' },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects a malformed branch identifier', async () => {
    await expect(
      service.register(
        authenticatedRequest(),
        tenantId,
        'invalid-branch',
        validBody,
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects an invalid token-hash length', async () => {
    bearerTokenService.hashAuthorization.mockReturnValueOnce(
      Buffer.alloc(1),
    );

    await expect(
      service.register(
        authenticatedRequest(),
        tenantId,
        null,
        validBody,
      ),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    {
      name: 'invalid session',
      failure: {
        code: '28000',
        message: 'Invalid or expired session',
      },
      expected: UnauthorizedException,
    },
    {
      name: 'denied member permission',
      failure: {
        code: '42501',
        message: 'Member registration permission denied',
      },
      expected: ForbiddenException,
    },
    {
      name: 'invalid registration data',
      failure: {
        code: '22023',
        message: 'Invalid phone number',
      },
      expected: BadRequestException,
    },
    {
      name: 'database privilege configuration failure',
      failure: {
        code: '42501',
        message: 'permission denied for function register_member',
      },
      expected: ServiceUnavailableException,
    },
    {
      name: 'database connection failure',
      failure: {
        code: 'ECONNREFUSED',
        message: 'private-database-connection-details',
      },
      expected: ServiceUnavailableException,
    },
  ])('handles $name safely', async ({ failure, expected }) => {
    database.query.mockRejectedValueOnce(failure);

    const result = await service.register(
      authenticatedRequest(),
      tenantId,
      null,
      validBody,
    ).catch((error: unknown) => error);

    expect(result).toBeInstanceOf(expected);

    if (result instanceof ServiceUnavailableException) {
      expect(JSON.stringify(result.getResponse()))
        .not.toContain(failure.message);
    }
  });

  it.each([
    {
      name: 'another tenant',
      changes: { tenant_id: otherTenantId },
    },
    {
      name: 'another branch',
      changes: { branch_id: otherBranchId },
    },
  ])('rejects a returned member from $name', async ({ changes }) => {
    database.query.mockResolvedValueOnce({
      rows: [
        {
          ...memberRecord(branchId),
          ...changes,
        },
      ],
    });

    await expect(
      service.register(
        authenticatedRequest(),
        tenantId,
        branchId,
        validBody,
      ),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects an empty registration result', async () => {
    database.query.mockResolvedValueOnce({ rows: [] });

    await expect(
      service.register(
        authenticatedRequest(),
        tenantId,
        null,
        validBody,
      ),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    {
      name: 'an administrator database account',
      changes: {
        database_user: 'postgres',
        is_superuser: true,
      },
    },
    {
      name: 'direct member-table access',
      changes: {
        can_select_members: true,
      },
    },
  ])('rejects startup with $name', async ({ changes }) => {
    const unverifiedService = createService();

    database.query.mockResolvedValueOnce({
      rows: [
        {
          ...validIdentity,
          ...changes,
        },
      ],
    });

    await expect(
      unverifiedService.onModuleInit(),
    ).rejects.toThrow('requires gympro_app');

    await expect(
      unverifiedService.register(
        authenticatedRequest(),
        tenantId,
        null,
        validBody,
      ),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).toHaveBeenCalledTimes(1);
  });

  it('rejects registration before startup verification', async () => {
    const unverifiedService = createService();

    await expect(
      unverifiedService.register(
        authenticatedRequest(),
        tenantId,
        null,
        validBody,
      ),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).not.toHaveBeenCalled();
  });
});