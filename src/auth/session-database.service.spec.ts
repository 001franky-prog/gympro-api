
import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  HttpStatus,
  ServiceUnavailableException,
} from '@nestjs/common';

import {
  SessionDatabaseService,
} from './session-database.service.js';

/**
 * Gym Pro SaaS
 * Session Database Operation — Security Unit Tests
 *
 * Purpose:
 * Verify that createTenantSession() remains
 * fail-closed and cannot create sessions.
 *
 * No PostgreSQL connections are opened.
 * No database records or permissions are modified.
 */

describe('Gym Pro SessionDatabaseService.createTenantSession', () => {
  const membershipId =
    '33333333-3333-4333-8333-333333333333';

  const query = vi.fn();

  let service: SessionDatabaseService;

  beforeEach(() => {
    vi.resetAllMocks();

    /**
     * Create an instance using the class prototype.
     *
     * This avoids running the constructor and
     * creating a real PostgreSQL connection pool.
     */
    service = Object.create(
      SessionDatabaseService.prototype,
    ) as SessionDatabaseService;

    /**
     * Attach a mocked pool for detecting accidental
     * database access in the current implementation.
     *
     * Private is a TypeScript compile-time modifier,
     * so the mock is attached using a test-only cast.
     */
    Object.assign(service, {
      pool: {
        query,
      },
    });
  });

  const expectDisabled = async (
    testMembershipId: string,
    testTokenHash: Buffer,
  ): Promise<void> => {
    await expect(
      service.createTenantSession(
        testMembershipId,
        testTokenHash,
      ),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    expect(query).not.toHaveBeenCalled();
  };

  it('D01: rejects valid membership and digest', async () => {
    await expectDisabled(
      membershipId,
      Buffer.alloc(32, 0xab),
    );
  });

  it('D02: rejects malformed membership UUID', async () => {
    await expectDisabled(
      'not-a-uuid',
      Buffer.alloc(32),
    );
  });

  it('D03: rejects empty membership UUID', async () => {
    await expectDisabled(
      '',
      Buffer.alloc(32),
    );
  });

  it('D04: rejects 16-byte digest', async () => {
    await expectDisabled(
      membershipId,
      Buffer.alloc(16),
    );
  });

  it('D05: rejects 64-byte digest', async () => {
    await expectDisabled(
      membershipId,
      Buffer.alloc(64),
    );
  });

  it('D06: rejects string instead of Buffer', async () => {
    await expectDisabled(
      membershipId,
      'invalid-digest' as unknown as Buffer,
    );
  });

  it('D07: rejects null digest', async () => {
    await expectDisabled(
      membershipId,
      null as unknown as Buffer,
    );
  });

  it('D08: rejects uppercase UUID and valid digest', async () => {
    await expectDisabled(
      membershipId.toUpperCase(),
      Buffer.alloc(32),
    );
  });

  it('D09: rejects repeated session requests', async () => {
    for (let i = 0; i < 5; i++) {
      await expectDisabled(
        membershipId,
        Buffer.alloc(32, i),
      );
    }

    expect(query).not.toHaveBeenCalled();
  });

  it('D10: returns HTTP 503 without executing SQL', async () => {
    try {
      await service.createTenantSession(
        membershipId,
        Buffer.alloc(32),
      );

      throw new Error(
        'SECURITY FAILURE: Session operation succeeded',
      );
    } catch (error) {
      expect(error).toBeInstanceOf(
        ServiceUnavailableException,
      );

      const exception =
        error as ServiceUnavailableException;

      expect(exception.getStatus()).toBe(
        HttpStatus.SERVICE_UNAVAILABLE,
      );

      expect(exception.getResponse()).toMatchObject({
        message: 'Session database writes are not enabled',
      });
    }

    expect(query).not.toHaveBeenCalled();
  });
});
