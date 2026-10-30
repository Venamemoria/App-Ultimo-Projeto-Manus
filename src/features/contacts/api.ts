import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, supabaseConfigError } from '../../lib/supabase';
import type { ClientDto, ContactArchiveInput, ContactArchiveResult, ContactData, ContactEntity, ContactImportInput, ContactImportResult, ContactDto, ContactUpsertInput, ContactUpsertResult, SupplierDto } from './types';

const PAGE_SIZE = 500;

export const contactsQueryKeys = {
  all: (organizationId: string, entity: ContactEntity) => ['contacts', entity, organizationId] as const,
};

function getClient() {
  if (!supabase) throw new Error(supabaseConfigError ?? 'O serviço de dados está indisponível neste ambiente.');
  return supabase;
}

function rows<T>(data: unknown): T[] {
  if (Array.isArray(data)) return data as T[];
  if (data && typeof data === 'object') return [data as T];
  return [];
}

function databaseError(error: { code?: string | null; message?: string | null } | null, fallback: string): Error {
  if (!error) return new Error(fallback);
  if (error.code === '42501') return new Error('Seu papel não permite alterar cadastros nesta organização.');
  if (error.code === '23505') return new Error('Já existe um cadastro com este CPF/CNPJ ou esta tentativa foi repetida com outros dados. Mantenha o formulário sem alterações para tentar novamente.');
  if (error.code === '23503') return new Error('O cadastro ou a organização não está disponível nesta organização.');
  if (['22003', '22023', '22P02', '23514'].includes(error.code ?? '')) return new Error('Confira os campos do cadastro, endereço e formato de CPF/CNPJ.');
  return new Error(`${fallback} A operação pode ter sido confirmada; tente novamente sem alterar os dados para verificar o mesmo resultado.`);
}

export function userFacingContactError(error: unknown, fallback = 'Não foi possível concluir esta ação agora.') {
  return error instanceof Error && error.message ? error.message : fallback;
}

async function fetchPaged<T extends { id: string }>(view: string, organizationId: string, fallback: string): Promise<T[]> {
  const result: T[] = [];
  let cursor: string | null = null;
  while (true) {
    let query = getClient().from(view).select('*', { count: 'exact' }).eq('organization_id', organizationId).order('id', { ascending: true }).limit(PAGE_SIZE);
    if (cursor) query = query.gt('id', cursor);
    const { data, error, count } = await query;
    if (error) throw databaseError(error, fallback);
    const batch = (data ?? []) as unknown as T[];
    result.push(...batch);
    if (!batch.length || (count !== null && batch.length >= count)) return result;
    const next = batch[batch.length - 1]?.id;
    if (!next || next === cursor) throw new Error(`${fallback} A paginação retornou um cursor inválido; nenhuma lista parcial foi apresentada.`);
    cursor = next;
  }
}

export async function fetchContacts(entity: ContactEntity, organizationId: string): Promise<ContactDto[]> {
  if (entity === 'client') return fetchPaged<ClientDto>('vm_clients_read', organizationId, 'Não foi possível carregar os clientes.');
  return fetchPaged<SupplierDto>('vm_suppliers_read', organizationId, 'Não foi possível carregar os fornecedores.');
}

async function callRpc<T>(name: string, params: Record<string, unknown>, fallback: string): Promise<T> {
  const { data, error } = await getClient().rpc(name, params);
  if (error) throw databaseError(error, fallback);
  const result = rows<T>(data)[0];
  if (!result) throw new Error(fallback);
  return result;
}

export async function upsertContact(input: ContactUpsertInput): Promise<ContactUpsertResult> {
  return callRpc<ContactUpsertResult>('vm_upsert_contact', {
    p_organization_id: input.organizationId,
    p_entity: input.entity,
    p_data: input.data,
    p_contact_id: input.contactId,
    p_idempotency_key: input.idempotencyKey,
  }, 'Não foi possível salvar o cadastro.');
}

export async function archiveContact(input: ContactArchiveInput): Promise<ContactArchiveResult> {
  return callRpc<ContactArchiveResult>('vm_archive_contact', {
    p_organization_id: input.organizationId,
    p_entity: input.entity,
    p_contact_id: input.contactId,
    p_archived: input.archived,
    p_reason: input.reason,
  }, input.archived ? 'Não foi possível arquivar o cadastro.' : 'Não foi possível recuperar o cadastro.');
}

export async function importContacts(input: ContactImportInput): Promise<ContactImportResult> {
  return callRpc<ContactImportResult>('vm_import_contacts', {
    p_organization_id: input.organizationId,
    p_entity: input.entity,
    p_rows: input.rows,
    p_key: input.batchKey,
  }, 'Não foi possível importar os cadastros. A operação pode ter sido confirmada; tente novamente com o mesmo arquivo.');
}

export function useContactsQuery(entity: ContactEntity, organizationId: string | null) {
  return useQuery({
    queryKey: organizationId ? contactsQueryKeys.all(organizationId, entity) : ['contacts', entity, 'no-organization'],
    queryFn: () => fetchContacts(entity, organizationId!),
    enabled: Boolean(organizationId),
    refetchOnWindowFocus: entity === 'supplier' ? 'always' : true,
    refetchInterval: entity === 'supplier' ? 30_000 : false,
  });
}

function useContactMutation<TInput, TResult>(entity: ContactEntity, organizationId: string | null, mutationFn: (input: TInput) => Promise<TResult>) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn,
    onSuccess: async () => {
      if (organizationId) await queryClient.invalidateQueries({ queryKey: contactsQueryKeys.all(organizationId, entity) });
    },
  });
}

export function useUpsertContactMutation(entity: ContactEntity, organizationId: string | null) {
  return useContactMutation<ContactUpsertInput, ContactUpsertResult>(entity, organizationId, upsertContact);
}

export function useArchiveContactMutation(entity: ContactEntity, organizationId: string | null) {
  return useContactMutation<ContactArchiveInput, ContactArchiveResult>(entity, organizationId, archiveContact);
}

export function useImportContactsMutation(entity: ContactEntity, organizationId: string | null) {
  return useContactMutation<ContactImportInput, ContactImportResult>(entity, organizationId, importContacts);
}

export type { ContactData };
