import { useEffect, useState } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router-dom';
import { CircleUserRound, LayoutDashboard, LogOut, Menu, PackageSearch, PackagePlus, ReceiptText, X } from 'lucide-react';
import { Alert, Button } from '../components/ui';
import { initials } from '../lib/format';
import { useSession } from './AuthProvider';

const roleLabels = {
  owner: 'proprietário',
  admin: 'administração',
  production: 'produção',
  finance: 'financeiro',
  viewer: 'leitura',
} as const;

export function AppLayout() {
  const { user, organization, currentMembershipRole, memberships, storageWarning, signOut } = useSession();
  const [drawerOpen, setDrawerOpen] = useState(false);
  const location = useLocation();
  const [signingOut, setSigningOut] = useState(false);

  useEffect(() => setDrawerOpen(false), [location.pathname]);

  const handleSignOut = async () => {
    setSigningOut(true);
    await signOut();
    setSigningOut(false);
  };

  const navClass = ({ isActive }: { isActive: boolean }) => `nav-link${isActive ? ' active' : ''}`;
  const displayName = user?.email?.split('@')[0] ?? 'Sua conta';

  return (
    <div className="app-shell">
      <header className="mobile-topbar">
        <div className="sidebar-brand">
          <img className="brand-mark" src="/brand-mark.webp" alt="" />
          <div className="wordmark">Vê na Memória<small>gestão do ateliê</small></div>
        </div>
        <button className="mobile-menu-button" type="button" aria-label={drawerOpen ? 'Fechar menu' : 'Abrir menu'} onClick={() => setDrawerOpen((open) => !open)}>
          {drawerOpen ? <X size={19} /> : <Menu size={19} />}
        </button>
      </header>

      <aside className={`sidebar${drawerOpen ? ' open' : ''}`} aria-label="Navegação principal">
        <div className="sidebar-brand">
          <img className="brand-mark" src="/brand-mark.webp" alt="" />
          <div className="wordmark">Vê na Memória<small>gestão do ateliê</small></div>
        </div>
        <div className="context-label">Ateliê</div>
        <nav className="sidebar-nav">
          <NavLink className={navClass} to="/" end><LayoutDashboard size={18} aria-hidden="true" /> <span>Painel</span></NavLink>
          <div className="context-label">Estoque &amp; Custos</div>
          <NavLink className={navClass} to="/estoque"><PackageSearch size={18} aria-hidden="true" /> <span>Inventário</span></NavLink>
          <NavLink className={navClass} to="/compras"><ReceiptText size={18} aria-hidden="true" /> <span>Registro de compras</span></NavLink>
          <NavLink className={navClass} to="/produtos"><PackagePlus size={18} aria-hidden="true" /> <span>Produtos</span></NavLink>
          <NavLink className={navClass} to="/conta"><CircleUserRound size={18} aria-hidden="true" /> <span>Conta</span></NavLink>
        </nav>
        <div className="sidebar-footer">
          <div className="organization-mini">
            <span className="org-avatar">{initials(organization?.name)}</span>
            <div>
              <strong>{organization?.name ?? (memberships.length ? 'Escolha uma organização' : 'Nenhuma organização')}</strong>
              <span>{currentMembershipRole ? roleLabels[currentMembershipRole] : 'sem vínculo'}</span>
            </div>
          </div>
          <Button className="sidebar-logout" variant="ghost" loading={signingOut} icon={<LogOut size={16} />} onClick={handleSignOut}>Sair</Button>
        </div>
      </aside>

      <main className="main-content">
        <div className="main-inner">
          {storageWarning ? <Alert className="storage-warning" kind="warning">{storageWarning}</Alert> : null}
          <Outlet />
        </div>
      </main>
    </div>
  );
}
