import { useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { Alert, Button, EmptyState, Loading, PageHeader } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';
import { useAllOrdersQuery, useSetOrderStatusMutation } from './api';
import type { OrderDto, OrderStatus } from './types';
import { canCancelAfterConsumption, canCancelBeforeConsumption, canSetProductionStage, statusTransitions } from './types';
import { formatCurrency, formatDate } from '../../lib/format';
import { newIdempotencyKey } from './utils';
import './orders.css';

const columns: Array<{ status: OrderStatus; title: string }> = [
  { status: 'Pendente', title: 'Pendente' },
  { status: 'Em Produção', title: 'Em produção' },
  { status: 'Concluído', title: 'Concluído' },
  { status: 'Entregue', title: 'Entregue' },
  { status: 'Cancelado', title: 'Cancelado' },
];

export function ProductionPage() {
  const { organizationId, currentMembershipRole } = useSession();
  const query = useAllOrdersQuery(organizationId);
  const mutation = useSetOrderStatusMutation(organizationId, null);
  const nonces = useRef(new Map<string, string>());
  const [dragged, setDragged] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const canStage = canSetProductionStage(currentMembershipRole);
  const orders = query.data ?? [];
  const change = async (order: OrderDto, status: OrderStatus) => {
    if (!organizationId || !canStage || !statusTransitions[order.status].includes(status)) return;
    const intent = `${order.id}:${status}`;
    const key = nonces.current.get(intent) ?? newIdempotencyKey();
    nonces.current.set(intent, key);
    setError(null);
    try { await mutation.mutateAsync({ organizationId, orderId: order.id, status, reason: null, idempotencyKey: key }); nonces.current.delete(intent); }
    catch (changeError) { setError(changeError instanceof Error ? changeError.message : 'Não foi possível confirmar a etapa.'); }
  };
  const cancelAllowed = (order: OrderDto) => order.inventory_deducted ? canCancelAfterConsumption(currentMembershipRole) : canCancelBeforeConsumption(currentMembershipRole);

  return <>
    <PageHeader eyebrow="Operação" title="Produção" description="Kanban dos pedidos reais. Cada mudança de etapa consulta e confirma o RPC; não há status local simulado." />
    {error ? <Alert kind="error">{error}</Alert> : null}
    {query.isLoading ? <Loading label="Consultando pedidos reais para produção…" /> : query.error ? <Alert kind="error">{query.error instanceof Error ? query.error.message : 'Não foi possível carregar o Kanban real.'}</Alert> : !orders.length ? <EmptyState title="Sem pedidos para produção" description="Quando houver pedidos reais, eles aparecerão por etapa nesta visão." /> : <div className="kanban-board" aria-label="Kanban de produção">{columns.map((column) => <section className="kanban-column" key={column.status} onDragOver={(event) => event.preventDefault()} onDrop={() => { const order = orders.find((candidate) => candidate.id === dragged); if (order) void change(order, column.status); setDragged(null); }}><div className="kanban-column-heading"><h2>{column.title}</h2><span>{orders.filter((order) => order.status === column.status).length}</span></div><div className="kanban-cards">{orders.filter((order) => order.status === column.status).map((order) => <article className="kanban-card" key={order.id} draggable={canStage && order.status !== 'Entregue'} onDragStart={() => setDragged(order.id)} onDragEnd={() => setDragged(null)}><div className="kanban-card-top"><Link className="text-link" to={`/pedidos/${order.id}`}>{order.code}</Link><span>{order.item_count} item(ns)</span></div><Link to={`/pedidos/${order.id}`}><h3>{order.title}</h3><p>{order.client_name}</p></Link><div className="kanban-card-meta"><span>entrega {formatDate(order.delivery_date)}</span><strong>{formatCurrency(order.total_amount)}</strong></div><div className="kanban-card-actions">{statusTransitions[order.status].filter((status) => status !== 'Cancelado').map((status) => <Button key={status} variant="ghost" disabled={!canStage} loading={mutation.isPending && mutation.variables?.orderId === order.id && mutation.variables.status === status} onClick={() => void change(order, status)}>→ {status}</Button>)}{statusTransitions[order.status].includes('Cancelado') && cancelAllowed(order) ? <Link className="text-link" to={`/pedidos/${order.id}`}>Cancelar no detalhe</Link> : null}</div></article>)}</div>{orders.filter((order) => order.status === column.status).length === 0 ? <p className="kanban-empty">Nenhum pedido real nesta etapa.</p> : null}</section>)}</div>}
    {!canStage ? <Alert kind="info">Seu papel é somente leitura para etapas de produção. O backend continua sendo a autoridade das permissões.</Alert> : null}
  </>;
}
