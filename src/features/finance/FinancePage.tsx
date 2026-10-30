import { useState, type FormEvent } from 'react';
import { ArrowDownRight, ArrowUpRight, RefreshCw, Wallet } from 'lucide-react';
import { Link } from 'react-router-dom';
import { Alert, Button, EmptyState, Field, Input, Loading, PageHeader, Select, StatCard } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';
import { Decimal } from '../../lib/decimal';
import { formatCurrency, formatDate } from '../../lib/format';
import { defaultFinancePeriod, financeDateRangeError, useFinanceSummaryQuery, type FinanceGrouping, type FinancePeriodFilter, type FinanceSummary } from './api';
import './finance.css';

const allowedRoles = new Set(['owner', 'admin', 'finance']);
const methodLabels: Record<string, string> = {
  pix: 'Pix', cash: 'Dinheiro', card: 'Cartão', bank_transfer: 'Transferência bancária', other: 'Outro',
};

function periodLabel(period: string, grouping: FinanceGrouping): string {
  if (grouping === 'day') return formatDate(period);
  const date = new Date(`${period}T00:00:00.000Z`);
  if (!Number.isFinite(date.getTime())) return '—';
  return new Intl.DateTimeFormat('pt-BR', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(date);
}

export function FinancePage() {
  const { organizationId, currentMembershipRole } = useSession();
  const canRead = allowedRoles.has(currentMembershipRole ?? '');
  const [draft, setDraft] = useState<FinancePeriodFilter>(() => defaultFinancePeriod());
  const [filter, setFilter] = useState<FinancePeriodFilter>(() => defaultFinancePeriod());
  const [filterError, setFilterError] = useState<string | null>(null);
  const query = useFinanceSummaryQuery(organizationId, filter, canRead && Boolean(organizationId));

  const change = <K extends keyof FinancePeriodFilter>(key: K, value: FinancePeriodFilter[K]) => {
    setDraft((current) => ({ ...current, [key]: value }));
    setFilterError(null);
  };

  const apply = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const error = financeDateRangeError(draft.from, draft.to);
    if (error) { setFilterError(error); return; }
    setFilterError(null);
    setFilter({ ...draft });
  };

  if (!canRead) return <>
    <PageHeader eyebrow="Financeiro" title="Acesso restrito" description="Este resumo contém totais financeiros da organização." />
    <Alert kind="error">Seu papel atual não permite consultar o financeiro. A consulta também é bloqueada no Supabase.</Alert>
  </>;

  if (!organizationId) return <>
    <PageHeader eyebrow="Financeiro" title="Escolha uma organização" description="O resumo não consulta dados sem uma organização ativa." />
    <Alert kind="warning">Selecione uma organização no painel antes de consultar valores.</Alert>
  </>;

  const summary = query.data;
  return <>
    <PageHeader eyebrow="Caixa e relatórios" title="Financeiro" description="Visão agregada dos pagamentos e despesas reais registrados. A previsão é estimada pelas datas de origem, não por vencimentos." action={<Button type="button" variant="secondary" loading={query.isFetching} icon={<RefreshCw size={15} />} onClick={() => void query.refetch()}>Atualizar dados</Button>} />

    <form className="panel finance-filters" onSubmit={apply}>
      <div className="finance-filter-grid">
        <Field label="De"><Input type="date" value={draft.from} onChange={(event) => change('from', event.target.value)} /></Field>
        <Field label="Até"><Input type="date" value={draft.to} onChange={(event) => change('to', event.target.value)} /></Field>
        <Field label="Agrupar por"><Select value={draft.grouping} onChange={(event) => change('grouping', event.target.value as FinanceGrouping)}><option value="day">Dia</option><option value="month">Mês</option></Select></Field>
        <div className="finance-filter-actions"><Button type="submit">Aplicar período</Button></div>
      </div>
      {filterError ? <p className="field-error finance-filter-error" role="alert">{filterError}</p> : <p className="finance-filter-hint">Até 367 dias. Datas inclusivas; o período selecionado filtra os registros, não define vencimentos.</p>}
    </form>

    {query.isLoading && !summary ? <Loading label="Consultando os totais financeiros reais…" /> : null}
    {query.isError ? <Alert kind={summary ? 'warning' : 'error'} className="finance-query-alert">{summary ? `A atualização falhou: ${query.error.message}. Os números abaixo são a última consulta confirmada.` : query.error.message}</Alert> : null}
    {!summary && query.isError ? <div className="finance-retry"><Button variant="secondary" loading={query.isFetching} onClick={() => void query.refetch()}>Tentar novamente</Button></div> : null}

    {summary ? <FinanceSummaryView summary={summary} filter={filter} /> : null}
  </>;
}

