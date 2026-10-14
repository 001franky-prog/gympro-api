
import {
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';

import type { TenantPrincipal } from './tenant-principal.js';

@Injectable()
export class TenantAuthorizationService {

  async verifyTenantMembership(
    userId: string,
    tenantId: string,
  ): Promise<TenantPrincipal> {

    // Authentication and secure membership lookup
    // are not implemented yet.
    // Never trust caller-supplied identity values.

    void userId;
    void tenantId;

    throw new UnauthorizedException(
      'Tenant authentication is required',
    );
  }
}
