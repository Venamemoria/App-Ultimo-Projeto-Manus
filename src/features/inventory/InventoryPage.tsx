import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { AlertTriangle, Archive, Download, PackagePlus, Pencil, Plus, Search, SlidersHorizontal, Wrench } from 'lucide-react';
import { Link } from 'react-router-dom';
import { Alert, Button, EmptyState, Field, Input, Loading, Modal, PageHeader, Select, StatCard, Textarea } from '../../components/ui';
import { Decimal, decimalString, formatDecimal, parseDecimalInput, STOCK_RESULT_SCALE, UNIT_COST_SCALE, unitCostPreview } from '../../lib/decimal';
import { formatDate } from '../../lib/format';
import { useSession } from '../../app/AuthProvider';
import {
  useAdjustMaterialMutation,
  useCreateMaterialMutation,
  useMaterialsQuery,
  useMovementsQuery,
  useReceiveMaterialMutation,
  useSuppliersQuery,
  useUpdateMaterialMutation,
  userFacingInventoryError,
} from './api';
import { OrganizationContext, OrganizationPicker } from './OrganizationContext';
import { movementLabel } from './movements';
import { canManageInventory, canReceiveInventory, MATERIAL_UNITS, type InventoryTab, type MaterialDto, type MaterialUnit, type StockMovementDto, type SupplierOption } from './types';
import './inventory.css';

const money = (value: string | Decimal | null | undefined) => {
  const formatted = formatDecimal(value, UNIT_COST_SCALE);
  return formatted === '—' ? formatted : `R$ ${formatted}`;
};

const quantity = (value: string | null | undefined) => formatDecimal(value, STOCK_RESULT_SCALE);

function stockValue(materials: MaterialDto[]): Decimal | null {
  try {
    return materials.reduce((total, material) => total.plus(new Decimal(material.stock_quantity).times(new Decimal(material.unit_cost))), new Decimal(0));
  } catch {
    return null;
  }
}

function makeIdempotencyKey() {
  return globalThis.crypto.randomUUID();
}

function errorText(error: unknown, fallback: string) {
  return userFacingInventoryError(error, fallback);
}

function movementKind(movement: { quantity_delta: string }) {
  try {
    return new Decimal(movement.quantity_delta).isNegative() ? 'negative' : 'positive';
  } catch {
    return 'neutral';
  }
}

function csvCell(value: string | number | null | undefined) {
  const text = String(value ?? '');
  const escapedFormula = /^[=+\-@]/.test(text) ? `'${text}` : text;
  return `"${escapedFormula.replace(/"/g, '""')}"`;
}

