import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { Alert, EmptyState, Loading, Select } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';

export function OrganizationContext({ children }: { children: ReactNode }) {
  const { membershipsLoading, memberships, organizationId, error } = useSession();

  if (membershipsLoading) return <Loading label="Carregando suas organizações…" />;
  if (error && !memberships.length) {
    return <><Alert kind="error">{error}</Alert><p className="context-followup"><Link className="text-link" to="/conta">Revise sua conta e organização</Link></p></>;
  }
  if (!memberships.length) {
    return (
      <EmptyState
        title="Escolha uma organização para continuar"
        description="Esta página consulta somente registros de uma organização real. Crie ou selecione sua organização na conta antes de continuar."
        action={<Link className="button button-primary" to="/conta">Ir para Conta</Link>}
      />
    );
  }
  if (!organizationId) return <Loading label="Selecionando organização…" />;
  return <>{children}</>;
}

export function OrganizationPicker() {
  const { memberships, organizationId, selectOrganization } = useSession();
  if (memberships.length < 2 || !organizationId) return null;
  return (
    <div className="organization-picker">
      <label htmlFor="operational-organization-select">Organização ativa</label>
      <Select id="operational-organization-select" value={organizationId} onChange={(event) => selectOrganization(event.target.value)}>
        {memberships.map((membership) => (
          <option key={membership.organization_id} value={membership.organization_id}>
            {membership.organization?.name ?? 'Organização sem nome'}
          </option>
        ))}
      </Select>
    </div>
  );
}
