import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { CalendarDays, CircleDollarSign, FileText, PackagePlus, Plus, Search, WalletCards } from 'lucide-react';
import { Link } from 'react-router-dom';
import { Alert, Button, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, StatCard, Textarea } from '../../components/ui';
import { Decimal, decimalString, formatDecimal, localDateToday, parseDecimalInput } from '../../lib/decimal';
import { formatDate } from '../../lib/format';
import { useSession } from '../../app/AuthProvider';
import { useCreatePurchaseMutation, useMaterialsQuery, usePurchasesQuery, useSuppliersQuery, userFacingInventoryError } from '../inventory/api';
import { OrganizationContext, OrganizationPicker } from '../inventory/OrganizationContext';
import { canRegisterPurchase } from '../inventory/types';
import type { MaterialDto, SupplierOption } from '../inventory/types';
import type { PaymentStatus, PurchaseDto } from './types';
import '../inventory/inventory.css';

const money = (value: string | Decimal | null | undefined, scale = 2) => {
  const formatted = formatDecimal(value, scale);
  return formatted === '—' ? formatted : `R$ ${formatted}`;
};

const quantity = (value: string | null | undefined) => formatDecimal(value, 8);

function makeIdempotencyKey() {
  return globalThis.crypto.randomUUID();
}

function errorText(error: unknown, fallback: string) {
  return userFacingInventoryError(error, fallback);
}

function sumAmounts(purchases: PurchaseDto[], predicate?: (purchase: PurchaseDto) => boolean) {
  try {
    return purchases.reduce((sum, purchase) => predicate && !predicate(purchase) ? sum : sum.plus(new Decimal(purchase.total_amount)), new Decimal(0));
  } catch {
    return null;
  }
}

function shortId(id: string | null) {
  return id ? `${id.slice(0, 8)}…` : '—';
}

export function PurchasesPage() {
  const { organizationId, currentMembershipRole } = useSession();
  if (!canRegisterPurchase(currentMembershipRole)) return <><PageHeader eyebrow="Compras" title="Acesso restrito"/><Alert kind="warning">Compras e pagamentos são acessíveis somente ao proprietário, à administração e ao financeiro.</Alert></>;
  return <OrganizationContext><PurchasesWorkspace key={organizationId ?? 'none'} /></OrganizationContext>;
}

