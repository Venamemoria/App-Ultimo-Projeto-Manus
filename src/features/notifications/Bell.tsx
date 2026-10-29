import { Bell, Check, ExternalLink } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Button } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';
import { markNotificationRead, notificationQueryKeys, useNotificationsQuery, useNotificationsRealtime } from './api';
import { useQueryClient } from '@tanstack/react-query';
import './notifications.css';

export function NotificationBell() {
  const { organizationId, user } = useSession();
  const [open, setOpen] = useState(false);
  const queryClient = useQueryClient();
  const notifications = useNotificationsQuery(organizationId, user?.id ?? null);
  const realtime = useNotificationsRealtime(organizationId, user?.id ?? null);
  const rows = notifications.data ?? [];
  const unread = rows.filter((notification) => !notification.read_at).length;

  const read = async (notificationId: string) => {
    if (!organizationId) return;
    try {
      await markNotificationRead(organizationId, notificationId);
      await queryClient.invalidateQueries({ queryKey: notificationQueryKeys.all(organizationId, user?.id ?? '') });
    } catch {
      // A failed read is intentionally not presented as success; the next realtime/query refresh keeps the truth.
    }
  };

  return (
    <div className="notification-bell-wrap">
      <Button className="notification-bell" variant="ghost" aria-expanded={open} aria-haspopup="dialog" onClick={() => setOpen((value) => !value)} icon={<Bell size={17} />}>
        <span className="notification-label">Notificações</span>
        {unread ? <span className="notification-count" aria-label={`${unread} não lidas`}>{unread > 99 ? '99+' : unread}</span> : null}
      </Button>
      <span className={`realtime-state ${realtime}`} aria-label={realtime === 'connected' ? 'Notificações conectadas em tempo real' : 'Reconectando notificações'}>
        <span aria-hidden="true" />{realtime === 'connected' ? 'conectado' : 'reconectando'}
      </span>
      {open ? (
        <div className="notification-popover" role="dialog" aria-label="Notificações">
          <div className="notification-popover-heading"><strong>Atualizações do ateliê</strong><span>{unread ? `${unread} não lida${unread === 1 ? '' : 's'}` : 'Tudo lido'}</span></div>
          {notifications.isLoading ? <p className="notification-empty">Consultando notificações reais…</p> : notifications.error ? <p className="notification-empty notification-error">Não foi possível carregar agora.</p> : rows.length === 0 ? <p className="notification-empty">Nenhuma notificação real nesta organização.</p> : (
            <div className="notification-list">
              {rows.map((notification) => {
                const orderId = typeof notification.payload.order_id === 'string' ? notification.payload.order_id : null;
                return (
                  <div className={`notification-row${notification.read_at ? '' : ' unread'}`} key={notification.id}>
                    <div><strong>{notification.title}</strong><small>{new Date(notification.created_at).toLocaleString('pt-BR')}</small></div>
                    <div className="notification-row-actions">
                      {orderId ? <Link className="icon-button" aria-label="Abrir pedido" to={`/pedidos/${orderId}`} onClick={() => setOpen(false)}><ExternalLink size={15} /></Link> : null}
                      {!notification.read_at ? <button className="icon-button" type="button" aria-label="Marcar como lida" onClick={() => void read(notification.id)}><Check size={15} /></button> : null}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      ) : null}
    </div>
  );
}
