import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { Alert, Button, EmptyState, Field, Input, Loading, PageHeader, Select, Textarea } from '../../components/ui';
import { Plus, Trash2 } from 'lucide-react';
import { useProductDetailQuery } from '../products/api';
import type { ProductDto } from '../products/types';
import { previewManualService, previewProductPricing } from '../orders/pricingPreview';
import { useSession } from '../../app/AuthProvider';
import { formatCurrency, formatDate } from '../../lib/format';
import { supabase } from '../../lib/supabase';
import { Decimal } from '../../lib/decimal';
import { approvePublicQuote, fetchAdminQuote, fetchPublicQuote, fetchQuoteCatalog, fetchQuotePage, fetchTracking, isUuid, issueQuote, revokeQuote, type PublicQuote, type QuoteListRow, type Tracking } from './api';
import { canCreateOrders } from '../orders/types';
import { decimalAtScale, isIsoDate, moneyAtTwoDecimals, todayIso } from '../orders/utils';
import { visibleQuotePage } from './pagination';
import { quoteBusinessDate } from './validity';
import { usePublicCapability } from './usePublicCapability';

type QuoteDraftLine = { kind: 'product' | 'manual_service'; productId: string; variantId: string; title: string; quantity: string; width: string; height: string; unitPrice: string; priceOverride: boolean; overrideReason: string; details: string; personalization: string; productionDate: string; deliveryDate: string };
const emptyQuoteLine = (kind: QuoteDraftLine['kind'] = 'manual_service'): QuoteDraftLine => ({ kind, productId: '', variantId: '', title: '', quantity: '1', width: '', height: '', unitPrice: '', priceOverride: false, overrideReason: '', details: '', personalization: '', productionDate: '', deliveryDate: '' });
const validIso = isIsoDate;
const optionalText = (value: string) => value.trim() || null;
function QuoteLineEditor({ line, index, products, organizationId, busy, onChange }: { line: QuoteDraftLine; index: number; products: ProductDto[]; organizationId: string | null; busy: boolean; onChange: (patch: Partial<QuoteDraftLine>) => void }) {
  const product = products.find((candidate) => candidate.id === line.productId) ?? null;
  const detail = useProductDetailQuery(organizationId, line.kind === 'product' && line.productId ? line.productId : null);
  const pricing = useMemo(() => {
    try {
      if (line.kind === 'manual_service') return { preview: previewManualService(line.quantity, line.unitPrice), error: '' };
      if (!product || !detail.data) return { preview: null, error: detail.error ? 'Não foi possível carregar versão e composição atuais deste produto.' : '' };
      return { preview: previewProductPricing({ product, snapshot: detail.data, variantId: line.variantId || null, quantity: line.quantity, dimensions: product.billing_unit === 'm2' ? { width_cm: line.width, height_cm: line.height } : null, override: line.priceOverride, overridePrice: line.priceOverride ? decimalAtScale(line.unitPrice, 8, false, 'Preço unitário') : '' }), error: '' };
    } catch (e) { return { preview: null, error: e instanceof Error ? e.message : 'Prévia indisponível.' }; }
  }, [line, product, detail.data, detail.error]);
  const patch = (value: Partial<QuoteDraftLine>) => onChange(value);
  return <div className="order-item-editor"><div className="form-grid"><Field label={`Tipo do item ${index + 1}`}><Select disabled={busy} value={line.kind} onChange={(e) => onChange({ ...emptyQuoteLine(e.target.value as QuoteDraftLine['kind']), kind: e.target.value as QuoteDraftLine['kind'] })}><option value="product">Produto do catálogo</option><option value="manual_service">Serviço manual</option></Select></Field><Field label="Quantidade"><Input disabled={busy} inputMode="decimal" value={line.quantity} onChange={(e) => patch({ quantity: e.target.value })}/></Field>
    {line.kind === 'product' ? <><Field label="Produto ativo da organização"><Select disabled={busy} value={line.productId} onChange={(e) => patch({ productId: e.target.value, variantId: '' })}><option value="">Selecione um produto</option>{products.map((p) => <option key={p.id} value={p.id}>{p.name}{p.sku ? ` · ${p.sku}` : ''}{!p.is_catalog_visible ? ' · interno' : ''}</option>)}</Select></Field>{product?.pricing_mode === 'variation' && <Field label="Variação ativa"><Select disabled={busy || detail.isLoading} value={line.variantId} onChange={(e) => patch({ variantId: e.target.value })}><option value="">Selecione uma variação</option>{(detail.data?.variants ?? []).filter((v) => v.active).map((v) => <option key={v.id} value={v.id}>{v.name}{v.sku ? ` · ${v.sku}` : ''}</option>)}</Select></Field>}{product?.billing_unit === 'm2' && <><Field label="Largura (cm)"><Input disabled={busy} inputMode="decimal" value={line.width} onChange={(e) => patch({ width: e.target.value })}/></Field><Field label="Altura (cm)"><Input disabled={busy} inputMode="decimal" value={line.height} onChange={(e) => patch({ height: e.target.value })}/></Field></>}<Field label="Título/descrição opcional"><Input disabled={busy} value={line.title} maxLength={200} onChange={(e) => patch({ title: e.target.value })}/></Field><Field label="Substituir preço do catálogo"><label><input type="checkbox" disabled={busy} checked={line.priceOverride} onChange={(e) => patch({ priceOverride: e.target.checked, ...(!e.target.checked ? { unitPrice: '', overrideReason: '' } : {}) })}/> Informar preço unitário excepcional</label></Field>{line.priceOverride && <><Field label="Preço unitário decimal (obrigatório)"><Input disabled={busy} inputMode="decimal" value={line.unitPrice} onChange={(e) => patch({ unitPrice: e.target.value })}/></Field><Field label="Motivo explícito do override (obrigatório)"><Input disabled={busy} value={line.overrideReason} maxLength={2000} onChange={(e) => patch({ overrideReason: e.target.value })}/></Field></>}</> : <><Field label="Descrição do serviço"><Input disabled={busy} value={line.title} maxLength={200} onChange={(e) => patch({ title: e.target.value })}/></Field><Field label="Preço unitário explícito"><Input disabled={busy} inputMode="decimal" value={line.unitPrice} onChange={(e) => patch({ unitPrice: e.target.value })}/></Field><Field label="Motivo do preço manual (obrigatório)"><Input disabled={busy} value={line.overrideReason} maxLength={2000} onChange={(e) => patch({ overrideReason: e.target.value })}/></Field></>}
    <Field label="Detalhes"><Input disabled={busy} value={line.details} maxLength={5000} onChange={(e) => patch({ details: e.target.value })}/></Field><Field label="Personalização JSON opcional"><Textarea disabled={busy} value={line.personalization} onChange={(e) => patch({ personalization: e.target.value })}/></Field><Field label="Produção prevista"><Input disabled={busy} type="date" value={line.productionDate} onChange={(e) => patch({ productionDate: e.target.value })}/></Field><Field label="Entrega prevista"><Input disabled={busy} type="date" value={line.deliveryDate} onChange={(e) => patch({ deliveryDate: e.target.value })}/></Field></div>
    {line.kind === 'product' && line.productId && !product && <Alert kind="warning">O produto vinculado nesta revisão (ID {line.productId}) não está no catálogo ativo atual. Escolha explicitamente um produto disponível; nenhuma correspondência foi presumida.</Alert>}{line.kind === 'product' && product?.pricing_mode === 'variation' && line.variantId && detail.data && !detail.data.variants.some((variant) => variant.id === line.variantId && variant.active) && <Alert kind="warning">A variação vinculada (ID {line.variantId}) não está ativa na versão vigente. Escolha uma variação ativa.</Alert>}{line.kind === 'product' && (!product || (product.pricing_mode === 'variation' && !line.variantId)) && !line.productId && <Alert kind="warning">Selecione um produto vigente e, quando exigido, uma variação ativa.</Alert>}{pricing.error && <Alert kind="warning">{pricing.error}</Alert>}{pricing.preview && <div className="order-price-preview"><span>{pricing.preview.label}</span><strong>{formatCurrency(pricing.preview.lineAmount)}</strong><small>Estimativa indicativa · servidor revalidará preço, mínimo e composição atuais.</small></div>}</div>;
}
export function QuotesPage() {
  const { organizationId, currentMembershipRole } = useSession();
  const [quotes, setQuotes] = useState<QuoteListRow[]>([]); const [cursor, setCursor] = useState<{ at: string; id: string } | null>(null);
  const [catalog, setCatalog] = useState<{ clients: import('../contacts/types').ClientDto[]; products: ProductDto[] }>({ clients: [], products: [] });
  const [clientId, setClientId] = useState(''); const [title, setTitle] = useState(''); const [lines, setLines] = useState<QuoteDraftLine[]>([emptyQuoteLine()]); const [activeLine, setActiveLine] = useState(0);
  const [valid, setValid] = useState(() => quoteBusinessDate()); const [orderDate, setOrderDate] = useState(todayIso()); const [productionDate, setProductionDate] = useState(''); const [deliveryDate, setDeliveryDate] = useState('');
  const [discountType, setDiscountType] = useState<'none' | 'fixed' | 'percent'>('none'); const [discount, setDiscount] = useState('0'); const [shipping, setShipping] = useState('0'); const [terms, setTerms] = useState(''); const [notes, setNotes] = useState('');
  const [error, setError] = useState(''); const [success, setSuccess] = useState(''); const [busy, setBusy] = useState(false); const [loading, setLoading] = useState(false); const [issuedLink, setIssuedLink] = useState('');
  const [revoking, setRevoking] = useState<string | null>(null); const [reason, setReason] = useState(''); const [revision, setRevision] = useState<QuoteListRow | null>(null);
  const intent = useRef<{ fingerprint: string; nonce: string } | null>(null); const allowed = canCreateOrders(currentMembershipRole);
  const load = useCallback(async (reset = true) => { if (!organizationId) return; setLoading(true); setError(''); try { const received = await fetchQuotePage(organizationId, reset ? null : cursor?.at ?? null, reset ? null : cursor?.id ?? null); const { items: page, cursor: nextCursor } = visibleQuotePage(received); setQuotes((old) => reset ? page : [...old, ...page]); setCursor(nextCursor); } catch (e) { setError(e instanceof Error ? e.message : 'Falha ao carregar orçamentos.'); } finally { setLoading(false); } }, [organizationId, cursor]);
  useEffect(() => { if (organizationId) { void load(true); void fetchQuoteCatalog(organizationId).then(setCatalog).catch(() => setError('Não foi possível carregar clientes e catálogo.')); } }, [organizationId]);
  const submit = async (event: React.FormEvent) => { event.preventDefault(); if (!organizationId) return; setError(''); setSuccess(''); setIssuedLink(''); try {
    if (!clientId || !title.trim() || !validIso(valid) || valid < quoteBusinessDate()) throw new Error('Selecione cliente ativo, informe título e uma validade a partir de hoje (horário de Brasília).'); if (terms.length > 20000 || notes.length > 5000 || title.length > 200) throw new Error('Título, termos ou observações excedem o limite permitido.');
    if (!validIso(orderDate) || (productionDate && (!validIso(productionDate) || productionDate < orderDate)) || (deliveryDate && (!validIso(deliveryDate) || deliveryDate < (productionDate || orderDate)))) throw new Error('Revise a sequência das datas de pedido, produção e entrega.');
    if (!lines.length) throw new Error('Adicione ao menos um item.');
    const ship = moneyAtTwoDecimals(shipping, false, 'Frete'); const disc = discountType === 'percent' ? decimalAtScale(discount, 8, false, 'Desconto percentual') : moneyAtTwoDecimals(discount, false, 'Desconto fixo'); if (discountType === 'percent' && new Decimal(disc).gt(100)) throw new Error('O desconto percentual não pode exceder 100%.');
    const data = { client_id: clientId, title: title.trim(), order_date: orderDate, production_date: productionDate || null, delivery_date: deliveryDate || null, responsible_membership_id: null, public_notes: optionalText(notes), internal_notes: null, discount_type: discountType, discount_value: discountType === 'none' ? '0' : disc, shipping_amount: ship };
    const items = lines.map((line) => { const quantity = decimalAtScale(line.quantity, 8, true, 'Quantidade'); const itemProduction = line.productionDate || productionDate || null; const itemDelivery = line.deliveryDate || deliveryDate || null; if ((itemProduction && (!isIsoDate(itemProduction) || itemProduction < orderDate)) || (itemDelivery && (!isIsoDate(itemDelivery) || itemDelivery < (itemProduction || orderDate)))) throw new Error('Revise a sequência das datas de produção e entrega em cada item.'); let personalization: unknown = null; if (line.personalization.trim()) { if (new TextEncoder().encode(line.personalization).byteLength > 20000) throw new Error('A personalização excede 20 KB.'); try { personalization = JSON.parse(line.personalization); } catch { throw new Error('Personalização deve ser JSON válido.'); } if (!personalization || typeof personalization !== 'object' || Array.isArray(personalization)) throw new Error('Personalização deve ser um objeto JSON.'); }
      if (line.kind === 'manual_service') { if (!line.title.trim() || !line.overrideReason.trim()) throw new Error('Cada serviço manual exige descrição e motivo explícito do preço.');  return { kind: 'manual_service', product_id: null, variant_id: null, title: line.title.trim(), quantity, unit_price: decimalAtScale(line.unitPrice, 8, false, 'Preço manual'), price_override: true, price_override_reason: line.overrideReason.trim(), dimensions: null, details: optionalText(line.details), personalization, production_date: itemProduction, delivery_date: itemDelivery }; }
      const product = catalog.products.find((p) => p.id === line.productId); if (!product) throw new Error('Produto selecionado não está mais disponível na organização. Escolha novamente.'); if (product.pricing_mode === 'variation' && !line.variantId) throw new Error(`Selecione uma variação ativa para ${product.name}.`); if (product.pricing_mode !== 'variation' && line.variantId) throw new Error(`${product.name} não aceita variação; corrija a linha.`);
      const dimensions = product.billing_unit === 'm2' ? { width_cm: decimalAtScale(line.width, 8, true, 'Largura'), height_cm: decimalAtScale(line.height, 8, true, 'Altura') } : null;
      if (line.priceOverride && !line.overrideReason.trim()) throw new Error('Informe o motivo explícito do override.');
      const overridePrice = line.priceOverride ? decimalAtScale(line.unitPrice, 8, false, 'Preço de override') : '';
      return { kind: 'product', product_id: product.id, variant_id: line.variantId || null, title: optionalText(line.title), quantity, unit_price: line.priceOverride ? overridePrice : null, price_override: line.priceOverride, price_override_reason: line.priceOverride ? line.overrideReason.trim() : null, dimensions, details: optionalText(line.details), personalization, production_date: itemProduction, delivery_date: itemDelivery };
    });
    const fingerprint = JSON.stringify([data, items, valid, terms, revision?.quote_id]); const nonce = intent.current?.fingerprint === fingerprint ? intent.current.nonce : crypto.randomUUID(); intent.current = { fingerprint, nonce }; setBusy(true);
    const result = await issueQuote({ organizationId, data, items, validUntil: valid, terms: optionalText(terms), nonce, ...(revision ? { parentQuoteId: revision.quote_id } : {}) });
    if (!result) throw new Error('A resposta da emissão foi inconclusiva. O conteúdo foi preservado; tente novamente sem alterar os dados para manter idempotência.'); intent.current = null; const link = `${window.location.origin}/orcamento/${result.public_token}`; setIssuedLink(link); setSuccess(revision ? 'Revisão emitida. O cliente deve revisar preços e composição atualizados.' : 'Orçamento emitido; nenhum pedido foi criado.'); setRevision(null); void load(true);
  } catch (e) { setError(e instanceof Error ? e.message : 'Não foi possível emitir. O conteúdo foi preservado para tentativa segura.'); } finally { setBusy(false); } };
  const startRevoke = (id: string) => { setRevoking(id); setReason(''); };
  const startRevision = async (quote: QuoteListRow) => { if (!organizationId || (quote.status !== 'Sent' && quote.status !== 'Expired')) return; setBusy(true); setError(''); try { const admin = await fetchAdminQuote(organizationId, quote.quote_id); if (!admin || admin.status !== 'Sent') throw new Error('Somente orçamentos enviados podem ser revisados.'); const data = admin.data; setClientId(String(data.client_id ?? '')); setTitle(String(data.title ?? '')); setOrderDate(String(data.order_date ?? todayIso())); setProductionDate(String(data.production_date ?? '')); setDeliveryDate(String(data.delivery_date ?? '')); setNotes(String(data.public_notes ?? '')); setDiscountType((data.discount_type as 'none' | 'fixed' | 'percent') ?? 'none'); setDiscount(String(data.discount_value ?? '0')); setShipping(String(data.shipping_amount ?? '0')); setValid(admin.valid_until < quoteBusinessDate() ? '' : admin.valid_until); setTerms(admin.terms ?? '');
    const restored = admin.items.map((item): QuoteDraftLine => { const kind = item.kind === 'product' ? 'product' : 'manual_service'; const productId = String(item.product_id ?? ''); return { ...emptyQuoteLine(kind), productId, variantId: String(item.variant_id ?? ''), title: String(item.title ?? ''), quantity: String(item.quantity ?? '1'), width: String((item.dimensions as { width_cm?: string } | null)?.width_cm ?? ''), height: String((item.dimensions as { height_cm?: string } | null)?.height_cm ?? ''), unitPrice: String(item.unit_price ?? ''), priceOverride: kind === 'product' && Boolean(item.price_override), overrideReason: String(item.price_override_reason ?? (kind === 'manual_service' ? '' : '')), details: String(item.details ?? ''), personalization: item.personalization ? JSON.stringify(item.personalization) : '', productionDate: String(item.production_date ?? ''), deliveryDate: String(item.delivery_date ?? '') }; }); setLines(restored.length ? restored : [emptyQuoteLine()]); setActiveLine(0); setRevision(quote); setSuccess('Itens carregados. Revise preços e composição e informe uma nova validade se a anterior expirou. Produtos fora do catálogo exigem correção antes da emissão.');
  } catch (e) { setError(e instanceof Error ? e.message : 'Não foi possível carregar a proposta para revisão.'); } finally { setBusy(false); } };
  const confirmRevoke = async () => { if (!organizationId || !revoking || !reason.trim()) return; setBusy(true); try { await revokeQuote(organizationId, revoking, reason.trim(), crypto.randomUUID()); setSuccess('Orçamento revogado.'); setRevoking(null); void load(true); } catch (e) { setError(e instanceof Error ? e.message : 'Não foi possível revogar.'); } finally { setBusy(false); } };
  if (!allowed) return <><PageHeader eyebrow="Orçamentos" title="Acesso restrito"/><Alert kind="warning">Seu papel não pode gerenciar orçamentos.</Alert></>;
  const updateLine = (index: number, patch: Partial<QuoteDraftLine>) => setLines((current) => current.map((line, i) => i === index ? { ...line, ...patch } : line));
  return <><PageHeader eyebrow="Vendas públicas" title="Orçamentos" description="Emita propostas sem criar pedido. Somente a aprovação do cliente cria um pedido real."/><section className="panel"><h2>{revision ? 'Revisar orçamento enviado' : 'Novo orçamento'}</h2>{revision && <Alert kind="warning">Produtos, preços e composições atuais serão re-resolvidos pelo servidor. Revise a proposta atualizada com o cliente antes de emitir.</Alert>}{error && <Alert kind="error">{error}</Alert>}{success && <Alert kind="success">{success}</Alert>}{issuedLink && <p><a href={issuedLink} target="_blank" rel="noreferrer">{issuedLink}</a> <Button variant="secondary" disabled={busy} onClick={() => void navigator.clipboard.writeText(issuedLink).then(() => setSuccess('Link do orçamento copiado.')).catch(() => setError('Não foi possível copiar o link.'))}>Copiar link</Button></p>}
    <form onSubmit={(e) => void submit(e)}><div className="form-grid"><Field label="Cliente ativo"><Select disabled={busy} value={clientId} onChange={(e) => setClientId(e.target.value)}><option value="">Selecione cliente ativo</option>{catalog.clients.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field><Field label="Título"><Input disabled={busy} value={title} onChange={(e) => setTitle(e.target.value)} required/></Field><Field label="Data do pedido"><Input disabled={busy} type="date" value={orderDate} onChange={(e) => setOrderDate(e.target.value)}/></Field><Field label="Produção prevista"><Input disabled={busy} type="date" value={productionDate} onChange={(e) => setProductionDate(e.target.value)}/></Field><Field label="Entrega prevista"><Input disabled={busy} type="date" value={deliveryDate} onChange={(e) => setDeliveryDate(e.target.value)}/></Field><Field label="Validade" hint="Válido até o fim do dia no horário de Brasília."><Input disabled={busy} type="date" min={quoteBusinessDate()} value={valid} onChange={(e) => setValid(e.target.value)} required/></Field></div>
    <div className="order-form-section"><div className="subsection-heading"><div><h3>Itens</h3><p>O RPC vigente resolve e congela preço e composição. Valores mostrados são apenas estimativas.</p></div><div className="form-actions-inline"><Button type="button" variant="secondary" icon={<Plus size={15}/>} disabled={busy} onClick={() => { setLines((v) => [...v, emptyQuoteLine('product')]); setActiveLine(lines.length); }}>Produto</Button><Button type="button" variant="ghost" icon={<Plus size={15}/>} disabled={busy} onClick={() => { setLines((v) => [...v, emptyQuoteLine()]); setActiveLine(lines.length); }}>Serviço manual</Button></div></div><div className="order-item-tabs" role="tablist">{lines.map((line, i) => <button type="button" role="tab" aria-selected={activeLine === i} className={activeLine === i ? 'active' : ''} key={i} onClick={() => setActiveLine(i)}>Item {i+1}<small>{line.kind === 'product' ? catalog.products.find((p) => p.id === line.productId)?.name ?? 'Produto' : line.title || 'Serviço manual'}</small></button>)}</div>{lines[activeLine] && <><QuoteLineEditor line={lines[activeLine]} index={activeLine} products={catalog.products} organizationId={organizationId} busy={busy} onChange={(patch) => updateLine(activeLine, patch)}/>{lines.length > 1 && <Button type="button" variant="ghost" icon={<Trash2 size={15}/>} disabled={busy} onClick={() => { const next = lines.filter((_, i) => i !== activeLine); setLines(next); setActiveLine(Math.max(0, activeLine - 1)); }}>Remover item</Button>}</>}</div>
    <div className="form-grid"><Field label="Desconto"><Select disabled={busy} value={discountType} onChange={(e) => setDiscountType(e.target.value as typeof discountType)}><option value="none">Sem desconto</option><option value="fixed">Valor fixo</option><option value="percent">Percentual</option></Select></Field>{discountType !== 'none' && <Field label="Valor do desconto"><Input disabled={busy} inputMode="decimal" value={discount} onChange={(e) => setDiscount(e.target.value)}/></Field>}<Field label="Frete"><Input disabled={busy} inputMode="decimal" value={shipping} onChange={(e) => setShipping(e.target.value)}/></Field></div><Field label="Termos"><Textarea disabled={busy} value={terms} onChange={(e) => setTerms(e.target.value)} maxLength={20000}/></Field><Field label="Observações públicas"><Textarea disabled={busy} value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={5000}/></Field><Button type="submit" loading={busy}>{revision ? 'Emitir revisão' : 'Emitir orçamento'}</Button>{revision && <Button type="button" variant="secondary" disabled={busy} onClick={() => setRevision(null)}>Cancelar revisão</Button>}</form></section>
    <section className="panel"><div className="panel-heading"><div><h2>Propostas</h2><p>Listagem paginada por cursor.</p></div><Button variant="secondary" disabled={loading} onClick={() => void load(true)}>Atualizar</Button></div>{loading && <Loading label="Carregando orçamentos…"/>}{!quotes.length && !loading ? <EmptyState title="Nenhum orçamento" description="As propostas emitidas aparecerão aqui."/> : <div className="simple-list">{quotes.map((q) => <article key={q.quote_id}><span><strong>{q.title}</strong><br/>{q.client_name_snapshot} · {{ Sent: 'Enviado', Expired: 'Expirado', Revoked: 'Revogado', Approved: 'Aprovado' }[q.status]} · vence {formatDate(q.valid_until)}</span><strong>{formatCurrency(q.total_amount)}</strong>{q.status !== 'Revoked' && q.status !== 'Expired' && q.valid_until >= quoteBusinessDate() && <a href={`/orcamento/${q.public_token}`} target="_blank" rel="noreferrer">Abrir proposta</a>}{(q.status === 'Sent' || q.status === 'Expired') && <><Button variant="secondary" disabled={busy} onClick={() => void startRevision(q)}>Iniciar revisão</Button><Button variant="danger" disabled={busy} onClick={() => startRevoke(q.quote_id)}>Revogar</Button></>}{revoking === q.quote_id && <div><Field label="Motivo obrigatório"><Input disabled={busy} value={reason} onChange={(e) => setReason(e.target.value)}/></Field><Button variant="danger" disabled={busy || !reason.trim()} loading={busy} onClick={() => void confirmRevoke()}>Confirmar revogação</Button><Button variant="secondary" disabled={busy} onClick={() => setRevoking(null)}>Cancelar</Button></div>}</article>)}</div>}{cursor && <Button variant="secondary" loading={loading} onClick={() => void load(false)}>Carregar mais</Button>}</section></>;
}

export function PublicQuotePage() {
  const { id = '' } = useParams();
  const { data: quote, loading, error, refresh } = usePublicCapability<PublicQuote>(id, fetchPublicQuote);
  const [busy, setBusy] = useState(false);
  const [approvalError, setApprovalError] = useState('');
  const actionGeneration = useRef(0);
  const currentId = useRef(id);
  currentId.current = id;
  const navigate = useNavigate();

  useEffect(() => {
    actionGeneration.current += 1;
    setBusy(false);
    setApprovalError('');
    return () => { actionGeneration.current += 1; };
  }, [id]);

  const approve = async () => {
    if (!isUuid(id) || busy) return;
    const action = actionGeneration.current;
    setBusy(true);
    setApprovalError('');
    try {
      const result = await approvePublicQuote(id);
      if (!result?.tracking_token || !isUuid(result.tracking_token)) {
        throw new Error('Resposta inconclusiva.');
      }
      if (actionGeneration.current === action && currentId.current === id) navigate(`/rastreio/${result.tracking_token}`, { replace: true });
    } catch {
      if (actionGeneration.current === action && currentId.current === id) {
        setApprovalError('Não foi possível concluir a solicitação. Verifique se o link ainda está válido ou peça ajuda à loja.');
        void refresh();
      }
    } finally {
      if (actionGeneration.current === action && currentId.current === id) setBusy(false);
    }
  };

  if (loading) return <Loading label="Carregando orçamento…"/>;
  if (error) return <main className="main-inner"><Alert kind="error">{error}</Alert><Button variant="secondary" onClick={() => void refresh(true)}>Tentar novamente</Button></main>;
  if (!quote) return <main className="main-inner"><EmptyState title="Orçamento indisponível" description="O link está incorreto, expirado ou revogado. Solicite uma nova proposta à loja."/></main>;

  return <main className="main-inner public-sales">
    <PageHeader eyebrow={quote.brand} title={quote.title} description={`Orçamento válido até ${formatDate(quote.valid_until)}, no horário de Brasília`}/>
    {approvalError && <Alert kind="error">{approvalError}</Alert>}
    <section className="panel">
      <div className="order-items-detail">{quote.items.map((item, i) => <article className="order-item-detail" key={i}><strong>{item.title}</strong><span>{item.quantity} {item.billing_unit} × {formatCurrency(item.unit_price)}</span><b>{formatCurrency(item.line_amount)}</b></article>)}</div>
      <div className="order-metric-grid"><div>Subtotal <b>{formatCurrency(quote.subtotal)}</b></div><div>Desconto <b>{formatCurrency(quote.discount_amount)}</b></div><div>Frete <b>{formatCurrency(quote.shipping_amount)}</b></div><div>Total <b>{formatCurrency(quote.total_amount)}</b></div></div>
      {quote.public_notes && <p>{quote.public_notes}</p>}
      {quote.terms && <><h2>Termos</h2><p>{quote.terms}</p></>}
      <p>Entrega prevista: {formatDate(quote.delivery_date)}</p>
      {quote.status === 'Sent' && <Button loading={busy} disabled={busy} onClick={() => void approve()}>Aprovar Orçamento</Button>}
      {quote.status === 'Approved' && (quote.tracking_available
        ? <><Alert kind="success">Este orçamento já foi aprovado. Recupere o rastreio com segurança.</Alert><Button loading={busy} disabled={busy} onClick={() => void approve()}>Recuperar link de rastreio</Button></>
        : <Alert kind="warning">Este orçamento já foi aprovado, mas o rastreio original está indisponível. Solicite um novo link à loja.</Alert>)}
    </section>
  </main>;
}

export function PublicTrackingPage() {
  const { id = '' } = useParams();
  const { data, loading, error, refresh } = usePublicCapability<Tracking>(id, fetchTracking);
  const [connection, setConnection] = useState<'connecting' | 'connected' | 'reconnecting'>('connecting');

  useEffect(() => {
    let active = true;
    setConnection('connecting');
    if (!supabase || !isUuid(id)) return () => { active = false; };
    const channel = supabase.channel(`tracking:${id}`, { config: { private: false } })
      .on('broadcast', { event: 'status' }, () => { if (active) void refresh(); })
      .subscribe((status) => { if (active) setConnection(status === 'SUBSCRIBED' ? 'connected' : 'reconnecting'); });
    return () => { active = false; void supabase?.removeChannel(channel); };
  }, [id, refresh]);

  if (loading) return <Loading label="Consultando rastreio…"/>;
  if (error) return <main className="main-inner"><Alert kind="error">{error}</Alert><Button variant="secondary" onClick={() => void refresh(true)}>Atualizar</Button></main>;
  if (!data) return <main className="main-inner"><EmptyState title="Rastreio indisponível" description="O link expirou, foi revogado ou não existe. Solicite um novo link à loja."/></main>;
  return <main className="main-inner public-sales"><PageHeader eyebrow={data.brand} title={data.title} description={`Pedido ${data.code} · ${data.status}`}/><section className="panel"><p>Atualização ao vivo: {connection === 'connected' ? 'conectado' : connection === 'reconnecting' ? 'reconectando' : 'conectando…'}</p><Button variant="secondary" onClick={() => void refresh(true)}>Atualizar agora</Button><p>Data do pedido: {formatDate(data.order_date)}</p><p>Previsão de produção: {formatDate(data.production_date)}</p><p>Previsão de entrega: {formatDate(data.delivery_date)}</p><h2>Histórico</h2><div className="event-history">{data.history.map((item, i) => <div key={`${item.status_version}-${i}`}><span className="event-dot"/><div><strong>{item.status}</strong><small>Versão {item.status_version} · {formatDate(item.created_at)}</small></div></div>)}</div></section></main>;
}
