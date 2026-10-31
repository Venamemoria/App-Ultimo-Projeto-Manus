import { useEffect, useMemo, useRef, useState, type ChangeEvent, type FormEvent } from 'react';
import { Archive, Download, ExternalLink, FileUp, Package, Pencil, Plus, RotateCcw, Search, UsersRound } from 'lucide-react';
import { Alert, Button, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, StatCard, Textarea } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';
import { canViewFinance } from '../../lib/permissions';
import { Decimal, formatDecimal } from '../../lib/decimal';
import { formatDate } from '../../lib/format';
import { OrganizationContext, OrganizationPicker } from '../inventory/OrganizationContext';
import { parseContactsCsv, downloadContactsCsv, CsvParseError } from './csv';
import { useArchiveContactMutation, useContactsQuery, useImportContactsMutation, userFacingContactError } from './api';
import { canManageContacts, type ClientDto, type ContactDto, type ContactEntity, type ContactImportResult, type SupplierDto } from './types';
import { ContactForm } from './form/ContactForm';
import './contacts.css';

type StatusFilter = 'active' | 'archived' | 'all';

const entityCopy: Record<ContactEntity, { singular: string; plural: string; eyebrow: string; description: string; search: string }> = {
  client: { singular: 'cliente', plural: 'clientes', eyebrow: 'Relacionamento', description: 'Cadastros de clientes desta organização, carregados do Supabase sem pedidos inventados.', search: 'Buscar por nome, contato, e-mail, cidade ou UF' },
  supplier: { singular: 'fornecedor', plural: 'fornecedores', eyebrow: 'Compras & parceiros', description: 'Fornecedores e seus materiais vinculados, com custos decimais derivados do estoque real.', search: 'Buscar por nome, contato, e-mail, cidade, UF ou site' },
};

function isSupplier(contact: ContactDto): contact is SupplierDto {
  return 'website' in contact;
}

function makeNonce(): string {
  return globalThis.crypto.randomUUID();
}

function decimalValue(value: string | null): Decimal | null {
  if (value === null) return null;
  try {
    return new Decimal(value);
  } catch {
    return null;
  }
}

function metricNumber(value: string): string {
  const decimal = decimalValue(value);
  return decimal ? formatDecimal(decimal, 0) : '—';
}

function money(value: string | null): string {
  const decimal = decimalValue(value);
  return decimal ? `R$ ${formatDecimal(decimal, 2, true)}` : '—';
}

function stockUnits(value: string): Array<{ unit: string; quantity: string }> {
  try {
    const parsed: unknown = JSON.parse(value);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return [];
    return Object.entries(parsed)
      .filter((entry): entry is [string, string] => typeof entry[0] === 'string' && typeof entry[1] === 'string' && decimalValue(entry[1]) !== null)
      .sort(([left], [right]) => left.localeCompare(right, 'pt-BR'))
      .map(([unit, quantity]) => ({ unit, quantity: formatDecimal(new Decimal(quantity), 8) }));
  } catch {
    return [];
  }
}

function safeWebsite(value: string | null): string | null {
  if (!value || !/^https?:\/\/[^\s]+$/i.test(value)) return null;
  try {
    const url = new URL(value);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.toString() : null;
  } catch {
    return null;
  }
}

function contactAddress(contact: ContactDto): string {
  const address = contact.address;
  if (!address) return '';
  return [address.city, address.state].filter(Boolean).join(' ');
}

function statusLabel(contact: ContactDto): string {
  return contact.archived_at ? 'Arquivado' : 'Ativo';
}

