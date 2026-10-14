
import {
  describe,
  expect,
  it,
} from 'vitest';

import {
  isMemberStatus,
  MemberValidationError,
  validateCreateMemberInput,
} from './member-profile.js';

describe('Gym Pro Member Profile Domain', () => {
  it('M01: accepts a valid member', () => {
    const result = validateCreateMemberInput({
      fullName: 'U Aung Aung',
      phone: '09912345678',
      email: 'aung@example.com',
    });

    expect(result.fullName).toBe('U Aung Aung');
    expect(result.phone).toBe('09912345678');
    expect(result.email).toBe('aung@example.com');
  });

  it('M02: normalizes name and email', () => {
    const result = validateCreateMemberInput({
      fullName: '  Daw Mya Mya  ',
      email: '  MYA@EXAMPLE.COM  ',
    });

    expect(result.fullName).toBe('Daw Mya Mya');
    expect(result.email).toBe('mya@example.com');
  });

  it('M03: accepts phone without email', () => {
    const result = validateCreateMemberInput({
      fullName: 'U Hla Hla',
      phone: '+959123456789',
    });

    expect(result.email).toBeNull();
    expect(result.phone).toBe('+959123456789');
  });

  it('M04: accepts email without phone', () => {
    const result = validateCreateMemberInput({
      fullName: 'U Kyaw Kyaw',
      email: 'kyaw@example.com',
    });

    expect(result.phone).toBeNull();
  });

  it('M05: rejects missing full name', () => {
    expect(() =>
      validateCreateMemberInput({
        phone: '09912345678',
      }),
    ).toThrow(MemberValidationError);
  });

  it('M06: rejects empty contact details', () => {
    expect(() =>
      validateCreateMemberInput({
        fullName: 'U Test',
        phone: '',
        email: '',
      }),
    ).toThrow(MemberValidationError);
  });

  it('M07: rejects invalid email', () => {
    expect(() =>
      validateCreateMemberInput({
        fullName: 'U Test',
        email: 'invalid-email',
      }),
    ).toThrow('Invalid email address');
  });

  it('M08: rejects invalid phone', () => {
    expect(() =>
      validateCreateMemberInput({
        fullName: 'U Test',
        phone: 'abc123',
      }),
    ).toThrow('Invalid phone number');
  });

  it('M09: rejects oversized member name', () => {
    expect(() =>
      validateCreateMemberInput({
        fullName: 'A'.repeat(151),
        email: 'test@example.com',
      }),
    ).toThrow(MemberValidationError);
  });

  it('M10: recognizes valid member statuses', () => {
    expect(isMemberStatus('pending')).toBe(true);
    expect(isMemberStatus('active')).toBe(true);
    expect(isMemberStatus('inactive')).toBe(true);
    expect(isMemberStatus('blacklisted')).toBe(true);
  });

  it('M11: rejects unsupported statuses', () => {
    expect(isMemberStatus('deleted')).toBe(false);
    expect(isMemberStatus('expired')).toBe(false);
    expect(isMemberStatus(null)).toBe(false);
  });

  it('M12: rejects invalid input structures', () => {
    expect(() =>
      validateCreateMemberInput(null),
    ).toThrow(MemberValidationError);

    expect(() =>
      validateCreateMemberInput([]),
    ).toThrow(MemberValidationError);
  });

  it('M13: rejects a nonstring phone value', () => {
    expect(() =>
      validateCreateMemberInput({
        fullName: 'U Test',
        phone: 912345678,
      }),
    ).toThrow(MemberValidationError);
  });

  it('M14: rejects a nonstring email value', () => {
    expect(() =>
      validateCreateMemberInput({
        fullName: 'U Test',
        email: 12345,
      }),
    ).toThrow(MemberValidationError);
  });

  it('M15: accepts Myanmar-language member names', () => {
    const result = validateCreateMemberInput({
      fullName: 'ဦးအောင်အောင်',
      phone: '09912345678',
    });

    expect(result.fullName).toBe('ဦးအောင်အောင်');
  });
});
