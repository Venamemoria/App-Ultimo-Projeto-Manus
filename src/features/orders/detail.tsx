import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowLeft, CheckCircle2, CreditCard, Printer, XCircle } from 'lucide-react';
import { Link, useParams } from 'react-router-dom';
import { Alert, Button, Field, Input, Loading, Modal, Select, Textarea } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';
import { recordOrderPayment, setOrderStatus, useOrderDetailQuery, useRecordOrderPaymentMutation, useSetOrderStatusMutation } from './api';
import type { OrderBundle, OrderStatus, PaymentMethod } from './types';
import { canCancelAfterConsumption, canCancelBeforeConsumption, canRecordPayment, canSetProductionStage, PAYMENT_METHODS, statusTransitions } from './types';
import { formatCurrency, formatDate } from '../../lib/format';
import { Decimal } from '../../lib/decimal';
import { canViewFinance } from '../../lib/permissions';
import { isIsoDate, newIdempotencyKey, paymentMethodLabels, todayIso } from './utils';
import { OrderReturnsSection } from './returns';
import { fetchOrderTracking, issueTracking, revokeTracking } from '../publicSales/api';
import './orders.css';

export function OrderDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { organizationId, currentMembershipRole } = useSession();
  const canReadFinance = canViewFinance(currentMembershipRole);
  const query = useOrderDetailQuery(organizationId, id ?? null, canReadFinance);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [paymentOpen, setPaymentOpen] = useState(false);
  const [cancelReason, setCancelReason] = useState('');
  const [statusError, setStatusError] = useState<string | null>(null);
  const [selectedStatus, setSelectedStatus] = useState<OrderStatus | null>(null);
  const [statusKey, setStatusKey] = useState(newIdempotencyKey);
  const statusIntent = useRef<string | null>(null);
  const [paymentKey, setPaymentKey] = useState(newIdempotencyKey);
  const paymentIntent = useRef<string | null>(null);
  const [paymentError, setPaymentError] = useState<string | null>(null);
  const statusMutation = useSetOrderStatusMutation(organizationId, id ?? null);
  const paymentMutation = useRecordOrderPaymentMutation(organizationId, id ?? null);
  const [payment, setPayment] = useState({ amount: '', date: todayIso(), method: 'pix' as PaymentMethod });
  const [tracking, setTracking] = useState<{ tracking_token: string; expires_at: string } | null>(null);
  const [trackingExpiry, setTrackingExpiry] = useState('30');
  const [trackingError, setTrackingError] = useState('');
  const [trackingSuccess, setTrackingSuccess] = useState('');
  const [trackingBusy, setTrackingBusy] = useState(false);
  const [confirmTrackingRevoke, setConfirmTrackingRevoke] = useState(false);
  const trackingIntent = useRef<{ days: string; expiresAt: string; nonce: string } | null>(null);
  const trackingNonce = useRef<string | null>(null);

  const canManageTracking = canRecordPayment(currentMembershipRole);
  const refreshTracking = useCallback(async () => {
    if (!organizationId || !id) return;
    try { setTracking(await fetchOrderTracking(organizationId, id)); setTrackingError(''); } catch (error) { setTrackingError(error instanceof Error ? error.message : 'Não foi possível consultar o link de rastreio.'); }
  }, [organizationId, id]);
  useEffect(() => { if (organizationId && id && canManageTracking) void refreshTracking(); }, [organizationId, id, canManageTracking, refreshTracking]);
  if (!id || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) return <><Link className="text-link" to="/pedidos"><ArrowLeft size={15} />Voltar para pedidos</Link><Alert kind="error">O identificador do pedido é inválido; nenhuma consulta foi enviada.</Alert></>;
  if (query.isLoading) return <Loading label="Consultando o pedido real…" />;
  if (query.error || !query.data) return <><Link className="text-link" to="/pedidos"><ArrowLeft size={15} />Voltar para pedidos</Link><Alert kind="error">{query.error instanceof Error ? query.error.message : 'Pedido não encontrado nesta organização.'}</Alert></>;

  const { order, items, events, consumptions, payments } = query.data;
  const missingProductRecipe = items.some((item) => item.kind === 'product' && item.product_snapshot?.inventory_mode !== 'no_stock' && (!Array.isArray(item.recipe_snapshot) || item.recipe_snapshot.length === 0));
  const issueTrackingLink = async () => {
    if (!organizationId || !id) return;
    const pending = trackingIntent.current;
    const days = pending?.days ?? trackingExpiry;
    const expiry = pending?.expiresAt ?? new Date(Date.now() + Number(days) * 86400000).toISOString();
    const nonce = pending?.nonce ?? crypto.randomUUID();
    trackingIntent.current = { days, expiresAt: expiry, nonce };
    setTrackingBusy(true); setTrackingError(''); setTrackingSuccess('');
    try {
      const result = await issueTracking(organizationId, id, expiry, nonce);
      if (!result) throw new Error('A emissão não foi confirmada. Repetir manterá a mesma intenção.'); trackingIntent.current = null; setTracking(result); setTrackingSuccess('Novo link emitido. O link anterior foi revogado imediatamente.');
    } catch (error) { setTrackingError(error instanceof Error ? error.message : 'Não foi possível emitir o link. Repetir mantém a mesma solicitação.'); }
    finally { setTrackingBusy(false); }
  };
  const revokeTrackingLink = async () => {
    if (!organizationId || !tracking) return;
    const nonce = trackingNonce.current ?? crypto.randomUUID(); trackingNonce.current = nonce;
    setTrackingBusy(true); setTrackingError('');
    try { await revokeTracking(organizationId, tracking.tracking_token, nonce); trackingNonce.current = null; setTracking(null); setConfirmTrackingRevoke(false); setTrackingSuccess('Link de rastreio revogado.'); }
    catch (error) { setTrackingError(error instanceof Error ? error.message : 'Não foi possível revogar. Tentar novamente é seguro.'); }
    finally { setTrackingBusy(false); }
  };
  const canStage = canSetProductionStage(currentMembershipRole);
  const available = statusTransitions[order.status].filter((status) => {
    if (status === 'Cancelado') return order.inventory_deducted ? canCancelAfterConsumption(currentMembershipRole) : canCancelBeforeConsumption(currentMembershipRole);
    return canStage;
  });
  const changeStatus = async (status: OrderStatus, reason: string | null = null) => {
    if (!organizationId || !id) return;
    const intent = `${status}|${reason ?? ''}`;
    const key = statusIntent.current === intent ? statusKey : newIdempotencyKey();
    if (statusIntent.current !== intent) {
      statusIntent.current = intent;
      setStatusKey(key);
    }
    setSelectedStatus(status);
    setStatusError(null);
    try { await statusMutation.mutateAsync({ organizationId, orderId: id, status, reason, idempotencyKey: key }); statusIntent.current = null; setStatusKey(newIdempotencyKey()); if (status === 'Cancelado') setCancelOpen(false); }
    catch (error) { setStatusError(error instanceof Error ? error.message : 'Não foi possível confirmar a etapa.'); }
    finally { setSelectedStatus(null); }
  };
  const submitPayment = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!organizationId || !id || !canReadFinance) return;
    setPaymentError(null);
    if (!payment.amount.trim()) { setPaymentError('Informe um valor positivo em moeda com até duas casas.'); return; }
    if (!isIsoDate(payment.date) || payment.date > todayIso()) { setPaymentError('A data do recebimento deve ser válida e não futura.'); return; }
    const intent = `${payment.amount}|${payment.date}|${payment.method}`;
    const key = paymentIntent.current === intent ? paymentKey : newIdempotencyKey();
    if (paymentIntent.current !== intent) { paymentIntent.current = intent; setPaymentKey(key); }
    try { await paymentMutation.mutateAsync({ organizationId, orderId: id, amount: payment.amount, paymentDate: payment.date, method: payment.method, idempotencyKey: key }); paymentIntent.current = null; setPaymentKey(newIdempotencyKey()); setPaymentOpen(false); setPayment({ amount: '', date: todayIso(), method: 'pix' }); }
    catch (error) { setPaymentError(error instanceof Error ? error.message : 'Não foi possível confirmar o recebimento.'); }
  };

  return <>
    <div className="detail-topline"><Link className="text-link" to="/pedidos"><ArrowLeft size={15} />Voltar para pedidos</Link><Button variant="secondary" icon={<Printer size={15} />} onClick={() => window.print()}>Imprimir</Button></div>
    <div className="order-detail-heading"><div><p className="eyebrow">Pedido {order.code}</p><h1>{order.title}</h1><p className="page-description">{order.client_name} · criado em {formatDate(order.created_at)}</p></div><span className={`status-pill order-status-${order.status.toLowerCase().replace(/[^a-zà-ú]+/gi, '-')}`}>{order.status}</span></div>
    {statusError ? <Alert kind="error">{statusError}</Alert> : null}
    {missingProductRecipe && !order.inventory_deducted && <Alert kind="warning">Este pedido tem produto sem composição congelada. Solicite ao responsável a revisão ou recriação com insumos; editar o catálogo não altera este histórico. A produção não será iniciada sem uma receita válida.</Alert>}
    {canManageTracking ? <section className="panel"><div className="order-detail-section-heading"><div><h2>Link público de rastreio</h2><p>O link não contém dados internos. Emitir outro revoga o link atual imediatamente.</p></div><Button variant="secondary" disabled={trackingBusy} onClick={() => void refreshTracking()}>Atualizar</Button></div>{trackingError && <Alert kind="error">{trackingError}</Alert>}{trackingSuccess && <Alert kind="success">{trackingSuccess}</Alert>}{tracking ? <><p>Ativo até {formatDate(tracking.expires_at)}</p><p><code>{`${window.location.origin}/rastreio/${tracking.tracking_token}`}</code></p><Button variant="secondary" disabled={trackingBusy} onClick={() => void navigator.clipboard.writeText(`${window.location.origin}/rastreio/${tracking.tracking_token}`).then(() => setTrackingSuccess('Link copiado.')).catch(() => setTrackingError('Não foi possível copiar o link.'))}>Copiar link relativo</Button><Button variant="danger" disabled={trackingBusy} onClick={() => setConfirmTrackingRevoke(true)}>Revogar link</Button></> : <p>Nenhum link ativo.</p>}<Field label="Validade do novo link"><Select disabled={trackingBusy || trackingIntent.current !== null} value={trackingExpiry} onChange={(event) => setTrackingExpiry(event.target.value)}><option value="1">1 dia</option><option value="7">7 dias</option><option value="30">30 dias</option><option value="90">90 dias</option><option value="365">365 dias</option></Select></Field><Button disabled={trackingBusy} loading={trackingBusy} onClick={() => void issueTrackingLink()}>{tracking ? 'Emitir/rotacionar link' : 'Emitir link'}</Button>{confirmTrackingRevoke && <div role="alertdialog" aria-label="Confirmar revogação"><Alert kind="warning">O link atual deixará de funcionar imediatamente.</Alert><Button variant="danger" disabled={trackingBusy} loading={trackingBusy} onClick={() => void revokeTrackingLink()}>Confirmar revogação</Button><Button variant="secondary" disabled={trackingBusy} onClick={() => setConfirmTrackingRevoke(false)}>Cancelar</Button></div>}</section> : null}
    <section className="panel order-stage-panel"><div className="order-detail-section-heading"><div><h2>Etapa operacional</h2><p>A transição é confirmada pelo RPC; a tela não altera status localmente.</p></div>{order.inventory_deducted ? <span className="truth-badge"><CheckCircle2 size={15} /> {consumptions.length ? 'baixa registrada' : 'processado sem baixa de materiais'}</span> : null}</div><div className="stage-actions">{available.map((status) => <Button key={status} variant={status === 'Cancelado' ? 'danger' : 'secondary'} disabled={missingProductRecipe && !order.inventory_deducted && (status === 'Em Produção' || status === 'Concluído')} loading={selectedStatus === status} icon={status === 'Cancelado' ? <XCircle size={15} /> : undefined} onClick={() => status === 'Cancelado' ? setCancelOpen(true) : void changeStatus(status)}>{status}</Button>)}</div>{order.status === 'Cancelado' ? <Alert kind="warning">Cancelado não devolve estoque automaticamente e não reembolsa pagamentos. Qualquer compensação física ou reembolso exige fluxo próprio autorizado.</Alert> : null}</section>
    <div className="order-detail-grid">
      <section className="panel">
        <div className="order-detail-section-heading"><div><h2>{canReadFinance ? 'Resumo comercial' : 'Dados do pedido'}</h2><p>{canReadFinance ? 'Valores atuais nas views financeiras reais.' : 'Informações operacionais do pedido.'}</p></div>{canReadFinance && order.status !== 'Cancelado' && order.balance_amount !== null && new Decimal(order.balance_amount).gt(0) ? <Button icon={<CreditCard size={15} />} onClick={() => { setPaymentOpen(true); setPaymentError(null); }}>Registrar recebimento</Button> : null}</div>
        {canReadFinance && <div className="order-metric-grid"><Metric label="Subtotal" value={formatCurrency(order.subtotal)} /><Metric label="Desconto" value={formatCurrency(order.discount_amount)} /><Metric label="Frete" value={formatCurrency(order.shipping_amount)} /><Metric label="Total" value={formatCurrency(order.total_amount)} /><Metric label="Recebido real" value={formatCurrency(order.paid_amount)} /><Metric label="Saldo" value={formatCurrency(order.balance_amount)} /></div>}
        <div className="detail-grid order-info-grid"><div><span>Cliente</span><strong>{order.client_name}</strong></div><div><span>Data do pedido</span><strong>{formatDate(order.order_date)}</strong></div><div><span>Produção</span><strong>{formatDate(order.production_date)}</strong></div><div><span>Entrega</span><strong>{formatDate(order.delivery_date)}</strong></div><div><span>Versão de status</span><strong>{order.status_version}</strong></div></div>
      </section>
      <section className="panel"><div className="order-detail-section-heading"><div><h2>Notas</h2><p>Públicas e internas ficam separadas pelo backend.</p></div></div><div className="notes-block"><h3>Nota pública</h3><p>{order.public_notes || 'Nenhuma nota pública real.'}</p><h3>Nota interna</h3><p>{order.internal_notes || 'Nenhuma nota interna real.'}</p></div></section>
    </div>
    <section className="panel"><div className="order-detail-section-heading"><div><h2>Itens e receita congelada</h2><p>{canReadFinance ? 'Somente leitura; os custos abaixo são snapshots do pedido, não catálogo atual.' : 'Quantidades e composição necessárias para a operação.'}</p></div></div><div className="order-items-detail">{items.map((item) => <article className="order-item-detail" key={item.id}><div className="order-item-detail-head"><div><strong>{item.title}</strong><span>{item.kind === 'manual_service' ? 'Serviço manual' : `Produto · ${item.billing_unit}`}</span></div>{canReadFinance ? <div className="order-item-amount"><strong>{formatCurrency(item.line_amount)}</strong><span>{item.quantity} × {formatCurrency(item.unit_price)}</span></div> : <strong>{item.quantity} {item.billing_unit}</strong>}</div><div className="detail-grid"><div><span>Quantidade cobrável</span><strong>{item.billed_quantity}</strong></div>{canReadFinance && <><div><span>Fonte do preço</span><strong>{item.price_source === 'catalog' ? 'Catálogo vigente' : item.price_source === 'manual' ? 'Manual' : item.price_source === 'override' ? 'Override' : '—'}</strong></div><div><span>Custo composição</span><strong>{item.unit_composition_cost ?? '—'}</strong></div><div><span>Custo total item</span><strong>{item.total_composition_cost ?? '—'}</strong></div></>}</div>{canReadFinance && item.price_override_reason ? <p className="detail-footnote">Motivo do preço: {item.price_override_reason}</p> : null}{item.details ? <p className="detail-text">{item.details}</p> : null}<RecipeList item={item} showCost={canReadFinance} /></article>)}</div></section>
    <div className="order-detail-grid"><section className="panel"><div className="order-detail-section-heading"><div><h2>Consumo real</h2><p>Movimentos e snapshots retornados pelas views autorizadas.</p></div></div>{consumptions.length ? <div className="simple-list">{consumptions.map((consumption) => <div key={`${consumption.material_id}-${consumption.movement_id}`}><span>{consumption.material_id.slice(0, 8)} · {consumption.unit}</span><strong>{consumption.quantity}</strong><small>saldo após {consumption.stock_after}</small></div>)}</div> : <p className="detail-text">Nenhuma baixa registrada para este pedido.</p>}</section>{canReadFinance && <section className="panel"><div className="order-detail-section-heading"><div><h2>Pagamentos reais</h2><p>Nenhuma quitação é inferida pela produção.</p></div></div>{payments.length ? <div className="simple-list">{payments.map((payment) => <div key={payment.id}><span>{formatDate(payment.payment_date)} · {paymentMethodLabels[payment.method]}</span><strong>{formatCurrency(payment.amount)}</strong><small>caixa {payment.cash_entry_id.slice(0, 8)}</small></div>)}</div> : <p className="detail-text">Nenhum pagamento real registrado.</p>}</section>}</div>
    {order.status === 'Cancelado' && order.consumed_at && consumptions.length ? <OrderReturnsSection organizationId={organizationId} order={order} items={items} consumptions={consumptions} currentMembershipRole={currentMembershipRole} /> : null}
    <section className="panel"><div className="order-detail-section-heading"><div><h2>Histórico de eventos</h2><p>Eventos confirmados na mesma transação das etapas.</p></div></div><div className="event-history">{events.map((event) => <div key={event.id}><span className="event-dot" /><div><strong>{event.status}</strong><small>{event.event_type === 'created' ? 'Pedido criado' : 'Etapa alterada'} · {formatDate(event.created_at)}</small>{event.reason ? <p>{event.reason}</p> : null}</div><b>v{event.status_version}</b></div>)}</div></section>
    <Modal title="Cancelar pedido" open={cancelOpen} onClose={() => setCancelOpen(false)}><Alert kind="warning">O cancelamento não devolve materiais consumidos e não inicia reembolso. O motivo fica no histórico auditável.</Alert><Field label="Motivo obrigatório"><Textarea value={cancelReason} maxLength={2000} onChange={(event) => setCancelReason(event.target.value)} /></Field><div className="form-actions"><Button variant="secondary" onClick={() => setCancelOpen(false)}>Voltar</Button><Button variant="danger" loading={selectedStatus === 'Cancelado'} disabled={!cancelReason.trim()} onClick={() => void changeStatus('Cancelado', cancelReason.trim())}>Confirmar cancelamento</Button></div></Modal>
    {canReadFinance && <Modal title="Registrar recebimento real" open={paymentOpen} onClose={() => setPaymentOpen(false)}><form className="payment-form" onSubmit={submitPayment}>{paymentError ? <Alert kind="error">{paymentError}</Alert> : null}<Field label="Valor (BRL)" hint="Positivo, com até duas casas; nunca maior que o saldo real."><Input value={payment.amount} inputMode="decimal" onChange={(event) => setPayment((current) => ({ ...current, amount: event.target.value }))} /></Field><Field label="Data efetiva"><Input type="date" max={todayIso()} value={payment.date} onChange={(event) => setPayment((current) => ({ ...current, date: event.target.value }))} /></Field><Field label="Método"><Select value={payment.method} onChange={(event) => setPayment((current) => ({ ...current, method: event.target.value as PaymentMethod }))}>{PAYMENT_METHODS.map((method) => <option key={method} value={method}>{paymentMethodLabels[method]}</option>)}</Select></Field><div className="form-actions"><Button type="button" variant="secondary" onClick={() => setPaymentOpen(false)}>Cancelar</Button><Button type="submit" loading={paymentMutation.isPending}>Registrar no caixa</Button></div></form></Modal>}
  </>;
}

function Metric({ label, value }: { label: string; value: string }) { return <div className="order-metric"><span>{label}</span><strong>{value}</strong></div>; }

function RecipeList({ item, showCost }: { item: OrderBundle['items'][number]; showCost: boolean }) {
  if (!item.recipe_snapshot.length) return <p className="detail-footnote">{item.kind === 'manual_service' ? 'Serviço manual sem receita de estoque.' : item.product_snapshot?.inventory_mode === 'no_stock' ? 'Produto classificado sem consumo de estoque.' : 'Produto sem composição congelada.'}</p>;
  return <details className="recipe-details"><summary>Ver composição congelada ({item.recipe_snapshot.length})</summary><div className="simple-list">{item.recipe_snapshot.map((recipe) => <div key={recipe.material_id}><span>{recipe.material_name} · {recipe.unit}</span><strong>{recipe.consumption_quantity}</strong><small>fração {recipe.quantitySnapshot}{showCost ? ` · custo ${recipe.consumption_cost ?? '—'}` : ''}</small></div>)}</div></details>;
}