function ContactTabs({ filter, contacts, onChange }: { filter: StatusFilter; contacts: ContactDto[]; onChange: (next: StatusFilter) => void }) {
  const active = contacts.filter((contact) => !contact.archived_at).length;
  const archived = contacts.filter((contact) => Boolean(contact.archived_at)).length;
  return <div className="contact-tabs" role="tablist" aria-label="Status dos cadastros">
    <button className={filter === 'active' ? 'contact-tab active' : 'contact-tab'} type="button" role="tab" aria-selected={filter === 'active'} onClick={() => onChange('active')}>Ativos <span>{active}</span></button>
    <button className={filter === 'archived' ? 'contact-tab active' : 'contact-tab'} type="button" role="tab" aria-selected={filter === 'archived'} onClick={() => onChange('archived')}>Arquivados <span>{archived}</span></button>
    <button className={filter === 'all' ? 'contact-tab active' : 'contact-tab'} type="button" role="tab" aria-selected={filter === 'all'} onClick={() => onChange('all')}>Todos <span>{contacts.length}</span></button>
  </div>;
}

function ContactTable({ entity, contacts, canWrite, showCost, onDetail, onEdit, onArchive }: { entity: ContactEntity; contacts: ContactDto[]; canWrite: boolean; showCost: boolean; onDetail: (contact: ContactDto) => void; onEdit: (contact: ContactDto) => void; onArchive: (contact: ContactDto) => void }) {
  return <div className="table-scroll"><table className="data-table contacts-table"><caption className="sr-only">{entityCopy[entity].plural} cadastrados</caption><thead><tr><th>Cadastro</th><th>Contato</th><th>Cidade / UF</th>{entity === 'supplier' ? <><th>Materiais</th>{showCost && <th>Custo atual</th>}<th>Estoque por unidade</th></> : null}<th>Status</th><th>Ações</th></tr></thead><tbody>{contacts.map((contact) => {
    const supplier = isSupplier(contact) ? contact : null;
    const units = supplier ? stockUnits(supplier.stocks_by_unit) : [];
    return <tr key={contact.id}>
      <th scope="row"><strong>{contact.name}</strong><small className="table-subline">{contact.person_type === 'business' ? 'Pessoa jurídica' : 'Pessoa física'}{contact.tax_id ? ` · ${contact.tax_id}` : ''}</small></th>
      <td>{contact.phone || '—'}<small className="table-subline">{contact.email || 'Sem e-mail'}</small></td>
      <td>{contactAddress(contact) || '—'}</td>
      {supplier ? <><td className="numeric">{metricNumber(supplier.material_count)}</td>{showCost && <td className="numeric">{money(supplier.current_stock_cost)}</td>}<td>{units.length ? <div className="stock-unit-list">{units.map((entry) => <span key={entry.unit}>{entry.quantity} {entry.unit}</span>)}</div> : '—'}</td></> : null}
      <td><span className={contact.archived_at ? 'status-pill' : 'status-pill status-on'}>{statusLabel(contact)}</span></td>
      <td><div className="table-actions"><Button variant="ghost" onClick={() => onDetail(contact)}>Detalhar</Button>{canWrite ? <><Button variant="ghost" icon={<Pencil size={15} />} onClick={() => onEdit(contact)}>Editar</Button><Button variant="ghost" icon={contact.archived_at ? <RotateCcw size={15} /> : <Archive size={15} />} onClick={() => onArchive(contact)}>{contact.archived_at ? 'Recuperar' : 'Arquivar'}</Button></> : null}</div></td>
    </tr>;
  })}</tbody></table></div>;
}

