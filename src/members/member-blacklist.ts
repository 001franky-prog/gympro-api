import type {
  MemberStatus,
} from './member-profile.js';

export const MEMBER_BLACKLIST_ACTIONS = [
  'blacklist',
  'unblacklist',
] as const;

export type MemberBlacklistAction =
  (typeof MEMBER_BLACKLIST_ACTIONS)[number];

export interface MemberBlacklistEvent {
  readonly id: string;

  readonly tenantId: string;
  readonly memberId: string;
  readonly requestId: string;

  readonly eventType: MemberBlacklistAction;
  readonly reason: string;

  readonly previousStatus: MemberStatus;
  readonly resultingStatus: MemberStatus;

  readonly recordedAt: Date;
  readonly createdAt: Date;
}

export interface ChangeMemberBlacklistInput {
  /**
   * Required reason, trimmed before storage.
   * Must contain 2–500 characters after trimming.
   */
  readonly reason: string;

  /**
   * Generate once per intended action.
   * Reuse the UUID, action, and reason when retrying.
   */
  readonly requestId: string;
}