function PurchasesWorkspace() {
  const { organizationId, organization, currentMembershipRole } = useSession();
  const purchasesQuery = usePurchasesQuery(organizationId);
  const materialsQuery = useMaterialsQuery(organizationId);
  const suppliersQuery = useSuppliersQuery(organizationId);
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [modalOpen, setModalOpen] = useState(false);
  const canCreate = canRegisterPurchase(currentMembershipRole);
  const purchases = purchasesQuery.data ?? [];
  const materials = materialsQuery.data ?? [];
  const suppliers = suppliersQuery.data ?? [];
  const normalizedSearch = search.trim().toLocaleLowerCase('pt-BR');
  const filteredPurchases = useMemo(() => purchases.filter((purchase) => {
    const searchable = `${purchase.material_name} ${purchase.supplier_name ?? ''} ${purchase.document_reference ?? ''}`.toLocaleLowerCase('pt-BR');
    return (!normalizedSearch || searchable.includes(normalizedSearch))
      && (!status || purchase.payment_status === status)
      && (!from || purchase.purchase_date >= from)
      && (!to || purchase.purchase_date <= to);
  }), [from, normalizedSearch, purchases, status, to]);
  const totalRegistered = useMemo(() => purchasesQuery.isError ? null : sumAmounts(purchases), [purchases, purchasesQuery.isError]);
  const totalPaid = useMemo(() => purchasesQuery.isError ? null : sumAmounts(purchases, (purchase) => purchase.payment_status === 'paid'), [purchases, purchasesQuery.isError]);
  const totalPending = useMemo(() => purchasesQuery.isError ? null : sumAmounts(purchases, (purchase) => purchase.payment_status === 'pending'), [purchases, purchasesQuery.isError]);

  if (purchasesQuery.isLoading || materialsQuery.isLoading) return <Loading label="Consultando compras e materiais…" />;

  return (
    <>
      <PageHeader
        eyebrow="Estoque & Custos"
        title="Registro de compras"
        description={`Compras reais de ${organization?.name ?? 'sua organização'} entram no estoque e criam a despesa vinculada na mesma transação.`}
        action={canCreate && materials.length ? <Button icon={<Plus size={17} />} onClick={() => setModalOpen(true)}>Registrar compra</Button> : undefined}
      />
      <OrganizationPicker />
      {suppliersQuery.isError ? <Alert className="inventory-alert" kind="warning">Fornecedores não puderam ser carregados. O registro continua sem fornecedor, sem dados demonstrativos.</Alert> : null}

      <div className="stats-grid inventory-stats purchase-stats">
        <StatCard label="Total registrado" value={totalRegistered === null ? '—' : money(totalRegistered)} footnote="valor total das compras carregadas" icon={<CircleDollarSign size={17} />} />
        <StatCard label="Pago" value={totalPaid === null ? '—' : money(totalPaid)} footnote="somente compras declaradas como pagas" icon={<WalletCards size={17} />} />
        <StatCard label="Pendente" value={totalPending === null ? '—' : money(totalPending)} footnote="não inferimos pagamento" icon={<CalendarDays size={17} />} />
      </div>

      {materialsQuery.isError ? (
        <div className="query-error-panel"><Alert kind="error">{errorText(materialsQuery.error, 'Não foi possível carregar os insumos necessários para compras.')}</Alert><Button variant="secondary" loading={materialsQuery.isFetching} onClick={() => void materialsQuery.refetch()}>Tentar novamente</Button></div>
      ) : materials.length === 0 ? (
        <EmptyState title="Crie um insumo antes da compra" description="Uma compra só pode apontar para um insumo existente. O financeiro não cria materiais sozinho e nenhum registro demonstrativo foi incluído." action={<Link className="button button-primary" to="/estoque"><PackagePlus size={16} />Ir para Inventário</Link>} />
      ) : (
        <section className="panel inventory-panel">
          {purchasesQuery.isError ? <div className="query-error-panel"><Alert kind="error">{errorText(purchasesQuery.error, 'Não foi possível carregar as compras.')}</Alert><Button variant="secondary" loading={purchasesQuery.isFetching} onClick={() => void purchasesQuery.refetch()}>Tentar novamente</Button></div> : <>
          <div className="filter-row purchase-filter-row">
            <label className="search-field"><Search size={17} aria-hidden="true" /><span className="sr-only">Buscar por insumo, fornecedor ou documento</span><input className="input" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Buscar insumo, fornecedor ou documento" /></label>
            <label className="filter-field"><span>Pagamento</span><Select value={status} onChange={(event) => setStatus(event.target.value)}><option value="">Todos os estados</option><option value="pending">Pendente</option><option value="paid">Pago</option></Select></label>
            <Field label="De"><Input type="date" value={from} onChange={(event) => setFrom(event.target.value)} /></Field>
            <Field label="Até"><Input type="date" value={to} onChange={(event) => setTo(event.target.value)} /></Field>
          </div>
          {!purchases.length ? <EmptyState title="Nenhuma compra registrada" description="As compras começam vazias. Registre uma compra real para criar estoque, compra e despesa vinculada em uma única transação." action={canCreate ? <Button onClick={() => setModalOpen(true)} icon={<Plus size={16} />}>Registrar primeira compra</Button> : <span className="muted-note">Seu papel pode consultar os registros, mas não registrar compras.</span>} /> : null}
          {purchases.length > 0 && !filteredPurchases.length ? <EmptyState title="Nenhuma compra combina com os filtros" description="Ajuste a busca, o estado de pagamento ou o período para consultar os registros reais carregados." /> : null}
          {filteredPurchases.length ? <PurchaseTable purchases={filteredPurchases} /> : null}
          </>}
        </section>
      )}

      <CreatePurchaseModal open={modalOpen} organizationId={organizationId!} materials={materials} suppliers={suppliers} supplierError={suppliersQuery.isError} onClose={() => setModalOpen(false)} />
    </>
  );
}

