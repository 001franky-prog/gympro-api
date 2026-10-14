import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  OnModuleDestroy,
  OnModuleInit,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import { ConfigService } from '@nestjs/config';
import pg from 'pg';

import {
  SessionBearerTokenService,
} from '../auth/session-bearer-token.service.js';

import type {
  GymProAuthenticatedRequest,
} from '../auth/authenticated-session.guard.js';

import {
  MemberValidationError,
  validateCreateMemberInput,
} from './member-profile.js';

import type {
  MemberProfile,
  NormalizedMemberInput,
} from './member-profile.js';

const { Pool } = pg;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const MEMBER_NUMBER_PATTERN = /^GP-[0-9]{10}$/;

interface RegistrationDatabaseIdentity {
  database_name: string;
  database_user: string;
  is_superuser: boolean;
  bypasses_rls: boolean;
  can_use_security_schema: boolean;
  can_register: boolean | null;
  can_select_members: boolean;
  can_insert_members: boolean;
  can_update_members: boolean;
  can_delete_members: boolean;
}

interface RegisteredMemberRecord {
  id: string;
  tenant_id: string;
  branch_id: string | null;
  member_number: string;
  full_name: string;
  phone: string | null;
  email: string | null;
  status: string;
  created_at: Date;
  updated_at: Date;
}

