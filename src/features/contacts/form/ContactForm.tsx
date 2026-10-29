import { useEffect, useRef, useState, type FormEvent } from 'react';
import { Alert, Button, Field, Input, Modal, Select, Textarea } from '../../../components/ui';
import { useSession } from '../../../app/AuthProvider';
import { useUpsertContactMutation, userFacingContactError } from '../api';
import { normalizeTaxId } from '../csv';
import { ADDRESS_KEYS, addressFromDto, emptyAddress, type AddressKey, type ClientContactData, type ContactAddress, type ContactDto, type ContactEntity, type ContactFormValues, type PersonType, type SupplierContactData } from '../types';

interface ContactFormProps {
  open: boolean;
  entity: ContactEntity;
  organizationId: string;
  contact: ContactDto | null;
  onClose: () => void;
  onSaved: () => void;
}

function makeNonce(): string {
  return globalThis.crypto.randomUUID();
}

function valuesFromContact(entity: ContactEntity, contact: ContactDto | null): ContactFormValues {
  const isClient = entity === 'client';
  return {
    name: contact?.name ?? '',
    personType: contact?.person_type ?? 'individual',
    taxId: contact?.tax_id ?? '',
    birthDate: isClient && contact && 'birth_date' in contact ? contact.birth_date ?? '' : '',
    phone: contact?.phone ?? '',
    email: contact?.email ?? '',
    address: addressFromDto(contact?.address),
    website: !isClient && contact && 'website' in contact ? contact.website ?? '' : '',
    notes: contact?.notes ?? '',
  };
}

function validateEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function validateDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split('-').map(Number);
  const date = new Date(year, month - 1, day);
  const today = new Date();
  const todayCivil = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day && date <= todayCivil;
}

function addressPayload(values: ContactFormValues): ContactAddress {
  return ADDRESS_KEYS.reduce((result, key) => {
    const cleanValue = values.address[key].trim();
    result[key] = cleanValue ? (key === 'state' ? cleanValue.toUpperCase() : cleanValue) : null;
    return result;
  }, {} as ContactAddress);
}

function buildPayload(entity: ContactEntity, values: ContactFormValues): ClientContactData | SupplierContactData {
  const common = {
    name: values.name.trim(),
    email: values.email.trim().toLocaleLowerCase('pt-BR') || null,
    phone: values.phone.trim() || null,
    notes: values.notes.trim() || null,
    person_type: values.personType,
    tax_id: normalizeTaxId(values.taxId) || null,
    address: addressPayload(values),
  };
  if (entity === 'client') {
    return {
      ...common,
      birth_date: values.personType === 'individual' ? values.birthDate.trim() || null : null,
    };
  }
  return { ...common, website: values.website.trim() || null };
}

function validateValues(entity: ContactEntity, values: ContactFormValues): string | null {
  const name = values.name.trim();
  if (!name) return 'Informe o nome do cadastro.';
  if (name.length > 200) return 'O nome pode ter no máximo 200 caracteres.';

  const taxId = normalizeTaxId(values.taxId);
  if (taxId && !/^(?:\d{11}|[A-Z0-9]{12}\d{2})$/.test(taxId)) return 'CPF deve ter 11 números; CNPJ deve ter 12 letras/números e dois dígitos finais, sem máscara.';
  if (values.email.trim() && !validateEmail(values.email.trim())) return 'Informe um e-mail válido.';
  if (values.personType !== 'individual' && values.personType !== 'business') return 'Escolha pessoa física ou jurídica.';
  if (entity === 'client' && values.personType === 'individual' && values.birthDate.trim() && !validateDate(values.birthDate.trim())) return 'Informe uma data de nascimento válida, no formato AAAA-MM-DD, que não seja futura.';
  if (entity === 'supplier' && values.website.trim() && !/^https?:\/\/[^\s]+$/i.test(values.website.trim())) return 'O site deve começar com http:// ou https:// e não pode conter espaços.';
  if (values.address.state.trim() && values.address.state.trim().length !== 2) return 'A UF deve ter exatamente duas letras.';
  return null;
}

