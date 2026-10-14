
import {
  describe,
  it,
  expect,
  beforeEach,
  vi,
} from 'vitest';

import { HttpStatus } from '@nestjs/common';
import { AuthenticationService } from './authentication.service.js';
import { AuthDatabaseService } from './auth-database.service.js';
import { PasswordService } from './password.service.js';

describe('Gym Pro AuthenticationService', () => {
  let service: AuthenticationService;

  const testHash = 'test-hash';
  const dummyHash = 'dummy-hash';

  const findUserCredentials = vi.fn();
  const hashPassword = vi.fn();
  const verifyPassword = vi.fn();

  const expectUnauthorized = async (
    operation: Promise<unknown>,
  ) => {
    try {
      await operation;
      throw new Error('Expected authentication rejection');
    } catch (error) {
      expect(error).toMatchObject({
        status: HttpStatus.UNAUTHORIZED,
        response: {
          message: 'Invalid email or password',
        },
      });
    }
  };

  beforeEach(async () => {
    vi.clearAllMocks();

    findUserCredentials.mockResolvedValue(null);
    hashPassword.mockResolvedValue(dummyHash);
    verifyPassword.mockResolvedValue(false);

    const authDatabase = {
      findUserCredentials,
    } as unknown as AuthDatabaseService;

    const passwordService = {
      hashPassword,
      verifyPassword,
    } as unknown as PasswordService;

    service = new AuthenticationService(
      authDatabase,
      passwordService,
    );

    await service.onModuleInit();
  });

  it('A01: rejects an unknown user', async () => {
    await expectUnauthorized(
      service.validateCredentials(
        'unknown@example.com',
        'TestPassword123!',
      ),
    );
    expect(verifyPassword).toHaveBeenCalledWith(
      dummyHash,
      'TestPassword123!',
    );
  });

  it('A02: rejects an incorrect password', async () => {
    findUserCredentials.mockResolvedValue({
      user_id: 'user-001',
      account_status: 'active',
      password_hash: testHash,
    });

    await expectUnauthorized(
      service.validateCredentials(
        'admin@example.com',
        'IncorrectPassword!',
      ),
    );
  });

  it('A03: rejects a pending user', async () => {
    findUserCredentials.mockResolvedValue({
      user_id: 'user-002',
      account_status: 'pending',
      password_hash: testHash,
    });

    verifyPassword.mockResolvedValue(true);

    await expectUnauthorized(
      service.validateCredentials(
        'pending@example.com',
        'TestPassword123!',
      ),
    );
  });

  it('A04: rejects a user without a password', async () => {
    findUserCredentials.mockResolvedValue({
      user_id: 'user-003',
      account_status: 'active',
      password_hash: null,
    });

    await expectUnauthorized(
      service.validateCredentials(
        'nopassword@example.com',
        'TestPassword123!',
      ),
    );

    expect(verifyPassword).toHaveBeenCalledWith(
      dummyHash,
      'TestPassword123!',
    );
  });

  it('A05: authenticates an active user', async () => {
    findUserCredentials.mockResolvedValue({
      user_id: 'user-004',
      account_status: 'active',
      password_hash: testHash,
    });

    verifyPassword.mockResolvedValue(true);

    const result = await service.validateCredentials(
      'ACTIVE@EXAMPLE.COM',
      'CorrectPassword123!',
    );

    expect(result).toEqual({
      userId: 'user-004',
    });

    expect(findUserCredentials).toHaveBeenCalledWith(
      'active@example.com',
    );

    expect(result).not.toHaveProperty('password_hash');
  });

  it('A06: rejects empty credentials', async () => {
    await expectUnauthorized(
      service.validateCredentials('', ''),
    );

    expect(findUserCredentials).not.toHaveBeenCalled();
  });
});