function PurchaseTable({ purchases }: { purchases: PurchaseDto[] }) {
  return <div className="table-scroll"><table className="data-table purchase-table"><caption className="sr-only">Compras registradas</caption><thead><tr><th>Data</th><th>Insumo</th><th>Fornecedor</th><th>Quantidade</th><th>Total</th><th>Custo unitário</th><th>Pagamento</th><th>Documento</th><th>Vínculos reais</th></tr></thead><tbody>{purchases.map((purchase) => <tr key={purchase.id}><td>{formatDate(purchase.purchase_date)}</td><th scope="row"><strong>{purchase.material_name}</strong></th><td>{purchase.supplier_name ?? '—'}</td><td className="numeric">{quantity(purchase.quantity_acquired)}</td><td className="numeric">{money(purchase.total_amount)}</td><td className="numeric">{money(purchase.unit_cost, 24)}</td><td><span className={`payment-badge payment-${purchase.payment_status}`}>{purchase.payment_status === 'paid' ? 'Pago' : 'Pendente'}</span>{purchase.paid_at ? <small className="status-text">em {formatDate(purchase.paid_at)}</small> : null}</td><td>{purchase.document_reference || '—'}</td><td><div className="reference-list"><span className="reference-badge" title={purchase.receipt_movement_id ? `Movimento de estoque ${purchase.receipt_movement_id}` : undefined}>Estoque {shortId(purchase.receipt_movement_id)}</span><span className="reference-badge" title={purchase.cash_entry_id ? `Lançamento de caixa ${purchase.cash_entry_id}` : undefined}>Caixa {shortId(purchase.cash_entry_id)}</span></div></td></tr>)}</tbody></table></div>;
}

