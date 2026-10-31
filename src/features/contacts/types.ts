import type { MembershipRole } from '../../lib/types';

export const ADDRESS_KEYS = ['postal_code', 'street', 'number', 'district', 'complement', 'city', 'state'] as const;
export type AddressKey = typeof ADDRESS_KEYS[number];

export interface ContactAddress {
  postal_code: string | null;
  street: string | null;
  number: string | null;
  district: string | null;
  complement: string | null;
  city: string | null;
  state: string | null;
}

export type ContactEntity = 'client' | 'supplier';
export type PersonType = 'individual' | 'business';

export interface ContactBaseDto {
  id: string;
  organization_id: string;
  name: string;
  email: string | null;
  phone: string | null;
  notes: string | null;
  person_type: PersonType;
  tax_id: string | null;
  address: ContactAddress | null;
  archived_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface ClientDto extends ContactBaseDto {
  birth_date: string | null;
  order_count?: string;
  open_order_count?: string;
}

export interface SupplierDto extends ContactBaseDto {
  website: string | null;
  material_count: string;
  current_stock_cost: string | null;
  stocks_by_unit: string;
}

export type ContactDto = ClientDto | SupplierDto;

export interface ClientContactData {
  name: string;
  email: string | null;
  phone: string | null;
  notes: string | null;
  person_type: PersonType;
  tax_id: string | null;
  birth_date: string | null;
  address: ContactAddress | null;
}

export interface SupplierContactData {
  name: string;
  email: string | null;
  phone: string | null;
  notes: string | null;
  person_type: PersonType;
  tax_id: string | null;
  address: ContactAddress | null;
  website: string | null;
}

export type ContactData = ClientContactData | SupplierContactData;

export interface ContactFormValues {
  name: string;
  personType: PersonType;
  taxId: string;
  birthDate: string;
  phone: string;
  email: string;
  address: Record<AddressKey, string>;
  website: string;
  notes: string;
}

export interface ContactUpsertInput {
  organizationId: string;
  entity: ContactEntity;
  data: ContactData;
  contactId: string | null;
  idempotencyKey: string;
}

export interface ContactUpsertResult {
  contact_id: string;
  entity: ContactEntity;
  created: boolean;
  updated_at: string;
}

export interface ContactArchiveInput {
  organizationId: string;
  entity: ContactEntity;
  contactId: string;
  archived: boolean;
  reason: string;
}

export interface ContactArchiveResult {
  contact_id: string;
  entity: ContactEntity;
  archived: boolean;
  archived_at: string | null;
  event_id: string | null;
}

export interface ContactImportInput {
  organizationId: string;
  entity: ContactEntity;
  rows: ContactData[];
  batchKey: string;
}

export interface ContactImportResult {
  batch_key: string;
  created: string;
  updated: string;
  skipped: string;
}

export const canManageContacts = (role: MembershipRole | null): boolean => role === 'owner' || role === 'admin' || role === 'finance';
export const canReadContacts = (role: MembershipRole | null): boolean => role !== null;

export function emptyAddress(): Record<AddressKey, string> {
  return {
    postal_code: '',
    street: '',
    number: '',
    district: '',
    complement: '',
    city: '',
    state: '',
  };
}

export function isSupplier(contact: ContactDto): contact is SupplierDto {
  return 'website' in contact;
}

export function addressFromDto(address: ContactAddress | null | undefined): Record<AddressKey, string> {
  return ADDRESS_KEYS.reduce((result, key) => {
    result[key] = address?.[key] ?? '';
    return result;
  }, emptyAddress());
}
