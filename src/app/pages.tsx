import { useEffect, useState } from 'react';
import { ArrowUpRight, Building2, Boxes, CalendarDays, ContactRound, Package, ShoppingBag, TriangleAlert, UserRound, ClipboardList } from 'lucide-react';
import { Link } from 'react-router-dom';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../components/ui/card';
import { Alert, Button, EmptyState, Field, Input, Loading, PageHeader, Select } from '../components/ui';
import { formatNumber, initials } from '../lib/format';
import { supabase } from '../lib/supabase';
import { canViewFinance } from '../lib/permissions';
import { useSession } from './AuthProvider';

interface Metrics {
  materials: number | null;
  lowStock: number | null;
  products: number | null;
  clients: number | null;
}

export function DashboardPage() {
  const { memberships, membershipsLoading, error, organization, organizationId } = useSession();

  if (membershipsLoading) return <Loading label="Carregando suas organizações…" />;
  if (!memberships.length) {
    if (error) return <><PageHeader eyebrow="Primeiro acesso" title="Sua área de trabalho" description="Não foi possível confirmar suas organizações agora." /><Alert kind="error">{error}</Alert></>;
    return <OnboardingPage />;
  }
  if (!organizationId) return <Loading label="Selecionando organização…" />;

  return <OrganizationDashboard organizationId={organizationId} organizationName={organization?.name ?? 'Organização'} />;
}

