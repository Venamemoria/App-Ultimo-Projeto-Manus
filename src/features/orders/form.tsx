import { useEffect, useMemo, useRef, useState } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import { Alert, Button, Field, Input, Modal, Select, Textarea } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';
import { useProductDetailQuery } from '../products/api';
import type { ProductDto } from '../products/types';
import { useCreateOrderMutation, useOrderCatalogQuery } from './api';
import { previewManualService, previewProductPricing, type PricingPreview } from './pricingPreview';
import type { DiscountType, OrderCreateItem, OrderInitialStatus, PaymentMethod } from './types';
import { canCreateOrders, canStartConsumingOrder, ORDER_INITIAL_STATUSES } from './types';
import { decimalAtScale, isIsoDate, moneyAtTwoDecimals, newIdempotencyKey, optionalText, todayIso } from './utils';
import { formatCurrency } from '../../lib/format';
import { Decimal } from '../../lib/decimal';

interface DraftItem {
  kind: 'product' | 'manual_service';
  productId: string;
  variantId: string;
  title: string;
  quantity: string;
  width: string;
  height: string;
  details: string;
  personalization: string;
  unitPrice: string;
  override: boolean;
  overrideReason: string;
  productionDate: string;
  deliveryDate: string;
}

interface DraftOrder {
  clientId: string;
  title: string;
  orderDate: string;
  productionDate: string;
  deliveryDate: string;
  responsibleMembershipId: string;
  publicNotes: string;
  internalNotes: string;
  initialStatus: OrderInitialStatus;
  discountType: DiscountType;
  discountValue: string;
  shippingAmount: string;
  items: DraftItem[];
}

function blankItem(kind: DraftItem['kind'] = 'product'): DraftItem {
  return { kind, productId: '', variantId: '', title: '', quantity: '1', width: '', height: '', details: '', personalization: '', unitPrice: '', override: kind === 'manual_service', overrideReason: '', productionDate: '', deliveryDate: '' };
}

function initialDraft(): DraftOrder {
  return { clientId: '', title: '', orderDate: todayIso(), productionDate: '', deliveryDate: '', responsibleMembershipId: '', publicNotes: '', internalNotes: '', initialStatus: 'Pendente', discountType: 'none', discountValue: '0', shippingAmount: '0', items: [blankItem()] };
}

function parsePersonalization(value: string): Record<string, unknown> | null {
  if (!value.trim()) return null;
  let parsed: unknown;
  try { parsed = JSON.parse(value); } catch { throw new Error('Personalização deve ser um objeto JSON válido.'); }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('Personalização deve ser um objeto JSON.');
  if (new Blob([JSON.stringify(parsed)]).size > 20000) throw new Error('Personalização ultrapassa 20.000 bytes.');
  return parsed as Record<string, unknown>;
}

function productFor(item: DraftItem, products: ProductDto[]): ProductDto | null {
  return products.find((product) => product.id === item.productId) ?? null;
}

