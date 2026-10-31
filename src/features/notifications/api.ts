import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { supabase, supabaseConfigError } from '../../lib/supabase';
import type { RealtimeStatus } from '../orders/types';
import { invalidateStockQueries } from '../inventory/cache';

export interface NotificationDto {
  id: string;
  organization_id: string;
  event_id: string;
  recipient_user_id: string;
  title: string;
  payload: Record<string, unknown>;
  read_at: string | null;
  created_at: string;
}

export const notificationQueryKeys = {
  all: (organizationId: string, userId: string) => ['notifications', organizationId, userId] as const,
};

function getClient() {
  if (!supabase) throw new Error(supabaseConfigError ?? 'O serviço de dados está indisponível neste ambiente.');
  return supabase;
}

function databaseError(error: { code?: string | null } | null, fallback: string): Error {
  if (!error) return new Error(fallback);
  if (error.code === '42501') return new Error('A notificação não pertence à sua sessão ou organização.');
  return new Error(fallback);
}

export async function fetchNotifications(organizationId: string): Promise<NotificationDto[]> {
  const { data, error } = await getClient().from('vm_notifications').select('id, organization_id, event_id, recipient_user_id, title, payload, read_at, created_at')
    .eq('organization_id', organizationId).order('created_at', { ascending: false }).limit(100);
  if (error) throw databaseError(error, 'Não foi possível carregar suas notificações.');
  return (data ?? []) as NotificationDto[];
}

export async function markNotificationRead(organizationId: string, notificationId: string): Promise<void> {
  const { error } = await getClient().rpc('vm_mark_notification_read', {
    p_organization_id: organizationId,
    p_notification_id: notificationId,
  });
  if (error) throw databaseError(error, 'Não foi possível marcar a notificação como lida.');
}

export function useNotificationsQuery(organizationId: string | null, userId: string | null) {
  return useQuery({
    queryKey: organizationId && userId ? notificationQueryKeys.all(organizationId, userId) : ['notifications', 'none'],
    queryFn: () => fetchNotifications(organizationId!),
    enabled: Boolean(organizationId && userId),
  });
}

export function useNotificationsRealtime(organizationId: string | null, userId: string | null): RealtimeStatus {
  const queryClient = useQueryClient();
  const [status, setStatus] = useState<RealtimeStatus>('reconnecting');
  useEffect(() => {
    if (!supabase || !organizationId || !userId) {
      setStatus('reconnecting');
      return undefined;
    }
    let active = true;
    const key = notificationQueryKeys.all(organizationId, userId);
    const refresh = () => { if (active) void queryClient.invalidateQueries({ queryKey: key }); };
    const refreshOrderStock = () => {
      if (!active) return;
      refresh();
      // Order events are already published without prices or costs. Re-read
      // stock under RLS instead of trusting a realtime payload as the balance.
      void invalidateStockQueries(queryClient, organizationId);
    };
    const realtimeClient = supabase;
    const channel = realtimeClient.channel(`orders-notifications:${organizationId}:${userId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'vm_notifications', filter: `organization_id=eq.${organizationId}` }, refresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'vm_order_events', filter: `organization_id=eq.${organizationId}` }, refreshOrderStock)
      .subscribe((subscriptionStatus) => {
        if (!active) return;
        setStatus(subscriptionStatus === 'SUBSCRIBED' ? 'connected' : 'reconnecting');
        if (subscriptionStatus === 'SUBSCRIBED') void invalidateStockQueries(queryClient, organizationId);
      });
    return () => {
      active = false;
      void realtimeClient.removeChannel(channel);
    };
  }, [organizationId, queryClient, userId]);
  return status;
}
