import { CanActivate, ExecutionContext, HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { LoginAttemptLimiter } from './login-attempt-limiter.js';

@Injectable()
export class LoginRateLimitGuard implements CanActivate {
  private readonly limiter = new LoginAttemptLimiter();
  canActivate(context: ExecutionContext): boolean {
    const http = context.switchToHttp();
    const request = http.getRequest<{socket?: {remoteAddress?: string}; body?: unknown}>();
    // Direct socket peer only. Client forwarding headers never select a rate-limit identity.
    const peer = request.socket?.remoteAddress || 'unknown-peer';
    const retry = this.limiter.consume(peer, request.body);
    if (retry) {
      http.getResponse<{setHeader(name: string, value: string): void}>().setHeader('Retry-After', String(retry));
      throw new HttpException('Too many login attempts. Try again later.', HttpStatus.TOO_MANY_REQUESTS);
    }
    return true;
  }
}