function ContactDetails({ entity, contact, showCost, onClose }: { entity: ContactEntity; contact: ContactDto; showCost: boolean; onClose: () => void }) {
  const website = isSupplier(contact) ? safeWebsite(contact.website) : null;
  const supplier = isSupplier(contact) ? contact : null;
  const units = supplier ? stockUnits(supplier.stocks_by_unit) : [];
  const address = contact.address;
  return <Modal open title={`Detalhes do ${entityCopy[entity].singular}`} onClose={onClose}><div className="contact-detail">
    <div className="detail-heading"><div><p className="eyebrow">{statusLabel(contact)}</p><h3>{contact.name}</h3><p>{contact.person_type === 'business' ? 'Pessoa jurídica' : 'Pessoa física'}{contact.tax_id ? ` · ${contact.tax_id}` : ''}</p></div><UsersRound size={28} aria-hidden="true" color="#b76445" /></div>
    <div className="detail-grid"><div><span>Telefone</span><strong>{contact.phone || '—'}</strong></div><div><span>E-mail</span><strong>{contact.email || '—'}</strong></div>{entity === 'client' ? <div><span>Nascimento</span><strong>{'birth_date' in contact ? formatDate(contact.birth_date) : '—'}</strong></div> : null}{entity === 'supplier' ? <div><span>Site</span><strong>{website ? <a className="text-link" href={website} target="_blank" rel="noreferrer noopener">Abrir site <ExternalLink size={14} /></a> : '—'}</strong></div> : null}<div><span>Criado em</span><strong>{formatDate(contact.created_at)}</strong></div><div><span>Atualizado em</span><strong>{formatDate(contact.updated_at)}</strong></div></div>
    {supplier ? <section className="detail-section"><h4>Estoque vinculado</h4><div className="detail-grid"><div><span>Materiais</span><strong>{metricNumber(supplier.material_count)}</strong></div>{showCost && <div><span>Custo corrente</span><strong>{money(supplier.current_stock_cost)}</strong></div>}</div>{units.length ? <div className="stock-unit-detail">{units.map((entry) => <span key={entry.unit}><strong>{entry.unit}</strong>{entry.quantity}</span>)}</div> : <p className="detail-text">Nenhum saldo de material vinculado.</p>}</section> : null}
    <section className="detail-section"><h4>Endereço</h4>{address ? <div className="detail-grid address-detail">{[['CEP', address.postal_code], ['Rua', address.street], ['Número', address.number], ['Bairro', address.district], ['Complemento', address.complement], ['Cidade', address.city], ['UF', address.state]].map(([label, value]) => <div key={label}><span>{label}</span><strong>{value || '—'}</strong></div>)}</div> : <p className="detail-text">Nenhum endereço informado.</p>}</section>
    <section className="detail-section"><h4>Observações</h4><p className="detail-text">{contact.notes || 'Nenhuma observação informada.'}</p></section>
    <p className="contact-detail-footnote">O status é reversível por arquivamento. Este detalhe não exibe contagem de pedidos porque ela ainda não existe no contrato de dados.</p>
  </div></Modal>;
}

function ArchiveContactModal({ entity, organizationId, contact, onClose, onDone }: { entity: ContactEntity; organizationId: string; contact: ContactDto | null; onClose: () => void; onDone: () => void }) {
  const mutation = useArchiveContactMutation(entity, organizationId);
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  const targetArchived = Boolean(contact && !contact.archived_at);
  useEffect(() => {
    if (contact) {
      setReason('');
      setError(null);
      mutation.reset();
    }
  }, [contact?.id, targetArchived]);
  if (!contact) return null;
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const trimmed = reason.trim();
    if (!trimmed) {
      setError('Informe o motivo para registrar esta mudança de status.');
      return;
    }
    if (trimmed.length > 2000) {
      setError('O motivo pode ter no máximo 2.000 caracteres.');
      return;
    }
    setError(null);
    try {
      await mutation.mutateAsync({ organizationId, entity, contactId: contact.id, archived: targetArchived, reason: trimmed });
      onDone();
    } catch (archiveError) {
      setError(userFacingContactError(archiveError, 'Não foi possível alterar o status. A operação pode ter sido confirmada; tente novamente com o mesmo motivo.'));
    }
  };
  return <Modal open title={targetArchived ? `Arquivar ${entityCopy[entity].singular}` : `Recuperar ${entityCopy[entity].singular}`} onClose={onClose}><form className="archive-form" onSubmit={(event) => void submit(event)}><Alert kind={targetArchived ? 'warning' : 'info'}>{targetArchived ? 'Arquivar não exclui o cadastro nem suas referências. O status poderá ser recuperado depois.' : 'Recuperar remove o status arquivado e mantém o histórico append-only.'}</Alert>{error ? <Alert kind="error">{error}</Alert> : null}<Field label="Motivo obrigatório" hint="Este texto será registrado no evento do cadastro."><Textarea autoFocus value={reason} onChange={(event) => setReason(event.target.value)} maxLength={2000} placeholder={targetArchived ? 'Ex.: cadastro inativo a pedido do negócio' : 'Ex.: cadastro voltou a ser utilizado'} /></Field><div className="form-actions"><Button type="button" variant="ghost" onClick={onClose}>Cancelar</Button><Button type="submit" variant={targetArchived ? 'danger' : 'primary'} loading={mutation.isPending}>{targetArchived ? 'Confirmar arquivamento' : 'Confirmar recuperação'}</Button></div></form></Modal>;
}