export function NewOrderModal({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated: (orderId: string) => void }) {
  const { organizationId, currentMembershipRole } = useSession();
  const catalog = useOrderCatalogQuery(organizationId);
  const createOrder = useCreateOrderMutation(organizationId);
  const [draft, setDraft] = useState<DraftOrder>(initialDraft);
  const [activeItem, setActiveItem] = useState(0);
  const [stockConfirmed, setStockConfirmed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [idempotencyKey, setIdempotencyKey] = useState(newIdempotencyKey);
  const intentSignature = useMemo(() => JSON.stringify(draft), [draft]);
  const lastSubmittedSignature = useRef<string | null>(null);

  useEffect(() => {
    if (lastSubmittedSignature.current !== intentSignature) setIdempotencyKey(newIdempotencyKey());
  }, [intentSignature]);
  useEffect(() => {
    if (!open) return;
    setDraft(initialDraft());
    setActiveItem(0);
    setStockConfirmed(false);
    setError(null);
    setIdempotencyKey(newIdempotencyKey());
    lastSubmittedSignature.current = null;
  }, [open]);

  const products = catalog.data?.products ?? [];
  const activeDraft = draft.items[activeItem] ?? draft.items[0];
  const activeProduct = productFor(activeDraft, products);
  const productDetail = useProductDetailQuery(organizationId, activeDraft.kind === 'product' && activeDraft.productId ? activeDraft.productId : null);
  const activePreview = useMemo(() => {
    if (!activeDraft) return { preview: null, error: null };
    try {
      if (activeDraft.kind === 'manual_service') return { preview: previewManualService(activeDraft.quantity, activeDraft.unitPrice), error: null };
      if (!activeProduct || !productDetail.data) return { preview: null, error: null };
      return { preview: previewProductPricing({ product: activeProduct, snapshot: productDetail.data, variantId: activeDraft.variantId || null, quantity: activeDraft.quantity, dimensions: activeProduct.billing_unit === 'm2' ? { width_cm: activeDraft.width, height_cm: activeDraft.height } : null, override: activeDraft.override, overridePrice: activeDraft.unitPrice }), error: null };
    } catch (previewError) { return { preview: null, error: previewError instanceof Error ? previewError.message : 'Preview indisponível.' }; }
  }, [activeDraft, activeProduct, productDetail.data]);

  const canCreate = canCreateOrders(currentMembershipRole);
  const canConsume = canStartConsumingOrder(currentMembershipRole);
  const allowedMemberships = (catalog.data?.memberships ?? []).filter((membership) => ['owner', 'admin', 'production'].includes(membership.role));
  const update = <K extends keyof DraftOrder>(key: K, value: DraftOrder[K]) => setDraft((current) => ({ ...current, [key]: value }));
  const updateItem = (index: number, patch: Partial<DraftItem>) => setDraft((current) => ({ ...current, items: current.items.map((item, itemIndex) => itemIndex === index ? { ...item, ...patch } : item) }));

  const validateDates = (orderDate: string, productionDate: string, deliveryDate: string) => {
    if (!isIsoDate(orderDate)) throw new Error('Informe uma data de pedido válida.');
    if (productionDate && (!isIsoDate(productionDate) || productionDate < orderDate)) throw new Error('A previsão de produção deve ser uma data válida após o pedido.');
    if (deliveryDate && (!isIsoDate(deliveryDate) || deliveryDate < (productionDate || orderDate))) throw new Error('A entrega deve respeitar a sequência do pedido e da produção.');
  };

  const buildItems = (): OrderCreateItem[] => draft.items.map((item) => {
    if (!item.quantity.trim()) throw new Error('Informe a quantidade de todos os itens.');
    const quantity = decimalAtScale(item.quantity, 8, true, 'Quantidade');
    const productionDate = item.productionDate || null;
    const deliveryDate = item.deliveryDate || null;
    if (productionDate && (!isIsoDate(productionDate) || productionDate < draft.orderDate)) throw new Error('A previsão de produção de um item é inválida.');
    if (deliveryDate && (!isIsoDate(deliveryDate) || deliveryDate < (productionDate || draft.orderDate))) throw new Error('A entrega de um item é inválida.');
    if (item.kind === 'manual_service') {
      if (!item.title.trim()) throw new Error('Serviço manual exige um título.');
      if (!item.overrideReason.trim()) throw new Error('Serviço manual exige o motivo do preço informado.');
      return { kind: 'manual_service', product_id: null, variant_id: null, title: item.title.trim(), quantity, unit_price: decimalAtScale(item.unitPrice, 8, false, 'Preço do serviço'), price_override: true, price_override_reason: item.overrideReason.trim(), dimensions: null, details: optionalText(item.details, 5000), personalization: parsePersonalization(item.personalization), production_date: productionDate, delivery_date: deliveryDate };
    }
    const product = productFor(item, products);
    if (!product) throw new Error('Selecione um produto vigente para todos os itens.');
    const dimensions = product.billing_unit === 'm2' ? { width_cm: decimalAtScale(item.width, 8, true, 'Largura'), height_cm: decimalAtScale(item.height, 8, true, 'Altura') } : null;
    if (product.pricing_mode === 'variation' && !item.variantId) throw new Error(`Selecione a variação de ${product.name}.`);
    if (item.override && (!item.unitPrice.trim() || !item.overrideReason.trim())) throw new Error('Preço override exige valor e motivo explícito.');
    return { kind: 'product', product_id: product.id, variant_id: item.variantId || null, title: optionalText(item.title, 200), quantity, unit_price: item.override ? decimalAtScale(item.unitPrice, 8, false, 'Preço override') : null, price_override: item.override, price_override_reason: item.override ? item.overrideReason.trim() : null, dimensions, details: optionalText(item.details, 5000), personalization: parsePersonalization(item.personalization), production_date: productionDate, delivery_date: deliveryDate };
  });

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!organizationId || !canCreate) return;
    try {
      if (!draft.clientId) throw new Error('Selecione um cliente ativo.');
      if (!draft.title.trim()) throw new Error('Informe o título do pedido.');
      validateDates(draft.orderDate, draft.productionDate, draft.deliveryDate);
      if (draft.initialStatus !== 'Pendente' && !canConsume) throw new Error('Seu papel não pode iniciar a baixa de estoque.');
      if (draft.initialStatus !== 'Pendente' && !stockConfirmed) throw new Error('Confirme que a disponibilidade será validada pelo servidor antes de iniciar a produção.');
      const discountValue = draft.discountType === 'none' ? '0' : draft.discountType === 'fixed' ? moneyAtTwoDecimals(draft.discountValue, false, 'Desconto') : decimalAtScale(draft.discountValue, 8, false, 'Desconto percentual');
      const shippingAmount = moneyAtTwoDecimals(draft.shippingAmount, false, 'Frete');
      const items = buildItems();
      const result = await createOrder.mutateAsync({ organizationId, idempotencyKey, data: { client_id: draft.clientId, title: draft.title.trim(), order_date: draft.orderDate, production_date: draft.productionDate || null, delivery_date: draft.deliveryDate || null, responsible_membership_id: draft.responsibleMembershipId || null, public_notes: optionalText(draft.publicNotes, 5000), internal_notes: optionalText(draft.internalNotes, 10000), initial_status: draft.initialStatus, discount_type: draft.discountType, discount_value: discountValue, shipping_amount: shippingAmount }, items });
      lastSubmittedSignature.current = intentSignature;
      onCreated(result.order_id);
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : 'Não foi possível confirmar o pedido.');
    }
  };

  if (!open) return null;
  if (!canCreate) return <Modal title="Novo pedido" open={open} onClose={onClose}><Alert kind="warning">Seu papel não pode criar pedidos. A permissão efetiva é validada também pelo Supabase.</Alert><div className="form-actions"><Button variant="secondary" onClick={onClose}>Fechar</Button></div></Modal>;

  return <Modal title="Novo pedido" open={open} onClose={onClose}>
    {catalog.isLoading ? <p className="form-intro">Consultando clientes e catálogo vigentes…</p> : null}
    {catalog.error ? <Alert kind="error">Não foi possível carregar clientes ou catálogo. Nenhum dado foi inventado.</Alert> : null}
    {error ? <Alert kind="error">{error}</Alert> : null}
    <form className="order-form" onSubmit={submit}>
      <section className="order-form-section"><div className="subsection-heading"><div><h3>Dados do pedido</h3><p>O cliente precisa estar ativo na organização atual.</p></div></div>
        <div className="form-grid">
          <Field label="Cliente ativo"><Select value={draft.clientId} onChange={(event) => update('clientId', event.target.value)}><option value="">Selecione um cliente</option>{(catalog.data?.clients ?? []).map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</Select></Field>
          <Field label="Título"><Input value={draft.title} maxLength={200} onChange={(event) => update('title', event.target.value)} placeholder="Ex.: Encomenda de lembranças" /></Field>
          <Field label="Data do pedido" hint="Hoje é o padrão, mas a data pode ser retroativa."><Input type="date" value={draft.orderDate} onChange={(event) => update('orderDate', event.target.value)} /></Field>
          <Field label="Responsável"><Select value={draft.responsibleMembershipId} onChange={(event) => update('responsibleMembershipId', event.target.value)}><option value="">Sem responsável definido</option>{allowedMemberships.map((membership) => <option key={membership.id} value={membership.id}>{membership.role} · usuário {membership.user_id.slice(0, 8)}</option>)}</Select></Field>
          <Field label="Previsão de produção"><Input type="date" value={draft.productionDate} min={draft.orderDate} onChange={(event) => update('productionDate', event.target.value)} /></Field>
          <Field label="Previsão de entrega"><Input type="date" value={draft.deliveryDate} min={draft.productionDate || draft.orderDate} onChange={(event) => update('deliveryDate', event.target.value)} /></Field>
        </div>
      </section>
      <section className="order-form-section"><div className="subsection-heading"><div><h3>Itens</h3><p>Produtos usam a versão vigente do catálogo; o servidor congela o preço e a receita.</p></div><div className="form-actions-inline"><Button type="button" variant="secondary" icon={<Plus size={15} />} onClick={() => { update('items', [...draft.items, blankItem('product')]); setActiveItem(draft.items.length); }}>Produto</Button><Button type="button" variant="ghost" icon={<Plus size={15} />} onClick={() => { update('items', [...draft.items, blankItem('manual_service')]); setActiveItem(draft.items.length); }}>Serviço manual</Button></div></div>
        <div className="order-item-tabs" role="tablist">{draft.items.map((item, index) => <button type="button" role="tab" aria-selected={activeItem === index} className={activeItem === index ? 'active' : ''} key={`${index}-${item.kind}`} onClick={() => setActiveItem(index)}>Item {index + 1}<small>{item.kind === 'product' ? productFor(item, products)?.name ?? 'Produto' : item.title || 'Serviço manual'}</small></button>)}</div>
        {activeDraft ? <div className="order-item-editor">
          <div className="form-grid"><Field label="Tipo"><Select value={activeDraft.kind} onChange={(event) => { const kind = event.target.value as DraftItem['kind']; updateItem(activeItem, { ...blankItem(kind), kind }); }}><option value="product">Produto do catálogo</option><option value="manual_service">Serviço manual</option></Select></Field><Field label="Quantidade"><Input value={activeDraft.quantity} inputMode="decimal" onChange={(event) => updateItem(activeItem, { quantity: event.target.value })} /></Field></div>
          {activeDraft.kind === 'product' ? <>
            <Field label="Produto vigente"><Select value={activeDraft.productId} onChange={(event) => updateItem(activeItem, { productId: event.target.value, variantId: '' })}><option value="">Selecione um produto</option>{products.map((product) => <option key={product.id} value={product.id}>{product.name}{product.sku ? ` · ${product.sku}` : ''}</option>)}</Select></Field>
            {activeProduct?.pricing_mode === 'variation' ? <Field label="Variação ativa"><Select value={activeDraft.variantId} onChange={(event) => updateItem(activeItem, { variantId: event.target.value })}><option value="">Selecione a variação</option>{(productDetail.data?.variants ?? []).filter((variant) => variant.active).map((variant) => <option key={variant.id} value={variant.id}>{variant.name}{variant.sku ? ` · ${variant.sku}` : ''}</option>)}</Select></Field> : null}
            {activeProduct?.billing_unit === 'm2' ? <div className="form-grid"><Field label="Largura (cm)"><Input value={activeDraft.width} inputMode="decimal" onChange={(event) => updateItem(activeItem, { width: event.target.value })} /></Field><Field label="Altura (cm)"><Input value={activeDraft.height} inputMode="decimal" onChange={(event) => updateItem(activeItem, { height: event.target.value })} /></Field></div> : null}
            <Field label="Título da peça" hint="Opcional para produto; o servidor usa o nome congelado quando vazio."><Input value={activeDraft.title} maxLength={200} onChange={(event) => updateItem(activeItem, { title: event.target.value })} /></Field>
            <label className="check-line"><input type="checkbox" checked={activeDraft.override} onChange={(event) => updateItem(activeItem, { override: event.target.checked })} /> Informar override de preço</label>
            {activeDraft.override ? <div className="form-grid"><Field label="Preço unitário"><Input value={activeDraft.unitPrice} inputMode="decimal" onChange={(event) => updateItem(activeItem, { unitPrice: event.target.value })} /></Field><Field label="Motivo obrigatório"><Input value={activeDraft.overrideReason} maxLength={2000} onChange={(event) => updateItem(activeItem, { overrideReason: event.target.value })} /></Field></div> : null}
          </> : <div className="form-grid"><Field label="Título do serviço"><Input value={activeDraft.title} maxLength={200} onChange={(event) => updateItem(activeItem, { title: event.target.value })} /></Field><Field label="Preço unitário"><Input value={activeDraft.unitPrice} inputMode="decimal" onChange={(event) => updateItem(activeItem, { unitPrice: event.target.value })} /></Field><Field label="Motivo do preço informado"><Input value={activeDraft.overrideReason} maxLength={2000} onChange={(event) => updateItem(activeItem, { overrideReason: event.target.value })} /></Field></div>}
          <div className="form-grid"><Field label="Detalhes da peça"><Textarea value={activeDraft.details} maxLength={5000} onChange={(event) => updateItem(activeItem, { details: event.target.value })} /></Field><Field label="Personalização (JSON opcional)" hint="Metadata opaca; não altera preço, quantidade ou estoque."><Textarea value={activeDraft.personalization} maxLength={20000} onChange={(event) => updateItem(activeItem, { personalization: event.target.value })} placeholder='{"cor":"terracota"}' /></Field><Field label="Produção da peça"><Input type="date" value={activeDraft.productionDate} min={draft.orderDate} onChange={(event) => updateItem(activeItem, { productionDate: event.target.value })} /></Field><Field label="Entrega da peça"><Input type="date" value={activeDraft.deliveryDate} min={activeDraft.productionDate || draft.orderDate} onChange={(event) => updateItem(activeItem, { deliveryDate: event.target.value })} /></Field></div>
          {activePreview.error ? <Alert kind="warning">{activePreview.error}</Alert> : activePreview.preview ? <PricePreviewCard preview={activePreview.preview} /> : null}
          {draft.items.length > 1 ? <Button type="button" variant="ghost" icon={<Trash2 size={15} />} onClick={() => { update('items', draft.items.filter((_, index) => index !== activeItem)); setActiveItem(Math.max(0, activeItem - 1)); }}>Remover item</Button> : null}
        </div> : null}
      </section>
      <section className="order-form-section"><div className="subsection-heading"><div><h3>Condição comercial</h3><p>O desconto não inclui o frete. Valores finais vêm da transação no servidor.</p></div></div><div className="form-grid"><Field label="Status inicial"><Select value={draft.initialStatus} onChange={(event) => update('initialStatus', event.target.value as OrderInitialStatus)}>{ORDER_INITIAL_STATUSES.filter((status) => status === 'Pendente' || canConsume).map((status) => <option key={status} value={status}>{status}</option>)}</Select></Field><Field label="Frete (BRL)"><Input value={draft.shippingAmount} inputMode="decimal" onChange={(event) => update('shippingAmount', event.target.value)} /></Field><Field label="Desconto"><Select value={draft.discountType} onChange={(event) => update('discountType', event.target.value as DiscountType)}><option value="none">Sem desconto</option><option value="fixed">Valor fixo (BRL)</option><option value="percent">Percentual</option></Select></Field>{draft.discountType !== 'none' ? <Field label={draft.discountType === 'fixed' ? 'Desconto (BRL)' : 'Desconto (%)'}><Input value={draft.discountValue} inputMode="decimal" onChange={(event) => update('discountValue', event.target.value)} /></Field> : null}</div>{draft.initialStatus !== 'Pendente' ? <div className="consuming-warning"><Alert kind="warning">Iniciar em {draft.initialStatus} exige disponibilidade de todos os insumos. A confirmação abaixo não baixa localmente: o RPC transacional continua sendo a única autoridade.</Alert><label className="check-line"><input type="checkbox" checked={stockConfirmed} onChange={(event) => setStockConfirmed(event.target.checked)} /> Entendi que o servidor pode rejeitar integralmente se faltar qualquer insumo.</label></div> : null}</section>
      <section className="order-form-section"><div className="form-grid"><Field label="Notas públicas"><Textarea value={draft.publicNotes} maxLength={5000} onChange={(event) => update('publicNotes', event.target.value)} /></Field><Field label="Notas internas"><Textarea value={draft.internalNotes} maxLength={10000} onChange={(event) => update('internalNotes', event.target.value)} /></Field></div></section>
      <div className="form-actions"><Button type="button" variant="secondary" onClick={onClose}>Cancelar</Button><Button type="submit" loading={createOrder.isPending}>Confirmar pedido</Button></div>
    </form>
  </Modal>;
}

function PricePreviewCard({ preview }: { preview: PricingPreview }) {
  return <div className="order-price-preview"><span>{preview.label}</span><strong>{formatCurrency(preview.lineAmount)}</strong><small>Preço unitário {formatCurrency(preview.unitPrice)} · quantidade cobrável {preview.billedQuantity}</small></div>;
}

export function estimateDraftTotal(items: PricingPreview[], shipping: string, discountType: DiscountType, discountValue: string): string {
  const subtotal = items.reduce((sum, item) => sum.plus(item.lineAmount), new Decimal(0));
  const discount = discountType === 'fixed' ? new Decimal(discountValue || 0) : discountType === 'percent' ? subtotal.times(new Decimal(discountValue || 0)).div(100) : new Decimal(0);
  return formatCurrency(subtotal.minus(discount).plus(new Decimal(shipping || 0)).toDecimalPlaces(2).toFixed(2));
}