function OrganizationDashboard({ organizationId, organizationName }: { organizationId: string; organizationName: string }) {
  const { memberships, selectOrganization, currentMembershipRole } = useSession();
    const [metrics, setMetrics] = useState<Metrics>({ materials: null, lowStock: null, products: null, clients: null });
  const [loading, setLoading] = useState(true);
  const [metricsError, setMetricsError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setMetrics({ materials: null, lowStock: null, products: null, clients: null });
    setMetricsError(null);

    if (!supabase) {
      setMetricsError('A configuração do Supabase está indisponível neste ambiente.');
      setLoading(false);
      return () => { active = false; };
    }
    const client = supabase;

    const load = async () => {
      const [materials, products, clients] = await Promise.all([
        client.from('vm_materials_read').select('id, is_low_stock').eq('organization_id', organizationId),
        client.from('vm_products_read').select('id', { count: 'exact', head: true }).eq('organization_id', organizationId),
        client.from('vm_clients').select('id', { count: 'exact', head: true }).eq('organization_id', organizationId),
      ]);
      if (!active) return;
      const errors = [materials.error, products.error, clients.error].filter(Boolean);
      setMetrics({
        materials: materials.error ? null : materials.data?.length ?? 0,
        lowStock: materials.error ? null : (materials.data ?? []).filter((material) => material.is_low_stock).length,
        products: products.error ? null : products.count ?? 0,
        clients: clients.error ? null : clients.count ?? 0,
      });
      if (errors.length) setMetricsError('Algumas contagens não puderam ser carregadas. Os campos com traço precisam de nova tentativa.');
      setLoading(false);
    };
    void load();
    return () => { active = false; };
  }, [organizationId]);

  const todayLabel = new Intl.DateTimeFormat('pt-BR', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
  }).format(new Date());
  const shortcuts = [
    { to: '/pedidos', title: 'Pedidos', description: 'Crie e acompanhe encomendas.', icon: ClipboardList },
    { to: '/estoque', title: 'Inventário', description: 'Consulte saldos e reposições.', icon: Boxes },
    { to: '/produtos', title: 'Produtos', description: 'Organize produtos e composições.', icon: Package },
    { to: '/clientes', title: 'Clientes', description: 'Acesse os contatos do ateliê.', icon: ContactRound },
    ...(canViewFinance(currentMembershipRole)
      ? [{ to: '/compras', title: 'Compras', description: 'Registre entradas de materiais.', icon: ShoppingBag }]
      : []),
  ];

  return (
    <>
      <PageHeader
        eyebrow="Visão geral"
        title="O ritmo do seu ateliê."
        description={`Indicadores reais de ${organizationName}, reunidos para apoiar as decisões do dia a dia.`}
      />
      <div className="dashboard-toolbar">
        {memberships.length > 1 ? (
          <div className="organization-picker">
            <label htmlFor="organization-select">Organização ativa</label>
            <Select id="organization-select" value={organizationId} onChange={(event) => selectOrganization(event.target.value)}>
              {memberships.map((membership) => <option key={membership.organization_id} value={membership.organization_id}>{membership.organization?.name ?? 'Organização sem nome'}</option>)}
            </Select>
          </div>
        ) : <span />}
        <time className="dashboard-date" dateTime={new Date().toISOString().slice(0, 10)}>
          <CalendarDays size={16} aria-hidden="true" />
          <span>{todayLabel}</span>
        </time>
      </div>
      {metricsError ? <Alert className="storage-warning" kind="warning">{metricsError}</Alert> : null}
      {loading ? <Loading label="Consultando os registros da organização…" /> : (
        <section className="dashboard-metrics-section" aria-labelledby="dashboard-metrics-title">
          <div className="dashboard-section-heading">
            <div>
              <p className="eyebrow">Registros da organização</p>
              <h2 id="dashboard-metrics-title">O essencial, de relance</h2>
            </div>
          </div>
          <div className="stats-grid dashboard-stats-grid">
            <Card className="dashboard-metric-card">
              <CardHeader className="dashboard-metric-header">
                <CardTitle className="dashboard-metric-label">Materiais</CardTitle>
                <span className="dashboard-metric-icon"><Boxes size={18} aria-hidden="true" /></span>
              </CardHeader>
              <CardContent className="dashboard-metric-content">
                <strong className="dashboard-metric-value">{metrics.materials === null ? '—' : formatNumber(metrics.materials)}</strong>
                <CardDescription>itens consultados no inventário</CardDescription>
              </CardContent>
            </Card>
            <Card className="dashboard-metric-card dashboard-metric-alert">
              <CardHeader className="dashboard-metric-header">
                <CardTitle className="dashboard-metric-label">Reposição</CardTitle>
                <span className="dashboard-metric-icon"><TriangleAlert size={18} aria-hidden="true" /></span>
              </CardHeader>
              <CardContent className="dashboard-metric-content">
                <strong className="dashboard-metric-value">{metrics.lowStock === null ? '—' : formatNumber(metrics.lowStock)}</strong>
                <CardDescription>insumos com alerta de estoque</CardDescription>
              </CardContent>
            </Card>
            <Card className="dashboard-metric-card">
              <CardHeader className="dashboard-metric-header">
                <CardTitle className="dashboard-metric-label">Produtos</CardTitle>
                <span className="dashboard-metric-icon"><Package size={18} aria-hidden="true" /></span>
              </CardHeader>
              <CardContent className="dashboard-metric-content">
                <strong className="dashboard-metric-value">{metrics.products === null ? '—' : formatNumber(metrics.products)}</strong>
                <CardDescription>produtos cadastrados</CardDescription>
              </CardContent>
            </Card>
            <Card className="dashboard-metric-card">
              <CardHeader className="dashboard-metric-header">
                <CardTitle className="dashboard-metric-label">Clientes</CardTitle>
                <span className="dashboard-metric-icon"><ContactRound size={18} aria-hidden="true" /></span>
              </CardHeader>
              <CardContent className="dashboard-metric-content">
                <strong className="dashboard-metric-value">{metrics.clients === null ? '—' : formatNumber(metrics.clients)}</strong>
                <CardDescription>clientes cadastrados</CardDescription>
              </CardContent>
            </Card>
          </div>
        </section>
      )}
      <section className="dashboard-actions-section" aria-labelledby="dashboard-actions-title">
        <div className="dashboard-section-heading">
          <div>
            <p className="eyebrow">Acesso direto</p>
            <h2 id="dashboard-actions-title">Fluxos do ateliê</h2>
            <p>Entre nos módulos que mantêm o trabalho em movimento.</p>
          </div>
        </div>
        <div className="dashboard-action-grid">
          {shortcuts.map((shortcut) => {
            const Icon = shortcut.icon;
            return (
              <Card className="dashboard-action-card" key={shortcut.to}>
                <Link className="dashboard-action-link" to={shortcut.to}>
                  <span className="dashboard-action-icon"><Icon size={18} aria-hidden="true" /></span>
                  <span className="dashboard-action-copy">
                    <strong>{shortcut.title}</strong>
                    <small>{shortcut.description}</small>
                  </span>
                  <ArrowUpRight className="dashboard-action-arrow" size={17} aria-hidden="true" />
                </Link>
              </Card>
            );
          })}
        </div>
      </section>
    </>
  );
}

