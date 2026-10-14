
import { Controller, Get } from '@nestjs/common';

import { AppService } from './app.service.js';

/**
 * Gym Pro SaaS — Application Controller
 *
 * Public routes:
 * GET /
 *
 * Development-only configuration and database
 * diagnostic endpoints have been removed.
 *
 * Database connectivity continues to be
 * managed by PrismaService independently.
 */
@Controller()
export class AppController {
  constructor(
    private readonly appService: AppService,
  ) {}

  @Get()
  getHello(): string {
    return this.appService.getHello();
  }
}