function exportMaterials(materials: MaterialDto[], supplierById: Map<string, string>) {
  const rows = [
    ['Nome', 'Categoria', 'Unidade', 'Custo unitário', 'Saldo', 'Limite de reposição', 'Fornecedor'],
    ...materials.map((material) => [
      material.name,
      material.category ?? '',
      material.unit,
      money(material.unit_cost),
      quantity(material.stock_quantity),
      quantity(material.reorder_level),
      material.supplier_id ? supplierById.get(material.supplier_id) ?? material.supplier_id : '',
    ]),
  ];
  const content = `\uFEFF${rows.map((row) => row.map(csvCell).join(';')).join('\r\n')}`;
  const blob = new Blob([content], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = 'inventario-insumos.csv';
  anchor.click();
  URL.revokeObjectURL(url);
}

export function InventoryPage() {
  const { organizationId } = useSession();
  return <OrganizationContext><InventoryWorkspace key={organizationId ?? 'none'} /></OrganizationContext>;
}

function InventoryWorkspace() {
  const { organizationId, organization, currentMembershipRole } = useSession();
  const materialsQuery = useMaterialsQuery(organizationId);
  const suppliersQuery = useSuppliersQuery(organizationId);
  const [tab, setTab] = useState<InventoryTab>('list');
  const movementsQuery = useMovementsQuery(organizationId, tab === 'history');
  const [search, setSearch] = useState('');
  const [categoryFilter, setCategoryFilter] = useState('');
  const [historyMaterial, setHistoryMaterial] = useState('');
  const [historyType, setHistoryType] = useState('');
  const [historyFrom, setHistoryFrom] = useState('');
  const [historyTo, setHistoryTo] = useState('');
  const [modal, setModal] = useState<'create' | 'edit' | 'receive' | 'adjust' | null>(null);
  const [selectedMaterial, setSelectedMaterial] = useState<MaterialDto | null>(null);

  const materials = materialsQuery.data ?? [];
  const suppliers = suppliersQuery.data ?? [];
  const supplierById = useMemo(() => new Map(suppliers.map((supplier) => [supplier.id, supplier.name])), [suppliers]);
  const categories = useMemo(() => Array.from(new Set(materials.map((material) => material.category?.trim()).filter(Boolean) as string[])).sort((a, b) => a.localeCompare(b, 'pt-BR')), [materials]);
  const normalizedSearch = search.trim().toLocaleLowerCase('pt-BR');
  const filteredMaterials = useMemo(() => materials.filter((material) => {
    const matchesSearch = !normalizedSearch || `${material.name} ${material.category ?? ''}`.toLocaleLowerCase('pt-BR').includes(normalizedSearch);
    const matchesCategory = !categoryFilter || material.category === categoryFilter;
    return matchesSearch && matchesCategory;
  }), [categoryFilter, materials, normalizedSearch]);
  const alertMaterials = useMemo(() => materials.filter((material) => material.is_low_stock), [materials]);
  const filteredMovements = useMemo(() => {
    const from = historyFrom ? new Date(`${historyFrom}T00:00:00`) : null;
    const to = historyTo ? new Date(`${historyTo}T23:59:59.999`) : null;
    return (movementsQuery.data ?? []).filter((movement) => {
      const movementDate = new Date(movement.created_at);
      return (!historyMaterial || movement.material_id === historyMaterial)
        && (!historyType || movement.movement_type === historyType)
        && (!from || movementDate >= from)
        && (!to || movementDate <= to);
    });
  }, [historyFrom, historyMaterial, historyTo, historyType, movementsQuery.data]);
  const totalStockValue = useMemo(() => materialsQuery.isError ? null : stockValue(materials), [materials, materialsQuery.isError]);
  const manageable = canManageInventory(currentMembershipRole);
  const canReceive = canReceiveInventory(currentMembershipRole);

  const openModal = (next: 'create' | 'edit' | 'receive' | 'adjust', material?: MaterialDto) => {
    setSelectedMaterial(material ?? null);
    setModal(next);
  };

  if (materialsQuery.isLoading) return <Loading label="Consultando os materiais da organização…" />;

  return (
    <>
      <PageHeader
        eyebrow="Estoque & Custos"
        title="Inventário de materiais"
        description={`Materiais, custos e saldos reais de ${organization?.name ?? 'sua organização'}, protegidos pela sua sessão.`}
        action={manageable ? <Button icon={<Plus size={17} />} onClick={() => openModal('create')}>Cadastrar insumo</Button> : undefined}
      />
      <OrganizationPicker />
      {suppliersQuery.isError ? <Alert className="inventory-alert" kind="warning">Fornecedores não puderam ser carregados. Nenhum fornecedor demonstrativo foi incluído; tente novamente antes de associar um fornecedor.</Alert> : null}

      <div className="stats-grid inventory-stats">
        <StatCard label="Insumos cadastrados" value={materialsQuery.isError ? '—' : String(materials.length)} footnote="registros reais nesta organização" icon={<Archive size={17} />} />
        <StatCard label="Valor ao custo" value={totalStockValue === null ? '—' : money(totalStockValue)} footnote="saldo atual × custo unitário" icon={<SlidersHorizontal size={17} />} />
        <StatCard label="Alertas de reposição" value={materialsQuery.isError ? '—' : String(alertMaterials.length)} footnote="saldo menor ou igual ao limite" icon={<AlertTriangle size={17} />} />
      </div>

      <section className="panel inventory-panel">
        {materialsQuery.isError ? <div className="query-error-panel"><Alert kind="error">{errorText(materialsQuery.error, 'Não foi possível carregar os materiais.')}</Alert><Button variant="secondary" loading={materialsQuery.isFetching} onClick={() => void materialsQuery.refetch()}>Tentar novamente</Button></div> : <>
        <div className="inventory-toolbar">
          <div className="inventory-tabs" role="tablist" aria-label="Visões do inventário">
            <button className={tab === 'list' ? 'inventory-tab active' : 'inventory-tab'} type="button" role="tab" aria-selected={tab === 'list'} onClick={() => setTab('list')}>Lista de insumos <span>{materials.length}</span></button>
            <button className={tab === 'alerts' ? 'inventory-tab active' : 'inventory-tab'} type="button" role="tab" aria-selected={tab === 'alerts'} onClick={() => setTab('alerts')}>Alertas de reposição <span>{alertMaterials.length}</span></button>
            <button className={tab === 'history' ? 'inventory-tab active' : 'inventory-tab'} type="button" role="tab" aria-selected={tab === 'history'} onClick={() => setTab('history')}>Histórico</button>
          </div>
          {tab !== 'history' ? <Button variant="secondary" icon={<Download size={16} />} disabled={!filteredMaterials.length} onClick={() => exportMaterials(filteredMaterials, supplierById)}>Exportar CSV</Button> : null}
        </div>

        {tab === 'history' ? (
          <HistoryView
            materials={materials}
            movements={filteredMovements}
            loading={movementsQuery.isLoading}
            error={movementsQuery.error}
            material={historyMaterial}
            type={historyType}
            from={historyFrom}
            to={historyTo}
            onMaterialChange={setHistoryMaterial}
            onTypeChange={setHistoryType}
            onFromChange={setHistoryFrom}
            onToChange={setHistoryTo}
          />
        ) : (
          <>
            <div className="filter-row">
              <label className="search-field"><Search size={17} aria-hidden="true" /><span className="sr-only">Buscar por nome ou categoria</span><input className="input" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Buscar por nome ou categoria" /></label>
              <label className="filter-field"><span>Categoria</span><Select value={categoryFilter} onChange={(event) => setCategoryFilter(event.target.value)}><option value="">Todas as categorias</option>{categories.map((category) => <option key={category} value={category}>{category}</option>)}</Select></label>
            </div>
            {tab === 'alerts' && !alertMaterials.length ? <EmptyState title="Nenhum alerta de reposição" description="Os alertas aparecem quando o saldo real de um insumo fica menor ou igual ao seu limite configurado." /> : null}
            {tab === 'list' && !materials.length ? <EmptyState title="Nenhum insumo cadastrado" description="O inventário desta organização começa vazio. Cadastre o primeiro insumo com unidade, custo, saldo inicial e limite de reposição." action={manageable ? <Button onClick={() => openModal('create')} icon={<Plus size={16} />}>Cadastrar primeiro insumo</Button> : <Link className="text-link" to="/conta">Confira sua permissão na Conta</Link>} /> : null}
            {filteredMaterials.length > 0 ? <MaterialTable materials={tab === 'alerts' ? alertMaterials.filter((material) => !normalizedSearch || `${material.name} ${material.category ?? ''}`.toLocaleLowerCase('pt-BR').includes(normalizedSearch)).filter((material) => !categoryFilter || material.category === categoryFilter) : filteredMaterials} supplierById={supplierById} manageable={manageable} canReceive={canReceive} onEdit={(material) => openModal('edit', material)} onReceive={(material) => openModal('receive', material)} onAdjust={(material) => openModal('adjust', material)} /> : null}
            {materials.length > 0 && !filteredMaterials.length && tab === 'list' ? <EmptyState title="Nenhum resultado para estes filtros" description="Ajuste a busca ou remova o filtro de categoria para consultar os registros reais carregados." /> : null}
            {materials.length > 0 && tab === 'alerts' && alertMaterials.length > 0 && !alertMaterials.some((material) => (!normalizedSearch || `${material.name} ${material.category ?? ''}`.toLocaleLowerCase('pt-BR').includes(normalizedSearch)) && (!categoryFilter || material.category === categoryFilter)) ? <EmptyState title="Nenhum alerta combina com os filtros" description="Os alertas existem, mas não correspondem à busca ou categoria selecionada." /> : null}
          </>
        )}
        </>}
      </section>

      <CreateMaterialModal open={modal === 'create'} organizationId={organizationId!} suppliers={suppliers} supplierError={suppliersQuery.isError} onClose={() => setModal(null)} />
      <EditMaterialModal open={modal === 'edit'} organizationId={organizationId!} material={selectedMaterial} suppliers={suppliers} supplierError={suppliersQuery.isError} onClose={() => setModal(null)} />
      <ReceiveMaterialModal open={modal === 'receive'} organizationId={organizationId!} material={selectedMaterial} onClose={() => setModal(null)} />
      <AdjustMaterialModal open={modal === 'adjust'} organizationId={organizationId!} material={selectedMaterial} onClose={() => setModal(null)} />
    </>
  );
}

function MaterialTable({ materials, supplierById, manageable, canReceive, onEdit, onReceive, onAdjust }: { materials: MaterialDto[]; supplierById: Map<string, string>; manageable: boolean; canReceive: boolean; onEdit: (material: MaterialDto) => void; onReceive: (material: MaterialDto) => void; onAdjust: (material: MaterialDto) => void }) {
  return (
    <div className="table-scroll">
      <table className="data-table">
        <caption className="sr-only">Materiais cadastrados</caption>
        <thead><tr><th>Material</th><th>Categoria</th><th>Unidade</th><th>Custo unitário</th><th>Saldo</th><th>Limite</th><th>Fornecedor</th><th>Ações</th></tr></thead>
        <tbody>{materials.map((material) => (
          <tr key={material.id}>
            <th scope="row"><strong>{material.name}</strong>{material.is_low_stock ? <span className="status-text status-warning">Abaixo do limite</span> : null}</th>
            <td>{material.category || '—'}</td>
            <td>{material.unit}</td>
            <td className="numeric">{money(material.unit_cost)}</td>
            <td className="numeric"><span className={material.is_low_stock ? 'stock-low' : ''}>{quantity(material.stock_quantity)}</span></td>
            <td className="numeric">{quantity(material.reorder_level)}</td>
            <td>{material.supplier_id ? supplierById.get(material.supplier_id) ?? 'Fornecedor associado' : '—'}</td>
            <td><div className="table-actions"><span className="sr-only">Ações para {material.name}</span>{manageable ? <><Button variant="ghost" icon={<Pencil size={15} />} onClick={() => onEdit(material)}>Editar</Button><Button variant="ghost" icon={<Wrench size={15} />} onClick={() => onAdjust(material)}>Ajustar</Button></> : null}{canReceive ? <Button variant="ghost" icon={<PackagePlus size={15} />} onClick={() => onReceive(material)}>Receber</Button> : null}</div></td>
          </tr>
        ))}</tbody>
      </table>
    </div>
  );
}

function HistoryView({ materials, movements, loading, error, material, type, from, to, onMaterialChange, onTypeChange, onFromChange, onToChange }: { materials: MaterialDto[]; movements: StockMovementDto[]; loading: boolean; error: unknown; material: string; type: string; from: string; to: string; onMaterialChange: (value: string) => void; onTypeChange: (value: string) => void; onFromChange: (value: string) => void; onToChange: (value: string) => void }) {
  return (
    <>
      <div className="filter-row history-filters">
        <label className="filter-field"><span>Insumo</span><Select value={material} onChange={(event) => onMaterialChange(event.target.value)}><option value="">Todos os insumos</option>{materials.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</Select></label>
        <label className="filter-field"><span>Tipo</span><Select value={type} onChange={(event) => onTypeChange(event.target.value)}><option value="">Todos os movimentos</option><option value="opening">Saldo inicial</option><option value="receipt">Entradas</option><option value="adjustment">Ajustes</option><option value="order_deduction">Baixas de pedido</option><option value="order_return">Devoluções de pedido</option></Select></label>
        <Field label="De"><Input type="date" value={from} onChange={(event) => onFromChange(event.target.value)} /></Field>
        <Field label="Até"><Input type="date" value={to} onChange={(event) => onToChange(event.target.value)} /></Field>
      </div>
      {loading ? <Loading label="Carregando histórico auditável…" /> : null}
      {error ? <Alert kind="error">{errorText(error, 'Não foi possível carregar o histórico.')}</Alert> : null}
      {!loading && !error && !movements.length ? <EmptyState title="Nenhum movimento encontrado" description="O histórico mostra somente movimentos reais registrados para esta organização e para os filtros selecionados." /> : null}
      {!loading && !error && movements.length ? <div className="table-scroll"><table className="data-table history-table"><caption className="sr-only">Histórico de movimentos de estoque</caption><thead><tr><th>Data</th><th>Insumo</th><th>Tipo</th><th>Delta</th><th>Saldo final</th><th>Motivo / referência</th></tr></thead><tbody>{movements.map((movement) => { const item = materials.find((candidate) => candidate.id === movement.material_id); return <tr key={movement.id}><td>{formatDate(movement.created_at)}</td><td><strong>{item?.name ?? 'Insumo não encontrado'}</strong></td><td><span className={`movement-badge movement-${movementKind(movement)}`}>{movementLabel(movement)}</span></td><td className="numeric">{quantity(movement.quantity_delta)}</td><td className="numeric">{quantity(movement.stock_after)}</td><td>{movement.note || (!movement.order_id && !movement.purchase_id ? '—' : null)}{movement.order_id ? <>{movement.note ? ' · ' : ''}<Link to={`/pedidos/${movement.order_id}`} title={`Pedido ${movement.order_id}`}>Pedido {movement.order_id.slice(0, 8)}…</Link></> : movement.purchase_id ? <>{movement.note ? ' · ' : ''}<span title={`Compra ${movement.purchase_id}`}>Compra vinculada <small className="id-reference">{movement.purchase_id.slice(0, 8)}…</small></span></> : null}</td></tr>; })}</tbody></table></div> : null}
    </>
  );
}

function SupplierSelect({ suppliers, supplierError, value, onChange }: { suppliers: SupplierOption[]; supplierError: boolean; value: string; onChange: (value: string) => void }) {
  return <Field label="Fornecedor (opcional)" hint={supplierError ? 'Não foi possível carregar fornecedores desta organização.' : undefined}><Select value={value} onChange={(event) => onChange(event.target.value)} disabled={supplierError}><option value="">Sem fornecedor</option>{suppliers.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.name}</option>)}</Select></Field>;
}

