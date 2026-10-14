import { SetMetadata } from '@nestjs/common';

/**
 * Gym Pro SaaS
 * Required permission metadata for protected routes.
 *
 * Example:
 * @RequirePermission('gym.members.read')
 *
 * The PermissionGuard must enforce this metadata.
 */
export const REQUIRED_PERMISSION_KEY =
  'gympro.required_permission';

export function RequirePermission(
  permissionCode: string,
): MethodDecorator & ClassDecorator {
  return SetMetadata(
    REQUIRED_PERMISSION_KEY,
    permissionCode,
  );
}