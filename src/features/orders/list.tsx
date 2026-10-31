import { useEffect, useRef, useState } from 'react';
import { Download, Plus, Search } from 'lucide-react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { Alert, Button, EmptyState, Field, Input, Loading, PageHeader, Select } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';
import { fetchAllOrders, normalizeOrderFilters, useOrdersPageQuery } from './api';
import { NewOrderModal } from './form';
import type { OrderListFilters, OrderStatus } from './types';
import { canCreateOrders, ORDER_STATUSES } from './types';
import { canViewFinance } from '../../lib/permissions';
import { downloadCsv, ordersCsv } from './utils';
import { formatCurrency, formatDate } from '../../lib/format';
import './orders.css';

const emptyFilters: OrderListFilters = { search: '', status: 'all', from: '', to: '', product: '' };

export function OrdersPage() {
  const { organizationId, currentMembershipRole } = useSession();
  const canReadFinance = canViewFinance(currentMembershipRole);
  const canCreate = canCreateOrders(currentMembershipRole);
  const exportScope = useRef({ organizationId, canReadFinance });
  exportScope.current = { organizationId, canReadFinance };
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const [draftFilters, setDraftFilters] = useState(emptyFilters);
  const [filters, setFilters] = useState(emptyFilters);
  const [cursor, setCursor] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const openCreate = searchParams.get('novo') === '1';
  const query = useOrdersPageQuery(organizationId, filters, cursor);
  const rows = query.data?.rows ?? [];

  useEffect(() => { setCursor(null); }, [filters]);

  const changeFilter = <K extends keyof OrderListFilters>(key: K, value: OrderListFilters[K]) => setDraftFilters((current) => ({ ...current, [key]: value }));
  const apply = (event: React.FormEvent) => { event.preventDefault(); setFilters(normalizeOrderFilters(draftFilters)); setCursor(null); };
  const clear = () => { setDraftFilters(emptyFilters); setFilters(emptyFilters); setCursor(null); };
  const closeCreate = () => { searchParams.delete('novo'); setSearchParams(searchParams); };
  const exportCsv = async () => {
    if (!organizationId) return;
    setExporting(true);
    try {
      const orders = await fetchAllOrders(organizationId, filters);
      // The role/organization may have changed while the network request ran.
      if (exportScope.current.organizationId !== organizationId) return;
      downloadCsv(`pedidos-${new Date().toISOString().slice(0, 10)}.csv`, ordersCsv(orders, canReadFinance && exportScope.current.canReadFinance));
    }
    catch { /* o estado da lista continua verdadeiro; nenhum CSV parcial é baixado */ }
    finally { setExporting(false); }
  };

  return <>
    <PageHeader eyebrow="Fluxo comercial" title="Pedidos" description="Pedidos reais, com preço e consumo congelados pela transação do Supabase." action={<div className="orders-header-actions"><Button variant="secondary" loading={exporting} icon={<Download size={16} />} onClick={() => void exportCsv()}>Exportar CSV real</Button>{canCreate && <Button icon={<Plus size={16} />} onClick={() => { searchParams.set('novo', '1'); setSearchParams(searchParams); }}>Novo pedido</Button>}</div>} />
    <form className="panel orders-filter-panel" onSubmit={apply}>
      <div className="orders-filter-row"><Field label="Buscar código, cliente ou título"><Input value={draftFilters.search} onChange={(event) => changeFilter('search', event.target.value)} placeholder="Busca no pedido real" /></Field><Field label="Produto/serviço"><Input value={draftFilters.product} onChange={(event) => changeFilter('product', event.target.value)} placeholder="Item real do pedido" /></Field><Field label="Status"><Select value={draftFilters.status} onChange={(event) => changeFilter('status', event.target.value as OrderStatus | 'all')}><option value="all">Todos os status</option>{ORDER_STATUSES.map((status) => <option key={status} value={status}>{status}</option>)}</Select></Field><Field label="De"><Input type="date" value={draftFilters.from} onChange={(event) => changeFilter('from', event.target.value)} /></Field><Field label="Até"><Input type="date" value={draftFilters.to} onChange={(event) => changeFilter('to', event.target.value)} /></Field><div className="orders-filter-actions"><Button type="submit" icon={<Search size={15} />}>Aplicar filtros</Button><Button type="button" variant="ghost" onClick={clear}>Limpar</Button></div></div>
    </form>
    {query.error ? <Alert kind="error">{query.error instanceof Error ? query.error.message : 'Não foi possível consultar os pedidos reais.'}</Alert> : null}
    {query.isLoading ? <Loading label="Consultando pedidos reais…" /> : !rows.length ? <EmptyState title="Nenhum pedido encontrado" description={filters.search || filters.product || filters.status !== 'all' || filters.from || filters.to ? 'Os filtros não retornaram registros reais nesta organização.' : 'Ainda não há pedidos reais nesta organização.'} action={canCreate ? <Button onClick={() => { searchParams.set('novo', '1'); setSearchParams(searchParams); }} icon={<Plus size={16} />}>Cadastrar pedido</Button> : undefined} /> : <section className="panel orders-list-panel">
      <div className="orders-list-heading"><div><h2>Histórico de pedidos</h2><p>{query.data?.total === null ? 'Contagem indisponível' : `${query.data?.total ?? 0} registro${query.data?.total === 1 ? '' : 's'} real${query.data?.total === 1 ? '' : 'is'}`}{query.data?.remaining ? ` · ${query.data.remaining} restantes após esta página` : ''}</p></div><span className="orders-truth-note">status confirmado pelo banco</span></div>
      <div className="table-scroll"><table className="data-table orders-table"><thead><tr><th>Pedido</th><th>Cliente</th><th>Datas</th><th>Status</th>{canReadFinance && <th>Financeiro</th>}<th /></tr></thead><tbody>{rows.map((order) => <tr key={order.id}><th><Link className="text-link order-code" to={`/pedidos/${order.id}`}>{order.code}</Link><span className="table-subline">{order.title}</span></th><td>{order.client_name}<span className="table-subline">{order.item_count} item(ns)</span></td><td><span className="table-subline">pedido {formatDate(order.order_date)}</span><span className="table-subline">entrega {formatDate(order.delivery_date)}</span></td><td><span className={`status-pill order-status-${statusClass(order.status)}`}>{order.status}</span></td>{canReadFinance && <td><strong>{formatCurrency(order.total_amount)}</strong><span className="table-subline">recebido {formatCurrency(order.paid_amount)} · saldo {formatCurrency(order.balance_amount)}</span></td>}<td><Link className="button button-ghost button-small" to={`/pedidos/${order.id}`}>Abrir</Link></td></tr>)}</tbody></table></div>
      <div className="orders-pagination"><span>{cursor ? 'Página seguinte' : 'Primeira página'} · {rows.length} exibidos</span><div><Button variant="ghost" disabled={!cursor} onClick={() => setCursor(null)}>Primeira</Button><Button variant="secondary" disabled={!query.data?.remaining || !query.data?.cursor} onClick={() => setCursor(query.data?.cursor ?? null)}>Próxima página</Button></div></div>
    </section>}
    {canCreate ? <NewOrderModal open={openCreate} onClose={closeCreate} onCreated={(orderId) => navigate(`/pedidos/${orderId}`)} /> : openCreate ? <Alert kind="warning">Seu papel não pode criar pedidos.</Alert> : null}
  </>;
}

function statusClass(status: OrderStatus): string { return status.toLowerCase().replace(/[^a-zà-ú]+/gi, '-'); }
