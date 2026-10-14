
import {
  afterEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  isSessionPersistenceEnabled,
  SESSION_SECURITY_POLICY,
} from './session-security-policy.js';

describe(
  'Gym Pro Development Session Activation Policy',
  () => {
    afterEach(() => {
      vi.unstubAllEnvs();
    });

    it('D01: baseline persistence remains disabled', () => {
      expect(
        SESSION_SECURITY_POLICY.persistenceEnabled,
      ).toBe(false);
    });

    it('D02: production cannot enable development writes', () => {
      vi.stubEnv('NODE_ENV', 'production');
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_WRITES',
        'enabled',
      );
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_CONFIRM',
        'I_UNDERSTAND_THE_RISK',
      );

      expect(
        isSessionPersistenceEnabled(),
      ).toBe(false);
    });

    it('D03: test environment cannot enable writes', () => {
      vi.stubEnv('NODE_ENV', 'test');
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_WRITES',
        'enabled',
      );
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_CONFIRM',
        'I_UNDERSTAND_THE_RISK',
      );

      expect(
        isSessionPersistenceEnabled(),
      ).toBe(false);
    });

    it('D04: development without flags is disabled', () => {
      vi.stubEnv('NODE_ENV', 'development');
      vi.stubEnv('GYMPRO_DEV_SESSION_WRITES', '');
      vi.stubEnv('GYMPRO_DEV_SESSION_CONFIRM', '');

      expect(
        isSessionPersistenceEnabled(),
      ).toBe(false);
    });

    it('D05: one activation flag is insufficient', () => {
      vi.stubEnv('NODE_ENV', 'development');
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_WRITES',
        'enabled',
      );
      vi.stubEnv('GYMPRO_DEV_SESSION_CONFIRM', '');

      expect(
        isSessionPersistenceEnabled(),
      ).toBe(false);
    });

    it('D06: incorrect confirmation is denied', () => {
      vi.stubEnv('NODE_ENV', 'development');
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_WRITES',
        'enabled',
      );
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_CONFIRM',
        'wrong-value',
      );

      expect(
        isSessionPersistenceEnabled(),
      ).toBe(false);
    });

    it('D07: explicit development opt-in is recognized', () => {
      vi.stubEnv('NODE_ENV', 'development');
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_WRITES',
        'enabled',
      );
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_CONFIRM',
        'I_UNDERSTAND_THE_RISK',
      );

      expect(
        isSessionPersistenceEnabled(),
      ).toBe(true);
    });

    it('D08: activation is disabled without development mode', () => {
      vi.stubEnv('NODE_ENV', '');
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_WRITES',
        'enabled',
      );
      vi.stubEnv(
        'GYMPRO_DEV_SESSION_CONFIRM',
        'I_UNDERSTAND_THE_RISK',
      );

      expect(
        isSessionPersistenceEnabled(),
      ).toBe(false);
    });
  },
);
