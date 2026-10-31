import { useEffect, useState, type CSSProperties } from 'react';
import { Building2, CalendarDays, CircleDollarSign, ClipboardList, Factory, FileText, LayoutDashboard, LoaderCircle, LogOut, PackagePlus, PackageSearch, ShoppingBag, UserRound, UsersRound, type LucideIcon } from 'lucide-react';
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom';
import { Alert } from '../components/ui';
import { Avatar, AvatarFallback } from '../components/ui/avatar';
import { Button } from '../components/ui/button';
import { Separator } from '../components/ui/separator';
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarSeparator,
  SidebarTrigger,
  useSidebar,
} from '../components/ui/sidebar';
import { TooltipProvider } from '../components/ui/tooltip';
import { NotificationBell } from '../features/notifications/Bell';
import { initials } from '../lib/format';
import { canViewFinance } from '../lib/permissions';
import { useSession } from './AuthProvider';

const roleLabels = {
  owner: 'Proprietário',
  admin: 'Administração',
  production: 'Produção',
  finance: 'Financeiro',
  viewer: 'Leitura',
} as const;

type NavigationItem = {
  to: string;
  label: string;
  icon: LucideIcon;
};

type NavigationGroup = {
  label: string;
  items: NavigationItem[];
};

function isActivePath(pathname: string, to: string): boolean {
  if (to === '/') return pathname === '/';
  return pathname === to || pathname.startsWith(`${to}/`);
}

function getPageTitle(pathname: string, groups: NavigationGroup[]): string {
  if (/^\/pedidos\/[^/]+$/.test(pathname)) return 'Detalhes do pedido';
  if (pathname === '/conta') return 'Minha conta';
  return groups.flatMap((group) => group.items).find((item) => isActivePath(pathname, item.to))?.label ?? 'Área de trabalho';
}

export function AppLayout() {
  return (
    <TooltipProvider delayDuration={0}>
      <SidebarProvider
        className="app-shell"
        style={{ '--sidebar-width': '17rem', '--sidebar-width-icon': '3.5rem' } as CSSProperties}
      >
        <AppShellContent />
      </SidebarProvider>
    </TooltipProvider>
  );
}

