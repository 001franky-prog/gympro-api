
import { config } from 'dotenv';
import { defineConfig } from 'prisma/config';

config({
  path: '.env.introspect',
  override: true,
  quiet: true,
});

export default defineConfig({
  schema: 'prisma/schema.prisma',

  datasource: {
    url: process.env.INTROSPECT_DATABASE_URL ?? '',
  },
});