export function ContactForm({ open, entity, organizationId, contact, onClose, onSaved }: ContactFormProps) {
  const { currentMembershipRole } = useSession();
  const mutation = useUpsertContactMutation(entity, organizationId);
  const [values, setValues] = useState<ContactFormValues>(() => valuesFromContact(entity, contact));
  const [error, setError] = useState<string | null>(null);
  const keyRef = useRef<string>(makeNonce());
  const payloadRef = useRef<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setValues(valuesFromContact(entity, contact));
    setError(null);
    keyRef.current = makeNonce();
    payloadRef.current = null;
    mutation.reset();
  }, [contact?.id, entity, open, organizationId]);

  const update = <K extends keyof ContactFormValues>(key: K, value: ContactFormValues[K]) => {
    setValues((current) => ({ ...current, [key]: value }));
  };

  const updateAddress = (key: AddressKey, value: string) => {
    setValues((current) => ({ ...current, address: { ...current.address, [key]: value } }));
  };

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const validation = validateValues(entity, values);
    if (validation) {
      setError(validation);
      return;
    }
    const data = buildPayload(entity, values);
    const fingerprint = JSON.stringify({ organizationId, entity, contactId: contact?.id ?? null, data });
    if (payloadRef.current !== fingerprint) {
      keyRef.current = makeNonce();
      payloadRef.current = fingerprint;
    }
    setError(null);
    try {
      await mutation.mutateAsync({
        organizationId,
        entity,
        data,
        contactId: contact?.id ?? null,
        idempotencyKey: keyRef.current,
      });
      onSaved();
    } catch (submitError) {
      setError(userFacingContactError(submitError, 'Não foi possível salvar o cadastro. A operação pode ter sido confirmada; tente novamente sem alterar os dados.'));
    }
  };

  const title = contact ? (entity === 'client' ? 'Editar cliente' : 'Editar fornecedor') : (entity === 'client' ? 'Novo cliente' : 'Novo fornecedor');
  const canWrite = currentMembershipRole === 'owner' || currentMembershipRole === 'admin' || currentMembershipRole === 'finance';

  return (
    <Modal title={title} open={open} onClose={onClose}>
      <form className="contact-form" onSubmit={(event) => void submit(event)}>
        {!canWrite ? <Alert kind="warning">Seu papel é somente leitura para este cadastro. A autorização final também é aplicada pelo Supabase.</Alert> : null}
        {error ? <Alert kind="error">{error}</Alert> : null}
        <p className="form-intro">Campos opcionais vazios serão enviados como nulos para que uma edição completa possa limpar dados antigos.</p>
        <section className="contact-form-section">
          <div className="contact-section-heading"><div><h3>Identificação</h3><p>O nome é o único campo obrigatório.</p></div></div>
          <Field label="Nome"><Input autoFocus value={values.name} onChange={(event) => update('name', event.target.value)} maxLength={200} placeholder={entity === 'client' ? 'Ex.: Ana Souza' : 'Ex.: Papelaria Central'} /></Field>
          <div className="form-grid">
            <Field label="Tipo de pessoa"><Select value={values.personType} onChange={(event) => { const next = event.target.value as PersonType; setValues((current) => ({ ...current, personType: next, birthDate: next === 'business' ? '' : current.birthDate })); }}><option value="individual">Pessoa física</option><option value="business">Pessoa jurídica</option></Select></Field>
            <Field label="CPF/CNPJ (opcional)" hint="Formato validado, sem consulta fiscal. Letras do CNPJ são preservadas."><Input value={values.taxId} onChange={(event) => update('taxId', event.target.value)} onBlur={() => update('taxId', normalizeTaxId(values.taxId))} maxLength={20} placeholder="CPF ou CNPJ" /></Field>
          </div>
          {entity === 'client' && values.personType === 'individual' ? <Field label="Data de nascimento (opcional)"><Input type="date" value={values.birthDate} onChange={(event) => update('birthDate', event.target.value)} /></Field> : null}
        </section>

        <section className="contact-form-section">
          <div className="contact-section-heading"><div><h3>Contato</h3><p>Use dados de contato operacionais, quando disponíveis.</p></div></div>
          <div className="form-grid"><Field label="Telefone"><Input value={values.phone} onChange={(event) => update('phone', event.target.value)} maxLength={100} placeholder="(11) 99999-0000" autoComplete="tel" /></Field><Field label="E-mail"><Input type="email" value={values.email} onChange={(event) => update('email', event.target.value)} maxLength={320} placeholder="nome@empresa.com" autoComplete="email" /></Field></div>
          {entity === 'supplier' ? <Field label="Site (opcional)" hint="Somente links iniciados por http:// ou https://."><Input type="url" value={values.website} onChange={(event) => update('website', event.target.value)} maxLength={2048} placeholder="https://empresa.com.br" /></Field> : null}
        </section>

        <section className="contact-form-section">
          <div className="contact-section-heading"><div><h3>Endereço</h3><p>Campos vazios serão gravados como null; não representam endereço completo para frete.</p></div></div>
          <div className="form-grid"><Field label="CEP"><Input value={values.address.postal_code} onChange={(event) => updateAddress('postal_code', event.target.value)} maxLength={20} autoComplete="postal-code" /></Field><Field label="Rua"><Input value={values.address.street} onChange={(event) => updateAddress('street', event.target.value)} maxLength={200} autoComplete="street-address" /></Field><Field label="Número"><Input value={values.address.number} onChange={(event) => updateAddress('number', event.target.value)} maxLength={40} /></Field><Field label="Bairro"><Input value={values.address.district} onChange={(event) => updateAddress('district', event.target.value)} maxLength={120} /></Field><Field label="Complemento"><Input value={values.address.complement} onChange={(event) => updateAddress('complement', event.target.value)} maxLength={120} /></Field><Field label="Cidade"><Input value={values.address.city} onChange={(event) => updateAddress('city', event.target.value)} maxLength={120} autoComplete="address-level2" /></Field><Field label="UF"><Input value={values.address.state} onChange={(event) => updateAddress('state', event.target.value.toUpperCase())} maxLength={2} autoComplete="address-level1" /></Field></div>
        </section>

        <section className="contact-form-section">
          <div className="contact-section-heading"><div><h3>Observações</h3><p>Texto interno do negócio, sem HTML.</p></div></div>
          <Field label="Observações"><Textarea value={values.notes} onChange={(event) => update('notes', event.target.value)} maxLength={5000} placeholder={entity === 'supplier' ? 'Prazos, condições, frete e contatos.' : 'Preferências e observações do atendimento.'} /></Field>
        </section>
        <div className="form-actions"><Button type="button" variant="ghost" onClick={onClose}>Cancelar</Button><Button type="submit" disabled={!canWrite} loading={mutation.isPending}>{contact ? 'Salvar alterações' : 'Cadastrar'}</Button></div>
      </form>
    </Modal>
  );
}