function AppShellContent() {
  const { user, organization, currentMembershipRole, storageWarning, signOut } = useSession();
  const { isMobile, setOpenMobile } = useSidebar();
  const location = useLocation();
  const [signingOut, setSigningOut] = useState(false);
  const [signOutError, setSignOutError] = useState<string | null>(null);
  const displayName = user?.email?.split('@')[0] ?? 'Sua conta';
  const roleLabel = currentMembershipRole ? roleLabels[currentMembershipRole] : 'Sem vínculo';

  useEffect(() => {
    if (isMobile) setOpenMobile(false);
  }, [isMobile, location.pathname, setOpenMobile]);

  const groups: NavigationGroup[] = [
    { label: 'Visão geral', items: [{ to: '/', label: 'Painel', icon: LayoutDashboard }] },
    {
      label: 'Operação',
      items: [
        { to: '/pedidos', label: 'Pedidos', icon: ClipboardList },
        { to: '/producao', label: 'Produção', icon: Factory },
        { to: '/agenda', label: 'Agenda', icon: CalendarDays },
      ],
    },
    {
      label: 'Gestão do ateliê',
      items: [
        { to: '/estoque', label: 'Inventário', icon: PackageSearch },
        { to: '/produtos', label: 'Produtos', icon: PackagePlus },
        { to: '/clientes', label: 'Clientes', icon: UsersRound },
        { to: '/fornecedores', label: 'Fornecedores', icon: Building2 },
      ],
    },
  ];

  if (canViewFinance(currentMembershipRole)) {
    groups.push({
      label: 'Financeiro',
      items: [
        { to: '/compras', label: 'Compras de materiais', icon: ShoppingBag },
        { to: '/orcamentos', label: 'Orçamentos', icon: FileText },
        { to: '/financeiro', label: 'Resumo do caixa', icon: CircleDollarSign },
      ],
    });
  }

  const pageTitle = getPageTitle(location.pathname, groups);

  const handleSignOut = async () => {
    if (signingOut) return;
    setSigningOut(true);
    setSignOutError(null);
    try {
      const result = await signOut();
      if (result.error) setSignOutError(result.error);
    } catch {
      setSignOutError('Não foi possível encerrar sua sessão agora. Tente novamente.');
    } finally {
      setSigningOut(false);
    }
  };

  return (
    <>
      <Sidebar collapsible="icon" className="shell-sidebar" aria-label="Navegação principal">
        <SidebarHeader className="shell-sidebar-header">
          <Link className="shell-brand" to="/" aria-label="Vê na Memória — Painel">
            <img className="shell-brand-mark" src="/brand-mark.webp" alt="" />
            <span className="shell-brand-copy">
              <span className="shell-brand-name">Vê na Memória</span>
              <span className="shell-brand-caption">GESTÃO DO ATELIÊ</span>
            </span>
          </Link>
        </SidebarHeader>

        <SidebarSeparator className="shell-sidebar-separator" />

        <SidebarContent className="shell-sidebar-content">
          {groups.map((group) => (
            <SidebarGroup key={group.label} className="shell-nav-group">
              <SidebarGroupLabel className="shell-nav-heading">{group.label}</SidebarGroupLabel>
              <SidebarMenu>
                {group.items.map((item) => {
                  const Icon = item.icon;
                  const active = isActivePath(location.pathname, item.to);
                  return (
                    <SidebarMenuItem key={item.to}>
                      <SidebarMenuButton
                        asChild
                        isActive={active}
                        tooltip={item.label}
                        className="shell-nav-link"
                      >
                        <NavLink to={item.to} end={item.to === '/'} aria-current={active ? 'page' : undefined}>
                          <Icon aria-hidden="true" />
                          <span>{item.label}</span>
                        </NavLink>
                      </SidebarMenuButton>
                    </SidebarMenuItem>
                  );
                })}
              </SidebarMenu>
            </SidebarGroup>
          ))}
        </SidebarContent>

        <SidebarFooter className="shell-sidebar-footer">
          <SidebarSeparator className="shell-sidebar-separator" />
          <div className="shell-organization" title={organization?.name ?? undefined}>
            <span className="shell-organization-mark" aria-hidden="true">{initials(organization?.name)}</span>
            <span className="shell-organization-copy">
              <span>Ateliê ativo</span>
              <strong>{organization?.name ?? 'Nenhuma organização'}</strong>
              <small>{roleLabel}</small>
            </span>
          </div>
          {signOutError ? <Alert className="shell-signout-error" kind="error">{signOutError}</Alert> : null}
          <SidebarMenu>
            <SidebarMenuItem>
              <SidebarMenuButton asChild isActive={location.pathname === '/conta'} tooltip="Minha conta" className="shell-account-link">
                <NavLink to="/conta" aria-current={location.pathname === '/conta' ? 'page' : undefined}>
                  <UserRound aria-hidden="true" />
                  <span>Minha conta</span>
                </NavLink>
              </SidebarMenuButton>
            </SidebarMenuItem>
          </SidebarMenu>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="shell-logout"
            disabled={signingOut}
            onClick={() => void handleSignOut()}
          >
            {signingOut ? <LoaderCircle className="animate-spin" aria-hidden="true" /> : <LogOut aria-hidden="true" />}
            <span>{signingOut ? 'Saindo…' : 'Sair'}</span>
          </Button>
        </SidebarFooter>
      </Sidebar>

      <SidebarInset className="app-main">
        <header className="app-header">
          <div className="app-header-leading">
            <SidebarTrigger className="app-sidebar-trigger" aria-label="Alternar navegação" />
            <Separator orientation="vertical" className="app-header-divider" />
            <div className="app-header-page">
              <span>Vê na Memória</span>
              <strong>{pageTitle}</strong>
            </div>
          </div>
          <div className="app-header-actions">
            {organization?.name ? (
              <span className="app-header-organization" title={organization.name}>
                <Building2 aria-hidden="true" />
                <span>{organization.name}</span>
              </span>
            ) : null}
            <span className="app-role-label">{roleLabel}</span>
            <NotificationBell />
            <Link className="app-profile-link" to="/conta" aria-label={`Conta de ${displayName}`}>
              <Avatar className="app-profile-avatar">
                <AvatarFallback>{initials(displayName)}</AvatarFallback>
              </Avatar>
              <span className="app-profile-name">{displayName}</span>
            </Link>
          </div>
        </header>
        <div className="main-content">
          <div className="main-inner">
            {storageWarning ? <Alert className="storage-warning" kind="warning">{storageWarning}</Alert> : null}
            <Outlet />
          </div>
        </div>
      </SidebarInset>
    </>
  );
}