function CreateMaterialModal({ open, organizationId, suppliers, supplierError, onClose }: { open: boolean; organizationId: string; suppliers: SupplierOption[]; supplierError: boolean; onClose: () => void }) {
  const mutation = useCreateMaterialMutation(organizationId);
  const keyRef = useRef<string | null>(null);
  const payloadRef = useRef<string | null>(null);
  const [name, setName] = useState('');
  const [category, setCategory] = useState('');
  const [unit, setUnit] = useState<MaterialUnit>('un');
  const [packageCost, setPackageCost] = useState('');
  const [packageQuantity, setPackageQuantity] = useState('');
  const [initialStock, setInitialStock] = useState('0');
  const [reorderLevel, setReorderLevel] = useState('0');
  const [supplierId, setSupplierId] = useState('');
  const [formError, setFormError] = useState<string | null>(null);
  useEffect(() => { if (open) { setName(''); setCategory(''); setUnit('un'); setPackageCost(''); setPackageQuantity(''); setInitialStock('0'); setReorderLevel('0'); setSupplierId(''); setFormError(null); keyRef.current = null; payloadRef.current = null; mutation.reset(); } }, [open]);
  const preview = unitCostPreview(packageCost, packageQuantity);
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    try {
      const cleanName = name.trim();
      if (!cleanName) throw new Error('Informe o nome do insumo.');
      if (cleanName.length > 200) throw new Error('O nome do insumo pode ter no máximo 200 caracteres.');
      const cost = decimalString(parseDecimalInput(packageCost));
      const packQty = decimalString(parseDecimalInput(packageQuantity, { positive: true }));
      const stock = decimalString(parseDecimalInput(initialStock));
      const reorder = decimalString(parseDecimalInput(reorderLevel));
      const payload = { organizationId, name: cleanName, category: category.trim() || null, unit, packageCost: cost, packageQuantity: packQty, initialStock: stock, reorderLevel: reorder, supplierId: supplierId || null };
      const fingerprint = JSON.stringify(payload);
      if (!keyRef.current || payloadRef.current !== fingerprint) { keyRef.current = makeIdempotencyKey(); payloadRef.current = fingerprint; }
      setFormError(null);
      await mutation.mutateAsync({ ...payload, idempotencyKey: keyRef.current });
      onClose();
    } catch (error) { setFormError(errorText(error, 'Não foi possível cadastrar o insumo.')); }
  };
  return <Modal title="Cadastrar insumo" open={open} onClose={onClose}><form className="inventory-form" onSubmit={submit}><p className="form-intro">O custo unitário será calculado pelo banco como custo total da embalagem dividido pela quantidade.</p>{formError ? <Alert kind="error">{formError}</Alert> : null}<Field label="Nome do insumo"><Input value={name} onChange={(event) => setName(event.target.value)} maxLength={200} placeholder="Ex.: Papel kraft" autoFocus /></Field><div className="form-grid"><Field label="Categoria (opcional)"><Input value={category} onChange={(event) => setCategory(event.target.value)} maxLength={120} placeholder="Ex.: Papéis" /></Field><Field label="Unidade"><Select value={unit} onChange={(event) => setUnit(event.target.value as MaterialUnit)}>{MATERIAL_UNITS.map((option) => <option key={option} value={option}>{option}</option>)}</Select></Field></div><div className="form-grid"><Field label="Custo total da embalagem / lote" hint="Aceita até 8 casas decimais."><Input inputMode="decimal" value={packageCost} onChange={(event) => setPackageCost(event.target.value)} placeholder="0,00000000" /></Field><Field label="Quantidade da embalagem" hint="Deve ser maior que zero."><Input inputMode="decimal" value={packageQuantity} onChange={(event) => setPackageQuantity(event.target.value)} placeholder="1" /></Field></div><div className="unit-preview">{preview ? <>Prévia do custo unitário: <strong>{money(preview)}</strong> por {unit}</> : 'Informe custo e quantidade para ver a prévia do custo unitário.'}</div><div className="form-grid"><Field label="Saldo inicial" hint="Pode ser zero."><Input inputMode="decimal" value={initialStock} onChange={(event) => setInitialStock(event.target.value)} placeholder="0" /></Field><Field label="Limite de reposição" hint="Alerta quando o saldo for menor ou igual a este limite."><Input inputMode="decimal" value={reorderLevel} onChange={(event) => setReorderLevel(event.target.value)} placeholder="0" /></Field></div><SupplierSelect suppliers={suppliers} supplierError={supplierError} value={supplierId} onChange={setSupplierId} /><Alert kind="info">Saldo inicial não registra despesa; use Registrar compra para uma compra real.</Alert><div className="form-actions"><Button type="button" variant="ghost" onClick={onClose}>Cancelar</Button><Button type="submit" loading={mutation.isPending}>Salvar insumo</Button></div></form></Modal>;
}