function FinanceSummaryView({ summary, filter }: { summary: FinanceSummary; filter: FinancePeriodFilter }) {
  return <div className="finance-content">
    <section className="finance-stats" aria-label="Caixa realizado">
      <StatCard label="Recebido" value={formatCurrency(summary.realized.received)} footnote="Pagamentos confirmados na janela" icon={<ArrowDownRight size={17} />} />
      <StatCard label="Pago" value={formatCurrency(summary.realized.paid)} footnote="Despesas baixadas na janela" icon={<ArrowUpRight size={17} />} />
      <StatCard label="Movimento líquido" value={formatCurrency(summary.realized.net)} footnote="Recebido menos pago; não é lucro contábil" icon={<Wallet size={17} />} />
    </section>

    <Alert kind="warning">A receber e a pagar são estimativas por data do pedido, lançamento ou compra. O sistema ainda não tem vencimentos confirmados; não use estes valores como agenda de cobrança.</Alert>

    <section className="finance-stats finance-estimates" aria-label="Estimativas, não vencimentos">
      <StatCard label="A receber · estimado" value={formatCurrency(summary.estimate.receivable)} footnote="Saldo de pedidos não cancelados criados no período" />
      <StatCard label="A pagar · estimado" value={formatCurrency(summary.estimate.payable)} footnote="Despesas/ compras pendentes registradas no período" />
      <StatCard label="Saldo projetado · estimado" value={formatCurrency(summary.estimate.projectedNet)} footnote="Caixa realizado + estimativas acima" />
    </section>

    <section className="panel finance-panel">
      <div className="finance-panel-heading"><div><h2>Movimento por {filter.grouping === 'day' ? 'dia' : 'mês'}</h2><p>Somente recebimentos e despesas efetivamente baixados.</p></div><span className="finance-period">{formatDate(filter.from)} – {formatDate(filter.to)}</span></div>
      {summary.series.length ? <div className="finance-table-scroll"><table className="finance-table"><thead><tr><th scope="col">Período</th><th scope="col">Recebido</th><th scope="col">Pago</th><th scope="col">Variação</th></tr></thead><tbody>
        {summary.series.map((row) => <tr key={row.period}><th scope="row">{periodLabel(row.period, filter.grouping)}</th><td>{formatCurrency(row.received)}</td><td>{formatCurrency(row.paid)}</td><td>{formatCurrency(new Decimal(row.received).minus(row.paid).toFixed(2))}</td></tr>)}
      </tbody></table></div> : <EmptyState title="Nenhuma baixa no período" description="Não há recebimentos ou despesas pagas nesta janela. As estimativas acima continuam separadas dos movimentos realizados." />}
    </section>

    <div className="finance-lower-grid">
      <section className="panel finance-panel">
        <div className="finance-panel-heading"><div><h2>Recebimentos por meio</h2><p>Valores provenientes dos pagamentos registrados nos pedidos.</p></div></div>
        {summary.realized.paymentMethods.length ? <div className="finance-method-list">
          {summary.realized.paymentMethods.map((item) => <div key={item.method}><span>{methodLabels[item.method] ?? item.method}</span><strong>{formatCurrency(item.amount)}</strong></div>)}
        </div> : <p className="finance-empty-note">Nenhum recebimento registrado no período.</p>}
      </section>
      <section className="panel finance-panel finance-sources">
        <div className="finance-panel-heading"><div><h2>Fontes deste resumo</h2><p>Dados agregados da organização ativa, sem lançamentos fictícios.</p></div></div>
        <p>Recebimentos: pagamentos confirmados de pedidos. Despesas: compras e despesas baixadas registradas no caixa.</p>
        <div className="finance-links"><Link className="text-link" to="/pedidos">Consultar pedidos</Link><Link className="text-link" to="/compras">Consultar compras</Link></div>
        <p className="finance-limit-note">Esta primeira visão não cria lançamentos manuais, não lista credores/devedores e não calcula lucro, taxas ou tributos.</p>
      </section>
    </div>
  </div>;
}
