
import { defineConfig } from 'vitest/config';
import tsconfigPaths from 'vite-tsconfig-paths';
import { config as loadEnv } from 'dotenv';

/**
 * Gym Pro SaaS
 * Vitest configuration
 *
 * Loads the dedicated introspection configuration
 * for integration tests.
 *
 * Existing process environment variables take
 * precedence over values in .env.introspect.
 */

// Load ordinary development configuration first.
loadEnv({
  path: '.env',
  override: false,
  quiet: true,
});

// Load dedicated read-only introspection credentials.
loadEnv({
  path: '.env.introspect',
  override: false,
  quiet: true,
});

export default defineConfig({
  plugins: [tsconfigPaths()],

  test: {
    globals: true,
    root: './',
    include: ['**/*.spec.ts'],
  },
});