function OnboardingPage() {
  const { createOrganization, storageWarning } = useSession();
  const [name, setName] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const submit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) {
      setError('Informe um nome para sua organização.');
      return;
    }
    if (trimmed.length > 200) {
      setError('O nome pode ter no máximo 200 caracteres.');
      return;
    }
    setSaving(true);
    setError(null);
    const result = await createOrganization(trimmed);
    setSaving(false);
    if (result.error) setError(result.error);
  };

  return (
    <div className="onboarding">
      <PageHeader eyebrow="Primeiro acesso" title="Vamos dar nome ao seu ateliê" description="Seu cadastro ainda não está vinculado a uma organização. Crie a sua para começar com segurança." />
      {storageWarning ? <Alert className="storage-warning" kind="warning">{storageWarning}</Alert> : null}
      <section className="panel">
        <div className="panel-heading"><div><h2>Nova organização</h2><p>Você será o proprietário inicial. Nenhuma organização existente será assumida.</p></div><Building2 size={22} color="#b76445" aria-hidden="true" /></div>
        <form onSubmit={submit}>
          <Field label="Nome da organização" hint="Use o nome que sua equipe reconhece no dia a dia." error={error ?? undefined}>
            <Input value={name} onChange={(event) => setName(event.target.value)} maxLength={200} placeholder="Ex.: Ateliê Vê na Memória" autoComplete="organization" />
          </Field>
          <div className="form-actions"><Button type="submit" loading={saving}>Criar organização</Button></div>
        </form>
      </section>
    </div>
  );
}

export function AccountPage() {
  const { user, organization, currentMembershipRole, memberships, signOut } = useSession();
  const [signingOut, setSigningOut] = useState(false);
  const displayName = user?.email?.split('@')[0] ?? 'Sua conta';
  const role = currentMembershipRole ? ({ owner: 'Proprietário', admin: 'Administração', production: 'Produção', finance: 'Financeiro', viewer: 'Leitura' } as const)[currentMembershipRole] : 'Sem organização';

  const handleSignOut = async () => {
    setSigningOut(true);
    await signOut();
    setSigningOut(false);
  };

  return (
    <>
      <PageHeader eyebrow="Conta" title="Seu perfil" description="Identidade e contexto da sessão atual no Vê na Memória." />
      <section className="profile-card">
        <div className="profile-avatar" aria-hidden="true">{initials(displayName)}</div>
        <div>
          <h2>{displayName}</h2>
          <p className="profile-email">{user?.email ?? 'E-mail não disponível'}</p>
          <div className="profile-meta">
            <div className="meta-item"><span>Organização</span><strong>{organization?.name ?? (memberships.length ? 'Selecione no painel' : 'Nenhuma')}</strong></div>
            <div className="meta-item"><span>Permissão efetiva</span><strong>{role}</strong></div>
          </div>
          <div className="account-actions"><Button variant="secondary" loading={signingOut} icon={<UserRound size={16} />} onClick={handleSignOut}>Sair desta sessão</Button></div>
        </div>
      </section>
    </>
  );
}