@Injectable()
export class MemberRegistrationService
  implements OnModuleInit, OnModuleDestroy
{
  private readonly pool: pg.Pool;
  private runtimeVerified = false;

  constructor(
    configService: ConfigService,
    private readonly bearerTokenService: SessionBearerTokenService,
  ) {
    const databaseUrl =
      configService.get<string>('DATABASE_URL');

    if (!databaseUrl) {
      throw new Error('DATABASE_URL is not configured');
    }

    this.pool = new Pool({
      connectionString: databaseUrl,
      max: 5,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });

    this.pool.on('error', () => {
      console.error('Member registration database pool error');
    });
  }

  async onModuleInit(): Promise<void> {
    this.runtimeVerified = false;

    let identity: RegistrationDatabaseIdentity | undefined;

    try {
      const result =
        await this.pool.query<RegistrationDatabaseIdentity>(
          `
            SELECT
              current_database() AS database_name,
              current_user AS database_user,
              r.rolsuper AS is_superuser,
              r.rolbypassrls AS bypasses_rls,

              has_schema_privilege(
                current_user, 'security', 'USAGE'
              ) AS can_use_security_schema,

              has_function_privilege(
                current_user,
                to_regprocedure(
                  'security.register_member(bytea,uuid,uuid,text,text,text)'
                ),
                'EXECUTE'
              ) AS can_register,

              has_table_privilege(
                current_user, 'app.members', 'SELECT'
              ) AS can_select_members,

              has_table_privilege(
                current_user, 'app.members', 'INSERT'
              ) AS can_insert_members,

              has_table_privilege(
                current_user, 'app.members', 'UPDATE'
              ) AS can_update_members,

              has_table_privilege(
                current_user, 'app.members', 'DELETE'
              ) AS can_delete_members

            FROM pg_roles AS r
            WHERE r.rolname = current_user
          `,
        );

      if (result.rows.length === 1) {
        identity = result.rows[0];
      }
    } catch {
      throw new Error(
        'Member registration database verification unavailable',
      );
    }

    if (
      !identity ||
      identity.database_name !== 'gympro_saas' ||
      identity.database_user !== 'gympro_app' ||
      identity.is_superuser !== false ||
      identity.bypasses_rls !== false ||
      identity.can_use_security_schema !== true ||
      identity.can_register !== true ||
      identity.can_select_members !== false ||
      identity.can_insert_members !== false ||
      identity.can_update_members !== false ||
      identity.can_delete_members !== false
    ) {
      throw new Error(
        'Member registration requires gympro_app connected to gympro_saas with function-only member access',
      );
    }

    this.runtimeVerified = true;
  }

  async register(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    branchId: string | null,
    body: unknown,
  ): Promise<MemberProfile> {
    const session = request?.gymproSession;

    if (
      !session ||
      typeof session.sessionId !== 'string' ||
      typeof session.userId !== 'string' ||
      typeof session.tenantId !== 'string' ||
      typeof session.membershipId !== 'string' ||
      !UUID_PATTERN.test(session.sessionId) ||
      !UUID_PATTERN.test(session.userId) ||
      !UUID_PATTERN.test(session.tenantId) ||
      !UUID_PATTERN.test(session.membershipId)
    ) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    if (
      typeof tenantId !== 'string' ||
      !UUID_PATTERN.test(tenantId)
    ) {
      throw new BadRequestException(
        'Invalid tenant identifier',
      );
    }

    if (
      tenantId.toLowerCase() !==
      session.tenantId.toLowerCase()
    ) {
      throw new ForbiddenException('Tenant access denied');
    }

    if (
      branchId !== null &&
      (
        typeof branchId !== 'string' ||
        !UUID_PATTERN.test(branchId)
      )
    ) {
      throw new BadRequestException(
        'Invalid branch identifier',
      );
    }

    if (!this.runtimeVerified) {
      throw new ServiceUnavailableException(
        'Member registration unavailable',
      );
    }

    const tokenHash =
      this.bearerTokenService.hashAuthorization(
        request.headers?.authorization,
      );

    if (
      !Buffer.isBuffer(tokenHash) ||
      tokenHash.length !== 32
    ) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    const input = this.validateBody(body);

    let rows: RegisteredMemberRecord[];

    try {
      const result =
        await this.pool.query<RegisteredMemberRecord>(
          `
            SELECT
              id,
              tenant_id,
              branch_id,
              member_number,
              full_name,
              phone,
              email,
              status,
              created_at,
              updated_at
            FROM security.register_member(
              $1::bytea,
              $2::uuid,
              $3::uuid,
              $4::text,
              $5::text,
              $6::text
            )
          `,
          [
            tokenHash,
            tenantId,
            branchId,
            input.fullName,
            input.phone,
            input.email,
          ],
        );

      rows = result.rows;
    } catch (error: unknown) {
      this.throwDatabaseError(error);
    }

    const row = rows[0];

    if (
      rows.length !== 1 ||
      !row ||
      typeof row.id !== 'string' ||
      !UUID_PATTERN.test(row.id) ||
      typeof row.tenant_id !== 'string' ||
      row.tenant_id.toLowerCase() !== tenantId.toLowerCase() ||
      (
        row.branch_id !== null &&
        (
          typeof row.branch_id !== 'string' ||
          !UUID_PATTERN.test(row.branch_id)
        )
      ) ||
      (row.branch_id?.toLowerCase() ?? null) !==
        (branchId?.toLowerCase() ?? null) ||
      typeof row.member_number !== 'string' ||
      !MEMBER_NUMBER_PATTERN.test(row.member_number) ||
      row.full_name !== input.fullName ||
      row.phone !== input.phone ||
      row.email !== input.email ||
      row.status !== 'pending' ||
      !(row.created_at instanceof Date) ||
      !Number.isFinite(row.created_at.getTime()) ||
      !(row.updated_at instanceof Date) ||
      !Number.isFinite(row.updated_at.getTime())
    ) {
      throw new ServiceUnavailableException(
        'Member registration unavailable',
      );
    }

    return {
      id: row.id,
      tenantId: row.tenant_id,
      branchId: row.branch_id,
      memberNumber: row.member_number,
      fullName: row.full_name,
      phone: row.phone,
      email: row.email,
      status: 'pending',
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  private validateBody(body: unknown): NormalizedMemberInput {
    if (
      typeof body !== 'object' ||
      body === null ||
      Array.isArray(body)
    ) {
      throw new BadRequestException(
        'Member registration data is required',
      );
    }

    const allowedFields = ['fullName', 'phone', 'email'];

    if (
      Object.keys(body).some(
        (key) => !allowedFields.includes(key),
      )
    ) {
      throw new BadRequestException(
        'Only fullName, phone and email are accepted',
      );
    }

    try {
      return validateCreateMemberInput(body);
    } catch (error: unknown) {
      if (error instanceof MemberValidationError) {
        throw new BadRequestException(error.message);
      }

      throw new BadRequestException(
        'Invalid member registration data',
      );
    }
  }

  private throwDatabaseError(error: unknown): never {
    const failure =
      typeof error === 'object' && error !== null
        ? error as { code?: unknown; message?: unknown }
        : {};

    if (
      failure.code === '28000' &&
      failure.message === 'Invalid or expired session'
    ) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    if (
      failure.code === '42501' &&
      (
        failure.message === 'Tenant access denied' ||
        failure.message === 'Member registration permission denied'
      )
    ) {
      throw new ForbiddenException(
        'Member registration permission denied',
      );
    }

    if (failure.code === '22023') {
      throw new BadRequestException(
        'Invalid member registration data',
      );
    }

    throw new ServiceUnavailableException(
      'Member registration unavailable',
    );
  }

  async onModuleDestroy(): Promise<void> {
    this.runtimeVerified = false;
    await this.pool.end();
  }
}