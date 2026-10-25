import { Injectable, OnModuleInit } from '@nestjs/common';
import { isSessionPersistenceEnabled } from './session-security-policy.js';

/** Startup configuration gate; identity/privilege checks stay in existing database services. */
@Injectable()
export class ProductionAuthPolicyService implements OnModuleInit {
  onModuleInit(): void {
    if (process.env.NODE_ENV === 'production' && !isSessionPersistenceEnabled()) {
      throw new Error('Production authentication requires persistent session mode and no development session overrides');
    }
  }
}