function EditMaterialModal({ open, organizationId, material, suppliers, supplierError, onClose }: { open: boolean; organizationId: string; material: MaterialDto | null; suppliers: SupplierOption[]; supplierError: boolean; onClose: () => void }) {
  const mutation = useUpdateMaterialMutation(organizationId);
  const [name, setName] = useState('');
  const [category, setCategory] = useState('');
  const [reorderLevel, setReorderLevel] = useState('');
  const [supplierId, setSupplierId] = useState('');
  const [formError, setFormError] = useState<string | null>(null);
  useEffect(() => { if (open && material) { setName(material.name); setCategory(material.category ?? ''); setReorderLevel(material.reorder_level); setSupplierId(material.supplier_id ?? ''); setFormError(null); mutation.reset(); } }, [material?.id, open]);
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    try {
      if (!material) return;
      const cleanName = name.trim();
      if (!cleanName) throw new Error('Informe o nome do insumo.');
      const reorder = decimalString(parseDecimalInput(reorderLevel));
      setFormError(null);
      await mutation.mutateAsync({ organizationId, materialId: material.id, name: cleanName, category: category.trim() || null, reorderLevel: reorder, supplierId: supplierId || null });
      onClose();
    } catch (error) { setFormError(errorText(error, 'Não foi possível atualizar o insumo.')); }
  };
  return <Modal title={material ? `Editar ${material.name}` : 'Editar insumo'} open={open} onClose={onClose}><form className="inventory-form" onSubmit={submit}>{formError ? <Alert kind="error">{formError}</Alert> : null}<Field label="Nome do insumo"><Input value={name} onChange={(event) => setName(event.target.value)} maxLength={200} autoFocus /></Field><Field label="Categoria (opcional)"><Input value={category} onChange={(event) => setCategory(event.target.value)} maxLength={120} /></Field><div className="form-grid"><Field label="Limite de reposição"><Input inputMode="decimal" value={reorderLevel} onChange={(event) => setReorderLevel(event.target.value)} /></Field><SupplierSelect suppliers={suppliers} supplierError={supplierError} value={supplierId} onChange={setSupplierId} /></div><Alert kind="info">A unidade, o saldo e os custos são imutáveis neste fluxo. Use Receber ou Ajustar para movimentos auditáveis.</Alert><div className="form-actions"><Button type="button" variant="ghost" onClick={onClose}>Cancelar</Button><Button type="submit" loading={mutation.isPending}>Salvar alterações</Button></div></form></Modal>;
}

