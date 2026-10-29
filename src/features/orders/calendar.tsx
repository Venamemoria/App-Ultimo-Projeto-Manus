import { useMemo, useState } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { Link } from 'react-router-dom';
import { Alert, Button, EmptyState, Loading, PageHeader, Select } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';
import { useAllOrdersQuery } from './api';
import type { OrderDto } from './types';
import { isoFromLocalDate, monthLabel, shiftMonth, todayIso } from './utils';
import { formatDate } from '../../lib/format';
import './orders.css';

type CalendarMode = 'production' | 'delivery';

export function CalendarPage() {
  const { organizationId } = useSession();
  const query = useAllOrdersQuery(organizationId);
  const [month, setMonth] = useState(todayIso().slice(0, 7));
  const [mode, setMode] = useState<CalendarMode>('production');
  const orders = query.data ?? [];
  const dates = useMemo(() => buildMonth(month), [month]);
  const byDate = useMemo(() => {
    const grouped = new Map<string, OrderDto[]>();
    orders.forEach((order) => {
      const date = mode === 'production' ? order.production_date : order.delivery_date;
      if (!date || date.slice(0, 7) !== month) return;
      const existing = grouped.get(date) ?? [];
      existing.push(order);
      grouped.set(date, existing);
    });
    return grouped;
  }, [mode, month, orders]);
  const visible = Array.from(byDate.values()).flat();

  return <>
    <PageHeader eyebrow="Agenda operacional" title="Agenda" description="Somente previsões reais de produção e entrega dos pedidos. Esta tela não cria tarefas paralelas." action={<div className="calendar-controls"><Button variant="secondary" aria-label="Mês anterior" onClick={() => setMonth((value) => shiftMonth(value, -1))}><ChevronLeft size={16} /></Button><strong>{monthLabel(month)}</strong><Button variant="secondary" aria-label="Próximo mês" onClick={() => setMonth((value) => shiftMonth(value, 1))}><ChevronRight size={16} /></Button><Select value={mode} onChange={(event) => setMode(event.target.value as CalendarMode)}><option value="production">Produção</option><option value="delivery">Entrega</option></Select></div>} />
    {query.isLoading ? <Loading label="Consultando datas reais…" /> : query.error ? <Alert kind="error">{query.error instanceof Error ? query.error.message : 'Não foi possível carregar a agenda real.'}</Alert> : <><div className="calendar-weekdays">{['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'].map((day) => <span key={day}>{day}</span>)}</div><div className="calendar-grid">{dates.map((date) => { const dayOrders = byDate.get(date) ?? []; return <div className={`calendar-day${date.slice(0, 7) === month ? '' : ' outside'}`} key={date}><span className="calendar-day-number">{Number(date.slice(8, 10))}</span>{dayOrders.map((order) => <Link className="calendar-order" key={order.id} to={`/pedidos/${order.id}`}><strong>{order.code}</strong><span>{order.client_name}</span><small>{order.title}</small></Link>)}</div>; })}</div>{visible.length === 0 ? <EmptyState title="Nenhuma previsão neste mês" description="Não há data real de produção ou entrega nesta competência." /> : <p className="calendar-footnote">{visible.length} pedido(s) real(is) com previsão de {mode === 'production' ? 'produção' : 'entrega'} neste mês.</p>}</>}
  </>;
}

function buildMonth(month: string): string[] {
  const [year, value] = month.split('-').map(Number);
  const first = new Date(year, value - 1, 1, 12, 0, 0, 0);
  const start = (first.getDay() + 6) % 7;
  const daysInMonth = new Date(year, value, 0, 12, 0, 0, 0).getDate();
  const previousDays = new Date(year, value - 1, 0, 12, 0, 0, 0).getDate();
  return Array.from({ length: 42 }, (_, index) => {
    const dayOffset = index - start + 1;
    if (dayOffset < 1) return isoFromLocalDate(new Date(year, value - 2, previousDays + dayOffset, 12));
    if (dayOffset > daysInMonth) return isoFromLocalDate(new Date(year, value, dayOffset - daysInMonth, 12));
    return `${year}-${String(value).padStart(2, '0')}-${String(dayOffset).padStart(2, '0')}`;
  });
}
