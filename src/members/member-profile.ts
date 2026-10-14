
/**
 * ========================================================
 * GYM PRO SAAS
 * PHASE B - STEP B1
 *
 * MEMBER PROFILE DOMAIN MODEL
 *
 * Responsibilities:
 * - Define basic gym member information.
 * - Validate registration input.
 * - Normalize email, phone and name.
 * - Define member account statuses.
 *
 * This module does not access PostgreSQL.
 * It does not authorize a tenant or branch.
 * It does not create memberships or payments.
 * ========================================================
 */

export const MEMBER_STATUSES = [
  'pending',
  'active',
  'inactive',
  'blacklisted',
] as const;

export type MemberStatus =
  (typeof MEMBER_STATUSES)[number];

export interface CreateMemberInput {
  readonly fullName: string;
  readonly phone?: string | null;
  readonly email?: string | null;
}

export interface NormalizedMemberInput {
  readonly fullName: string;
  readonly phone: string | null;
  readonly email: string | null;
}

export interface MemberProfile {
  readonly id: string;
  readonly tenantId: string;
  readonly branchId: string | null;
  readonly memberNumber: string;
  readonly fullName: string;
  readonly phone: string | null;
  readonly email: string | null;
  readonly status: MemberStatus;
  readonly createdAt: Date;
  readonly updatedAt: Date;
}

export class MemberValidationError extends Error {
  constructor(message: string) {
    super(message);

    this.name = 'MemberValidationError';
  }
}

const EMAIL_PATTERN =
  /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const PHONE_PATTERN =
  /^\+?[0-9][0-9\s()-]*$/;

/**
 * Validate and normalize new member information.
 *
 * TenantId and branchId must come from the
 * authenticated authorization context,
 * not from untrusted client-supplied ownership.
 *
 * The backend will generate memberNumber.
 */
export function validateCreateMemberInput(
  input: unknown,
): NormalizedMemberInput {
  if (
    typeof input !== 'object' ||
    input === null ||
    Array.isArray(input)
  ) {
    throw new MemberValidationError(
      'Member registration data is required',
    );
  }

  const record =
    input as Record<string, unknown>;

  if (typeof record.fullName !== 'string') {
    throw new MemberValidationError(
      'Member full name is required',
    );
  }

  const fullName = record.fullName.trim();

  if (
    fullName.length < 2 ||
    fullName.length > 150
  ) {
    throw new MemberValidationError(
      'Member name must contain 2 to 150 characters',
    );
  }

  if (
    record.phone !== undefined &&
    record.phone !== null &&
    typeof record.phone !== 'string'
  ) {
    throw new MemberValidationError(
      'Phone number must be text',
    );
  }

  if (
    record.email !== undefined &&
    record.email !== null &&
    typeof record.email !== 'string'
  ) {
    throw new MemberValidationError(
      'Email address must be text',
    );
  }

  const phone =
    typeof record.phone === 'string'
      ? record.phone.trim()
      : '';

  const email =
    typeof record.email === 'string'
      ? record.email.trim().toLowerCase()
      : '';

  if (!phone && !email) {
    throw new MemberValidationError(
      'Phone number or email address is required',
    );
  }

  if (phone) {
    if (
      phone.length < 7 ||
      phone.length > 20 ||
      !PHONE_PATTERN.test(phone)
    ) {
      throw new MemberValidationError(
        'Invalid phone number',
      );
    }

    const digitCount =
      phone.replace(/\D/g, '').length;

    if (
      digitCount < 7 ||
      digitCount > 15
    ) {
      throw new MemberValidationError(
        'Phone number must contain 7 to 15 digits',
      );
    }
  }

  if (email) {
    if (
      email.length > 254 ||
      !EMAIL_PATTERN.test(email)
    ) {
      throw new MemberValidationError(
        'Invalid email address',
      );
    }
  }

  return Object.freeze({
    fullName,
    phone: phone || null,
    email: email || null,
  });
}

/**
 * Validate a member status string.
 */
export function isMemberStatus(
  value: unknown,
): value is MemberStatus {
  return (
    typeof value === 'string' &&
    MEMBER_STATUSES.some(
      (status) => status === value,
    )
  );
}