function CreatePurchaseModal({ open, organizationId, materials, suppliers, supplierError, onClose }: { open: boolean; organizationId: string; materials: MaterialDto[]; suppliers: SupplierOption[]; supplierError: boolean; onClose: () => void }) {
  const mutation = useCreatePurchaseMutation(organizationId);
  const keyRef = useRef<string | null>(null);
  const payloadRef = useRef<string | null>(null);
  const [materialId, setMaterialId] = useState('');
  const [quantityAcquired, setQuantityAcquired] = useState('');
  const [totalAmount, setTotalAmount] = useState('');
  const [purchaseDate, setPurchaseDate] = useState(localDateToday());
  const [supplierId, setSupplierId] = useState('');
  const [documentReference, setDocumentReference] = useState('');
  const [paymentStatus, setPaymentStatus] = useState<PaymentStatus>('pending');
  const [paidAt, setPaidAt] = useState('');
  const [formError, setFormError] = useState<string | null>(null);
  useEffect(() => { if (open) { setMaterialId(materials[0]?.id ?? ''); setQuantityAcquired(''); setTotalAmount(''); setPurchaseDate(localDateToday()); setSupplierId(''); setDocumentReference(''); setPaymentStatus('pending'); setPaidAt(''); setFormError(null); keyRef.current = null; payloadRef.current = null; mutation.reset(); } }, [open, materials]);
  const selectedMaterial = materials.find((material) => material.id === materialId);
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    try {
      if (!materialId || !selectedMaterial) throw new Error('Selecione um insumo existente.');
      if (!purchaseDate) throw new Error('Informe a data da compra.');
      const qty = decimalString(parseDecimalInput(quantityAcquired, { positive: true }));
      const total = decimalString(parseDecimalInput(totalAmount, { scale: 2 }));
      if (paymentStatus === 'paid' && !paidAt) throw new Error('Informe a data de pagamento para uma compra paga.');
      if (paymentStatus === 'pending' && paidAt) throw new Error('Compra pendente não pode ter data de pagamento.');
      const payload = { organizationId, materialId, quantityAcquired: qty, totalAmount: total, purchaseDate, paymentStatus, paidAt: paymentStatus === 'paid' ? paidAt : null, supplierId: supplierId || null, documentReference: documentReference.trim() || null };
      const fingerprint = JSON.stringify(payload);
      if (!keyRef.current || payloadRef.current !== fingerprint) { keyRef.current = makeIdempotencyKey(); payloadRef.current = fingerprint; }
      setFormError(null);
      await mutation.mutateAsync({ ...payload, idempotencyKey: keyRef.current });
      onClose();
    } catch (error) { setFormError(errorText(error, 'Não foi possível registrar a compra.')); }
  };
  return <Modal title="Registrar compra" open={open} onClose={onClose}><form className="inventory-form" onSubmit={submit}><p className="form-intro">O valor total informado é o valor real da compra. Esta ação cria estoque, compra e despesa vinculada em uma única transação.</p>{formError ? <Alert kind="error">{formError}</Alert> : null}<Field label="Insumo existente"><Select value={materialId} onChange={(event) => setMaterialId(event.target.value)} autoFocus><option value="">Selecione um insumo</option>{materials.map((material) => <option key={material.id} value={material.id}>{material.name} ({material.unit})</option>)}</Select></Field><div className="form-grid"><Field label="Quantidade adquirida" hint={selectedMaterial ? `Unidade: ${selectedMaterial.unit}; até 8 casas.` : 'Até 8 casas decimais.'}><Input inputMode="decimal" value={quantityAcquired} onChange={(event) => setQuantityAcquired(event.target.value)} placeholder="0" /></Field><Field label="Valor total real da compra" hint="Valor cobrado; até 2 casas decimais."><Input inputMode="decimal" value={totalAmount} onChange={(event) => setTotalAmount(event.target.value)} placeholder="0,00" /></Field></div><Field label="Data da compra"><Input type="date" value={purchaseDate} onChange={(event) => setPurchaseDate(event.target.value)} /></Field><div className="form-grid"><Field label="Estado de pagamento"><Select value={paymentStatus} onChange={(event) => { const next = event.target.value as PaymentStatus; setPaymentStatus(next); if (next === 'pending') setPaidAt(''); }}><option value="pending">Pendente</option><option value="paid">Pago</option></Select></Field><Field label="Data de pagamento" hint={paymentStatus === 'paid' ? 'Obrigatória quando o estado é Pago.' : 'Deixe vazia enquanto estiver pendente.'}><Input type="date" value={paidAt} onChange={(event) => setPaidAt(event.target.value)} disabled={paymentStatus !== 'paid'} /></Field></div><Field label="Fornecedor (opcional)" hint={supplierError ? 'Fornecedores indisponíveis nesta consulta; tente novamente.' : undefined}><Select value={supplierId} onChange={(event) => setSupplierId(event.target.value)} disabled={supplierError}><option value="">Sem fornecedor</option>{suppliers.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.name}</option>)}</Select></Field><Field label="Documento / referência (opcional)"><Input value={documentReference} onChange={(event) => setDocumentReference(event.target.value)} maxLength={500} placeholder="Ex.: NF 1234" /></Field><Alert kind="info">Pagamento não é inferido: Pendente não cria valor pago, e Pago exige a data declarada. O vínculo de caixa exibido depois é o ID real criado pela transação.</Alert><div className="form-actions"><Button type="button" variant="ghost" onClick={onClose}>Cancelar</Button><Button type="submit" loading={mutation.isPending}>Registrar compra</Button></div></form></Modal>;
}