function ReceiveMaterialModal({ open, organizationId, material, onClose }: { open: boolean; organizationId: string; material: MaterialDto | null; onClose: () => void }) {
  const mutation = useReceiveMaterialMutation(organizationId);
  const keyRef = useRef<string | null>(null);
  const payloadRef = useRef<string | null>(null);
  const [receiveQuantity, setReceiveQuantity] = useState('');
  const [packageCost, setPackageCost] = useState('');
  const [packageQuantity, setPackageQuantity] = useState('');
  const [note, setNote] = useState('');
  const [formError, setFormError] = useState<string | null>(null);
  useEffect(() => { if (open) { setReceiveQuantity(''); setPackageCost(material?.package_cost ?? ''); setPackageQuantity(material?.package_quantity ?? ''); setNote(''); setFormError(null); keyRef.current = null; payloadRef.current = null; mutation.reset(); } }, [material?.id, open]);
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    try {
      if (!material) return;
      const qty = decimalString(parseDecimalInput(receiveQuantity, { positive: true }));
      const cost = decimalString(parseDecimalInput(packageCost));
      const packQty = decimalString(parseDecimalInput(packageQuantity, { positive: true }));
      const cleanNote = note.trim();
      if (!cleanNote) throw new Error('Informe o motivo da entrada avulsa.');
      const payload = { organizationId, materialId: material.id, quantity: qty, packageCost: cost, packageQuantity: packQty, note: cleanNote };
      const fingerprint = JSON.stringify(payload);
      if (!keyRef.current || payloadRef.current !== fingerprint) { keyRef.current = makeIdempotencyKey(); payloadRef.current = fingerprint; }
      setFormError(null);
      await mutation.mutateAsync({ ...payload, idempotencyKey: keyRef.current });
      onClose();
    } catch (error) { setFormError(errorText(error, 'Não foi possível registrar a entrada avulsa.')); }
  };
  return <Modal title={material ? `Receber ${material.name}` : 'Receber insumo'} open={open} onClose={onClose}><form className="inventory-form" onSubmit={submit}><p className="form-intro">Esta entrada altera o saldo, mas não cria compra nem despesa.</p>{formError ? <Alert kind="error">{formError}</Alert> : null}<Field label={`Quantidade recebida (${material?.unit ?? 'un'})`}><Input inputMode="decimal" value={receiveQuantity} onChange={(event) => setReceiveQuantity(event.target.value)} autoFocus placeholder="0" /></Field><div className="form-grid"><Field label="Custo do lote" hint="Não cria despesa neste fluxo."><Input inputMode="decimal" value={packageCost} onChange={(event) => setPackageCost(event.target.value)} /></Field><Field label="Quantidade da embalagem"><Input inputMode="decimal" value={packageQuantity} onChange={(event) => setPackageQuantity(event.target.value)} /></Field></div><Field label="Motivo obrigatório"><Textarea value={note} onChange={(event) => setNote(event.target.value)} maxLength={2000} placeholder="Ex.: recebimento de material remanescente" /></Field><div className="form-actions"><Button type="button" variant="ghost" onClick={onClose}>Cancelar</Button><Button type="submit" loading={mutation.isPending}>Registrar entrada</Button></div></form></Modal>;
}

