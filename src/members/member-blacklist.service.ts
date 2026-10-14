import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import type {
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';

import { ConfigService } from '@nestjs/config';
import pg from 'pg';

import {
  SessionBearerTokenService,
} from '../auth/session-bearer-token.service.js';

import type {
  GymProAuthenticatedRequest,
} from '../auth/authenticated-session.guard.js';

import type {
  MemberStatus,
} from './member-profile.js';

import type {
  ChangeMemberBlacklistInput,
  MemberBlacklistAction,
  MemberBlacklistEvent,
} from './member-blacklist.js';

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface RuntimeIdentity {
  database_name: string;
  database_user: string;
  is_superuser: boolean;
  bypasses_rls: boolean;
  schema_usage: boolean;
  can_execute: boolean;
  history_select: boolean;
  history_insert: boolean;
  history_update: boolean;
  history_delete: boolean;
  member_select: boolean;
  member_insert: boolean;
  member_update: boolean;
  member_delete: boolean;
}

interface BlacklistRow {
  id: string;
  tenant_id: string;
  member_id: string;
  request_id: string;
  event_type: string;
  reason: string;
  previous_status: string;
  resulting_status: string;
  recorded_at: Date;
  created_at: Date;
}

@Injectable()
export class MemberBlacklistService
  implements OnModuleInit, OnModuleDestroy
{
  private readonly pool: pg.Pool;
  private runtimeVerified = false;

  constructor(
    config: ConfigService,
    private readonly bearerTokenService: SessionBearerTokenService,
  ) {
    const databaseUrl = config.get<string>('DATABASE_URL');

    if (!databaseUrl) {
      throw new Error('DATABASE_URL is required');
    }

    this.pool = new pg.Pool({
      connectionString: databaseUrl,
      max: 5,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });

    this.pool.on('error', () => {
      console.error('Member blacklist database pool error');
    });
  }

  async onModuleInit(): Promise<void> {
    this.runtimeVerified = false;

    let result: pg.QueryResult<RuntimeIdentity>;

    try {
      result = await this.pool.query<RuntimeIdentity>(`
        SELECT
          current_database() AS database_name,
          current_user AS database_user,
          r.rolsuper AS is_superuser,
          r.rolbypassrls AS bypasses_rls,
          has_schema_privilege(
            current_user, 'security', 'USAGE'
          ) AS schema_usage,
          has_function_privilege(
            current_user,
            to_regprocedure(
              'security.change_member_blacklist(bytea,uuid,uuid,text,text,uuid)'
            ),
            'EXECUTE'
          ) AS can_execute,
          has_table_privilege(
            current_user, 'app.member_blacklist_events', 'SELECT'
          ) AS history_select,
          has_table_privilege(
            current_user, 'app.member_blacklist_events', 'INSERT'
          ) AS history_insert,
          has_table_privilege(
            current_user, 'app.member_blacklist_events', 'UPDATE'
          ) AS history_update,
          has_table_privilege(
            current_user, 'app.member_blacklist_events', 'DELETE'
          ) AS history_delete,
          has_table_privilege(
            current_user, 'app.members', 'SELECT'
          ) AS member_select,
          has_table_privilege(
            current_user, 'app.members', 'INSERT'
          ) AS member_insert,
          has_table_privilege(
            current_user, 'app.members', 'UPDATE'
          ) AS member_update,
          has_table_privilege(
            current_user, 'app.members', 'DELETE'
          ) AS member_delete
        FROM pg_roles AS r
        WHERE r.rolname = current_user
      `);
    } catch {
      throw new Error('Member blacklist database verification unavailable');
    }

    const row = result.rows[0];

    if (
      result.rows.length !== 1 ||
      !row ||
      row.database_name !== 'gympro_saas' ||
      row.database_user !== 'gympro_app' ||
      row.is_superuser !== false ||
      row.bypasses_rls !== false ||
      row.schema_usage !== true ||
      row.can_execute !== true ||
      row.history_select !== false ||
      row.history_insert !== false ||
      row.history_update !== false ||
      row.history_delete !== false ||
      row.member_select !== false ||
      row.member_insert !== false ||
      row.member_update !== false ||
      row.member_delete !== false
    ) {
      throw new Error(
        'Member blacklist requires gympro_app connected to gympro_saas with function-only member access',
      );
    }

    this.runtimeVerified = true;
  }

  async change(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    memberId: string,
    action: MemberBlacklistAction,
    body: unknown,
  ): Promise<MemberBlacklistEvent> {
    const session = request.gymproSession;

    if (
      !session ||
      !this.isUuid(session.sessionId) ||
      !this.isUuid(session.tenantId) ||
      !this.isUuid(session.membershipId) ||
      !this.isUuid(session.userId)
    ) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    if (!this.isUuid(tenantId) || !this.isUuid(memberId)) {
      throw new BadRequestException('Invalid tenant or member identifier');
    }

    if (!this.sameUuid(session.tenantId, tenantId)) {
      throw new ForbiddenException('Tenant access denied');
    }

    if (action !== 'blacklist' && action !== 'unblacklist') {
      throw new BadRequestException('Invalid blacklist action');
    }

    if (!this.runtimeVerified) {
      throw new ServiceUnavailableException('Member blacklist unavailable');
    }

    const input = this.validateBody(body);

    const tokenHash = this.bearerTokenService.hashAuthorization(
      request.headers?.authorization,
    );

    if (!Buffer.isBuffer(tokenHash) || tokenHash.length !== 32) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    let result: pg.QueryResult<BlacklistRow>;

    try {
      result = await this.pool.query<BlacklistRow>(
        `
          SELECT
            id,
            tenant_id,
            member_id,
            request_id,
            event_type,
            reason,
            previous_status,
            resulting_status,
            recorded_at,
            created_at
          FROM security.change_member_blacklist(
            $1::bytea,
            $2::uuid,
            $3::uuid,
            $4::text,
            $5::text,
            $6::uuid
          )
        `,
        [
          tokenHash,
          tenantId,
          memberId,
          action,
          input.reason,
          input.requestId,
        ],
      );
    } catch (error: unknown) {
      this.throwDatabaseError(error);
    }

    const row = result.rows[0];

    if (
      result.rows.length !== 1 ||
      !row ||
      !this.isUuid(row.id) ||
      !this.sameUuid(row.tenant_id, tenantId) ||
      !this.sameUuid(row.member_id, memberId) ||
      !this.sameUuid(row.request_id, input.requestId) ||
      row.event_type !== action ||
      row.reason !== input.reason ||
      !this.isValidTransition(
        action,
        row.previous_status,
        row.resulting_status,
      ) ||
      !this.isValidDate(row.recorded_at) ||
      !this.isValidDate(row.created_at)
    ) {
      throw new ServiceUnavailableException('Member blacklist unavailable');
    }

    return Object.freeze({
      id: row.id,
      tenantId: row.tenant_id,
      memberId: row.member_id,
      requestId: row.request_id,
      eventType: action,
      reason: row.reason,
      previousStatus: row.previous_status as MemberStatus,
      resultingStatus: row.resulting_status as MemberStatus,
      recordedAt: row.recorded_at,
      createdAt: row.created_at,
    });
  }

  async onModuleDestroy(): Promise<void> {
    this.runtimeVerified = false;
    await this.pool.end();
  }

  private validateBody(body: unknown): ChangeMemberBlacklistInput {
    if (
      typeof body !== 'object' ||
      body === null ||
      Array.isArray(body)
    ) {
      throw new BadRequestException('Invalid blacklist request');
    }

    const input = body as Record<string, unknown>;
    const allowed = new Set(['reason', 'requestId']);

    if (
      Object.keys(input).some((key) => !allowed.has(key)) ||
      typeof input.reason !== 'string' ||
      !this.isUuid(input.requestId)
    ) {
      throw new BadRequestException(
        'Only reason and a valid requestId are accepted',
      );
    }

    const reason = input.reason.trim();
    const characterCount = Array.from(reason).length;

    if (
      characterCount < 2 ||
      characterCount > 500 ||
      !/\S/u.test(reason)
    ) {
      throw new BadRequestException(
        'A blacklist reason of 2 to 500 characters is required',
      );
    }

    return Object.freeze({
      reason,
      requestId: input.requestId,
    });
  }

  private isValidTransition(
    action: MemberBlacklistAction,
    previous: string,
    resulting: string,
  ): boolean {
    const ordinaryStatuses = ['pending', 'active', 'inactive'];

    if (action === 'blacklist') {
      return ordinaryStatuses.includes(previous) &&
        resulting === 'blacklisted';
    }

    return previous === 'blacklisted' &&
      ordinaryStatuses.includes(resulting);
  }

  private isUuid(value: unknown): value is string {
    return typeof value === 'string' && UUID_PATTERN.test(value);
  }

  private sameUuid(value: unknown, expected: string): boolean {
    return this.isUuid(value) &&
      value.toLowerCase() === expected.toLowerCase();
  }

  private isValidDate(value: unknown): value is Date {
    return value instanceof Date && Number.isFinite(value.getTime());
  }

  private throwDatabaseError(error: unknown): never {
    const databaseError =
      typeof error === 'object' && error !== null
        ? error as { code?: unknown; message?: unknown }
        : {};

    if (
      databaseError.code === '28000' &&
      databaseError.message === 'Invalid or expired session'
    ) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    if (
      databaseError.code === '42501' &&
      (
        databaseError.message === 'Tenant access denied' ||
        databaseError.message === 'Member access denied' ||
        databaseError.message === 'Member blacklist permission denied'
      )
    ) {
      throw new ForbiddenException('Member blacklist access denied');
    }

    if (databaseError.code === '22023') {
      throw new BadRequestException('Invalid member blacklist request');
    }

    throw new ServiceUnavailableException('Member blacklist unavailable');
  }
}