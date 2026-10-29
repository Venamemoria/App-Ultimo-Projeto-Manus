import { useEffect, useState } from 'react';
import { Building2, Boxes, ContactRound, Package, UserRound } from 'lucide-react';
import { Alert, Button, EmptyState, Field, Input, Loading, PageHeader, Select, StatCard } from '../components/ui';
import { formatNumber, initials } from '../lib/format';
import { supabase } from '../lib/supabase';
import { useSession } from './AuthProvider';

interface Metrics {
  materials: number | null;
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
  const { memberships, selectOrganization } = useSession();
  const [metrics, setMetrics] = useState<Metrics>({ materials: null, products: null, clients: null });
  const [loading, setLoading] = useState(true);
  const [metricsError, setMetricsError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setMetrics({ materials: null, products: null, clients: null });
    setMetricsError(null);

    if (!supabase) {
      setMetricsError('A configuração do Supabase está indisponível neste ambiente.');
      setLoading(false);
      return () => { active = false; };
    }
    const client = supabase;

    const load = async () => {
      const [materials, products, clients] = await Promise.all([
        client.from('vm_materials').select('id', { count: 'exact', head: true }).eq('organization_id', organizationId),
        client.from('vm_products').select('id', { count: 'exact', head: true }).eq('organization_id', organizationId),
        client.from('vm_clients').select('id', { count: 'exact', head: true }).eq('organization_id', organizationId),
      ]);
      if (!active) return;
      const errors = [materials.error, products.error, clients.error].filter(Boolean);
      setMetrics({
        materials: materials.error ? null : materials.count ?? 0,
        products: products.error ? null : products.count ?? 0,
        clients: clients.error ? null : clients.count ?? 0,
      });
      if (errors.length) setMetricsError('Algumas contagens não puderam ser carregadas. Os campos com traço precisam de nova tentativa.');
      setLoading(false);
    };
    void load();
    return () => { active = false; };
  }, [organizationId]);

  return (
    <>
      <PageHeader
        eyebrow="Painel da organização"
        title={organizationName}
        description="Um ponto de partida calmo para acompanhar os registros reais do seu ateliê."
      />
      {memberships.length > 1 ? (
        <div className="organization-picker">
          <label htmlFor="organization-select">Organização ativa</label>
          <Select id="organization-select" value={organizationId} onChange={(event) => selectOrganization(event.target.value)}>
            {memberships.map((membership) => <option key={membership.organization_id} value={membership.organization_id}>{membership.organization?.name ?? 'Organização sem nome'}</option>)}
          </Select>
        </div>
      ) : null}
      {metricsError ? <Alert className="storage-warning" kind="warning">{metricsError}</Alert> : null}
      {loading ? <Loading label="Consultando os registros da organização…" /> : (
        <div className="stats-grid">
          <StatCard label="Materiais" value={metrics.materials === null ? '—' : formatNumber(metrics.materials)} footnote="registros cadastrados" icon={<Boxes size={17} />} />
          <StatCard label="Produtos" value={metrics.products === null ? '—' : formatNumber(metrics.products)} footnote="registros cadastrados" icon={<Package size={17} />} />
          <StatCard label="Clientes" value={metrics.clients === null ? '—' : formatNumber(metrics.clients)} footnote="registros cadastrados" icon={<ContactRound size={17} />} />
        </div>
      )}
      <section className="panel">
        <div className="panel-heading"><div><h2>Seu espaço começa aqui</h2><p>Os próximos módulos aparecem quando tiverem um fluxo real para conectar ao banco.</p></div></div>
        <EmptyState title="Nenhuma atividade adicional nesta fatia" description="Este painel mostra apenas a organização ativa e as contagens autorizadas pela sua sessão. Não há dados demonstrativos para preencher a tela." />
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