function AdjustMaterialModal({ open, organizationId, material, onClose }: { open: boolean; organizationId: string; material: MaterialDto | null; onClose: () => void }) {
  const mutation = useAdjustMaterialMutation(organizationId);
  const keyRef = useRef<string | null>(null);
  const payloadRef = useRef<string | null>(null);
  const [delta, setDelta] = useState('');
  const [reason, setReason] = useState('');
  const [formError, setFormError] = useState<string | null>(null);
  useEffect(() => { if (open) { setDelta(''); setReason(''); setFormError(null); keyRef.current = null; payloadRef.current = null; mutation.reset(); } }, [material?.id, open]);
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    try {
      if (!material) return;
      const parsed = parseDecimalInput(delta, { allowNegative: true });
      if (parsed.isZero()) throw new Error('O ajuste não pode ser zero.');
      const cleanReason = reason.trim();
      if (!cleanReason) throw new Error('Informe o motivo do ajuste.');
      const payload = { organizationId, materialId: material.id, delta: decimalString(parsed), reason: cleanReason };
      const fingerprint = JSON.stringify(payload);
      if (!keyRef.current || payloadRef.current !== fingerprint) { keyRef.current = makeIdempotencyKey(); payloadRef.current = fingerprint; }
      setFormError(null);
      await mutation.mutateAsync({ ...payload, idempotencyKey: keyRef.current });
      onClose();
    } catch (error) { setFormError(errorText(error, 'Não foi possível ajustar o saldo.')); }
  };
  return <Modal title={material ? `Ajustar saldo de ${material.name}` : 'Ajustar saldo'} open={open} onClose={onClose}><form className="inventory-form" onSubmit={submit}><p className="form-intro">Use valor positivo para adicionar e negativo para retirar. O servidor impede saldo negativo e mantém o movimento no histórico.</p>{formError ? <Alert kind="error">{formError}</Alert> : null}<Field label={`Delta do saldo (${material?.unit ?? 'un'})`} hint="O valor não pode ser zero."><Input inputMode="decimal" value={delta} onChange={(event) => setDelta(event.target.value)} autoFocus placeholder="Ex.: -2 ou 3,5" /></Field><Field label="Motivo obrigatório"><Textarea value={reason} onChange={(event) => setReason(event.target.value)} maxLength={2000} placeholder="Ex.: conferência física do estoque" /></Field><div className="form-actions"><Button type="button" variant="ghost" onClick={onClose}>Cancelar</Button><Button type="submit" loading={mutation.isPending}>Registrar ajuste</Button></div></form></Modal>;
}