function ImportContactsModal({ entity, organizationId, open, onClose }: { entity: ContactEntity; organizationId: string; open: boolean; onClose: () => void }) {
  const mutation = useImportContactsMutation(entity, organizationId);
  const batchKeyRef = useRef<string | null>(null);
  const payloadRef = useRef<string | null>(null);
  const [fileName, setFileName] = useState('');
  const [rows, setRows] = useState<ReturnType<typeof parseContactsCsv>['rows']>([]);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [result, setResult] = useState<ContactImportResult | null>(null);

  useEffect(() => {
    if (!open) return;
    setFileName('');
    setRows([]);
    setPreviewError(null);
    setImportError(null);
    setResult(null);
    batchKeyRef.current = null;
    payloadRef.current = null;
    mutation.reset();
  }, [entity, open, organizationId]);

  const chooseFile = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    setFileName(file.name);
    setPreviewError(null);
    setImportError(null);
    setResult(null);
    try {
      const parsed = parseContactsCsv(await file.text(), entity);
      setRows(parsed.rows);
      payloadRef.current = JSON.stringify({ entity, rows: parsed.rows });
      batchKeyRef.current = makeNonce();
    } catch (parseError) {
      setRows([]);
      batchKeyRef.current = null;
      payloadRef.current = null;
      setPreviewError(parseError instanceof Error ? parseError.message : 'Não foi possível interpretar este CSV.');
    }
  };

  const submit = async () => {
    if (!rows.length || !batchKeyRef.current) return;
    setImportError(null);
    try {
      const imported = await mutation.mutateAsync({ organizationId, entity, rows, batchKey: batchKeyRef.current });
      setResult(imported);
    } catch (importError) {
      setImportError(userFacingContactError(importError, 'Não foi possível importar. A operação pode ter sido confirmada; tente novamente com o mesmo arquivo.'));
    }
  };

  return <Modal open={open} title={`Importar ${entityCopy[entity].plural}`} onClose={onClose}><div className="import-form"><p className="form-intro">Escolha um CSV real para validar e pré-visualizar as linhas que serão enviadas à RPC transacional. O lote aceita até 500 linhas.</p><label className="file-picker"><FileUp size={18} /><span>{fileName || 'Escolher arquivo CSV'}</span><input type="file" accept=".csv,text/csv" onChange={(event) => void chooseFile(event)} /></label>{previewError ? <Alert kind="error">{previewError}</Alert> : null}{rows.length ? <><div className="import-summary"><strong>{rows.length} linha(s) analisada(s)</strong><span>Prévia dos dados do arquivo selecionado</span></div><div className="import-preview"><table className="data-table"><caption className="sr-only">Prévia da importação</caption><thead><tr><th>Nome</th><th>E-mail</th><th>Telefone</th><th>CPF/CNPJ</th><th>Cidade/UF</th></tr></thead><tbody>{rows.slice(0, 8).map((row, index) => { const address = row.address; return <tr key={`${row.name}-${index}`}><th scope="row">{row.name || '—'}</th><td>{row.email || '—'}</td><td>{row.phone || '—'}</td><td>{row.tax_id || '—'}</td><td>{[address?.city, address?.state].filter(Boolean).join(' ') || '—'}</td></tr>; })}</tbody></table></div>{rows.length > 8 ? <p className="field-hint">Mostrando 8 das {rows.length} linhas analisadas; a RPC receberá todas.</p> : null}</> : null}{importError ? <Alert kind="error">{importError}</Alert> : null}{result ? <Alert kind="success"><strong>Resultado real do servidor</strong><br />Criados: {result.created} · Atualizados: {result.updated} · Ignorados: {result.skipped}</Alert> : null}<div className="form-actions"><Button type="button" variant="ghost" onClick={onClose}>{result ? 'Fechar' : 'Cancelar'}</Button>{!result ? <Button type="button" onClick={() => void submit()} disabled={!rows.length} loading={mutation.isPending}>Importar {rows.length || ''} cadastro(s)</Button> : null}</div></div></Modal>;
}

