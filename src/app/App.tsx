import { lazy, Suspense } from 'react';
import { Navigate, Outlet, Route, Routes, useLocation } from 'react-router-dom';
import { useSession } from './AuthProvider';
import { AppLayout } from './layout';
import { AccountPage, DashboardPage } from './pages';
import { AuthPage } from '../features/auth/AuthPage';
import { RecoverPage } from '../features/auth/RecoverPage';
import { getSafeNextPath } from '../lib/supabase';

const InventoryPage = lazy(() => import('../features/inventory/InventoryPage').then((module) => ({ default: module.InventoryPage })));
const PurchasesPage = lazy(() => import('../features/purchases/PurchasesPage').then((module) => ({ default: module.PurchasesPage })));
const ProductsPage = lazy(() => import('../features/products/ProductsPage').then((module) => ({ default: module.ProductsPage })));
const ClientsPage = lazy(() => import('../features/contacts/ContactsPage').then((module) => ({ default: module.ClientsPage })));
const SuppliersPage = lazy(() => import('../features/contacts/ContactsPage').then((module) => ({ default: module.SuppliersPage })));
const OrdersPage = lazy(() => import('../features/orders/list').then((module) => ({ default: module.OrdersPage })));
const OrderDetailPage = lazy(() => import('../features/orders/detail').then((module) => ({ default: module.OrderDetailPage })));
const ProductionPage = lazy(() => import('../features/orders/board').then((module) => ({ default: module.ProductionPage })));
const CalendarPage = lazy(() => import('../features/orders/calendar').then((module) => ({ default: module.CalendarPage })));
const QuotesPage = lazy(() => import('../features/publicSales/pages').then((module) => ({ default: module.QuotesPage })));
const PublicQuotePage = lazy(() => import('../features/publicSales/pages').then((module) => ({ default: module.PublicQuotePage })));
const PublicTrackingPage = lazy(() => import('../features/publicSales/pages').then((module) => ({ default: module.PublicTrackingPage })));

function ProtectedRoute() {
  const { loading, session } = useSession();
  const location = useLocation();
  if (loading) return <div className="loading"><span>Carregando sessão…</span></div>;
  if (!session) return <Navigate replace to="/entrar" state={{ next: getSafeNextPath(location.pathname) }} />;
  return <Outlet />;
}

export default function App() {
  return (
    <Suspense fallback={<div className="loading" role="status"><span>Carregando tela…</span></div>}>
      <Routes>
        <Route path="/entrar" element={<AuthPage />} />
        <Route path="/recuperar" element={<RecoverPage />} />
        <Route path="/orcamento/:id" element={<PublicQuotePage />} />
        <Route path="/rastreio/:id" element={<PublicTrackingPage />} />
        <Route element={<ProtectedRoute />}>
          <Route element={<AppLayout />}>
            <Route index element={<DashboardPage />} />
            <Route path="conta" element={<AccountPage />} />
            <Route path="estoque" element={<InventoryPage />} />
            <Route path="compras" element={<PurchasesPage />} />
            <Route path="produtos" element={<ProductsPage />} />
            <Route path="clientes" element={<ClientsPage />} />
            <Route path="fornecedores" element={<SuppliersPage />} />
            <Route path="pedidos" element={<OrdersPage />} />
            <Route path="pedidos/:id" element={<OrderDetailPage />} />
            <Route path="producao" element={<ProductionPage />} />
            <Route path="agenda" element={<CalendarPage />} />
            <Route path="orcamentos" element={<QuotesPage />} />
          </Route>
        </Route>
        <Route path="*" element={<Navigate replace to="/" />} />
      </Routes>
    </Suspense>
  );
}
