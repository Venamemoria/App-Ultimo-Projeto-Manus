import { Navigate, Outlet, Route, Routes, useLocation } from 'react-router-dom';
import { useSession } from './AuthProvider';
import { AppLayout } from './layout';
import { AccountPage, DashboardPage } from './pages';
import { AuthPage } from '../features/auth/AuthPage';
import { RecoverPage } from '../features/auth/RecoverPage';
import { getSafeNextPath } from '../lib/supabase';

function ProtectedRoute() {
  const { loading, session } = useSession();
  const location = useLocation();

  if (loading) return <div className="loading"><span>Carregando sessão…</span></div>;
  if (!session) {
    return <Navigate replace to="/entrar" state={{ next: getSafeNextPath(location.pathname) }} />;
  }
  return <Outlet />;
}

export default function App() {
  return (
    <Routes>
      <Route path="/entrar" element={<AuthPage />} />
      <Route path="/recuperar" element={<RecoverPage />} />
      <Route element={<ProtectedRoute />}>
        <Route element={<AppLayout />}>
          <Route index element={<DashboardPage />} />
          <Route path="conta" element={<AccountPage />} />
        </Route>
      </Route>
      <Route path="*" element={<Navigate replace to="/" />} />
    </Routes>
  );
}