export function ContactsPage({ entity }: { entity: ContactEntity }) {
  const { organizationId } = useSession();
  return <OrganizationContext><ContactsWorkspace key={organizationId ?? 'none'} entity={entity} /></OrganizationContext>;
}

export function ClientsPage() {
  return <ContactsPage entity="client" />;
}

export function SuppliersPage() {
  return <ContactsPage entity="supplier" />;
}

function ContactsWorkspace({ entity }: { entity: ContactEntity }) {
  const { organizationId, organization, currentMembershipRole } = useSession();
  const query = useContactsQuery(entity, organizationId);
  const [status, setStatus] = useState<StatusFilter>('active');
  const [search, setSearch] = useState('');
  const [formContact, setFormContact] = useState<ContactDto | null | undefined>(undefined);
  const [detailContact, setDetailContact] = useState<ContactDto | null>(null);
  const [archiveTarget, setArchiveTarget] = useState<ContactDto | null>(null);
  const [importOpen, setImportOpen] = useState(false);
  const contacts = query.data ?? [];
  const canWrite = canManageContacts(currentMembershipRole);
  const showCost = canViewFinance(currentMembershipRole);
  const copy = entityCopy[entity];
  const hasData = !query.isError;
  const normalizedSearch = search.trim().toLocaleLowerCase('pt-BR');
  const filteredContacts = useMemo(() => contacts.filter((contact) => {
    const matchesStatus = status === 'all' || (status === 'active' ? !contact.archived_at : Boolean(contact.archived_at));
    const address = contact.address;
    const supplierSite = isSupplier(contact) ? contact.website ?? '' : '';
    const haystack = `${contact.name} ${contact.email ?? ''} ${contact.phone ?? ''} ${contact.tax_id ?? ''} ${address?.city ?? ''} ${address?.state ?? ''} ${supplierSite}`.toLocaleLowerCase('pt-BR');
    return matchesStatus && (!normalizedSearch || haystack.includes(normalizedSearch));
  }), [contacts, normalizedSearch, status]);
  const totalMaterials = useMemo(() => entity === 'supplier' ? contacts.reduce((total, contact) => { const supplier = isSupplier(contact) ? contact : null; const count = supplier ? decimalValue(supplier.material_count) : null; return count ? total.plus(count) : total; }, new Decimal(0)) : null, [contacts, entity]);
  const totalCost = useMemo(() => {
    if (entity !== 'supplier' || !showCost) return null;
    const costs = contacts.map((contact) => isSupplier(contact) ? decimalValue(contact.current_stock_cost) : null);
    if (costs.some((cost) => cost === null)) return null;
    return costs.reduce<Decimal>((total, cost) => total.plus(cost!), new Decimal(0));
  }, [contacts, entity, showCost]);

  if (query.isLoading) return <Loading label={`Consultando ${copy.plural} da organização…`} />;

  return <>
    <PageHeader eyebrow={copy.eyebrow} title={copy.plural[0].toUpperCase() + copy.plural.slice(1)} description={`${copy.description} ${organization?.name ? `Organização: ${organization.name}.` : ''}`} action={<div className="contact-header-actions">{canWrite ? <><Button variant="secondary" icon={<FileUp size={16} />} onClick={() => setImportOpen(true)}>Importar CSV</Button><Button icon={<Plus size={17} />} onClick={() => setFormContact(null)}>Novo {copy.singular}</Button></> : null}</div>} />
    <OrganizationPicker />
    <div className={`stats-grid contact-stats ${entity === 'supplier' ? 'supplier-stats' : ''}`}>
      <StatCard label={copy.plural[0].toUpperCase() + copy.plural.slice(1)} value={hasData ? String(contacts.length) : '—'} footnote="registros reais nesta organização" icon={<UsersRound size={17} />} />
      {entity === 'client' ? <><StatCard label="Ativos" value={hasData ? String(contacts.filter((contact) => !contact.archived_at).length) : '—'} footnote="cadastros disponíveis" icon={<UsersRound size={17} />} /><StatCard label="Arquivados" value={hasData ? String(contacts.filter((contact) => Boolean(contact.archived_at)).length) : '—'} footnote="status reversível" icon={<Archive size={17} />} /></> : <><StatCard label="Materiais vinculados" value={hasData && totalMaterials ? formatDecimal(totalMaterials, 0) : '—'} footnote="soma de contagens reais" icon={<Package size={17} />} />{showCost && <StatCard label="Custo corrente" value={hasData && totalCost ? money(totalCost.toString()) : '—'} footnote="soma decimal do estoque" icon={<Archive size={17} />} />}</>}
    </div>
    {query.isError ? <section className="panel query-error-panel"><Alert kind="error">{userFacingContactError(query.error, `Não foi possível carregar ${copy.plural}.`)}</Alert><Button variant="secondary" loading={query.isFetching} onClick={() => void query.refetch()}>Tentar novamente</Button></section> : <section className="panel contacts-panel">
      <div className="contacts-toolbar"><div><h2 className="panel-title">Lista de {copy.plural}</h2><p className="panel-caption">Busca, status e exportação usam somente os registros carregados do Supabase.</p></div><Button variant="secondary" icon={<Download size={16} />} disabled={!filteredContacts.length} onClick={() => downloadContactsCsv(entity, filteredContacts)}>Exportar CSV</Button></div>
      <ContactTabs filter={status} contacts={contacts} onChange={setStatus} />
      <div className="filter-row contact-filter-row"><label className="search-field"><Search size={17} aria-hidden="true" /><span className="sr-only">{copy.search}</span><input className="input" value={search} onChange={(event) => setSearch(event.target.value)} placeholder={copy.search} /></label><div className="contact-filter-note">{filteredContacts.length} resultado(s) visível(is)</div></div>
      {!contacts.length ? <EmptyState title={`Nenhum ${copy.singular} cadastrado`} description={`A organização ainda não tem ${copy.plural} reais. Nenhum registro demonstrativo foi incluído.`} action={canWrite ? <Button onClick={() => setFormContact(null)} icon={<Plus size={16} />}>Cadastrar primeiro {copy.singular}</Button> : undefined} /> : null}
      {contacts.length > 0 && !filteredContacts.length ? <EmptyState title="Nenhum resultado para estes filtros" description="Ajuste a busca ou altere o status para consultar os cadastros reais." /> : null}
      {filteredContacts.length ? <ContactTable entity={entity} contacts={filteredContacts} canWrite={canWrite} showCost={showCost} onDetail={setDetailContact} onEdit={setFormContact} onArchive={setArchiveTarget} /> : null}
      {entity === 'supplier' ? <div className="contact-stock-note"><Package size={16} aria-hidden="true" /><span>Quantidades de estoque permanecem separadas por unidade. A tela não soma gramas, centímetros ou outras unidades incompatíveis.</span></div> : null}
    </section>}
    {formContact !== undefined && organizationId ? <ContactForm open entity={entity} organizationId={organizationId} contact={formContact} onClose={() => setFormContact(undefined)} onSaved={() => setFormContact(undefined)} /> : null}
    {detailContact ? <ContactDetails entity={entity} contact={detailContact} showCost={showCost} onClose={() => setDetailContact(null)} /> : null}
    {archiveTarget && organizationId ? <ArchiveContactModal entity={entity} organizationId={organizationId} contact={archiveTarget} onClose={() => setArchiveTarget(null)} onDone={() => setArchiveTarget(null)} /> : null}
    {organizationId ? <ImportContactsModal entity={entity} organizationId={organizationId} open={importOpen} onClose={() => setImportOpen(false)} /> : null}
  </>;
}
