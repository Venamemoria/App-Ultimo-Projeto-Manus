import type { MembershipRole } from './types';

/** Financial access is also enforced by PostgreSQL, not by UI hiding alone. */
export function canViewFinance(role: MembershipRole | null): boolean {
  return role === 'owner' || role === 'admin' || role === 'finance';
}
