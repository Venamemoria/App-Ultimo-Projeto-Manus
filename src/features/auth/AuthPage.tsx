import { useEffect, useState, type FormEvent } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { ArrowRight } from 'lucide-react';
import { Alert, Button, Field, Input } from '../../components/ui';
import { getSafeNextPath } from '../../lib/supabase';
import { useSession } from '../../app/AuthProvider';

export function AuthPage() {
  const { session, loading, error: contextError, storageWarning, signIn, signUp } = useSession();
  const navigate = useNavigate();
  const location = useLocation();
  const next = getSafeNextPath((location.state as { next?: string } | null)?.next);
  const [createMode, setCreateMode] = useState(false);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [passwordConfirmation, setPasswordConfirmation] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!loading && session) navigate(next, { replace: true });
  }, [loading, navigate, next, session]);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(null);
    setNotice(null);
    const normalizedEmail = email.trim().toLowerCase();
    if (!normalizedEmail || !normalizedEmail.includes('@')) {
      setError('Informe um e-mail válido.');
      return;
    }
    if (password.length < 8) {
      setError('A senha deve ter pelo menos 8 caracteres.');
      return;
    }
    if (createMode && password !== passwordConfirmation) {
      setError('As senhas precisam ser iguais.');
      return;
    }

    setSubmitting(true);
    const result = createMode
      ? await signUp(normalizedEmail, password)
      : await signIn(normalizedEmail, password);
    setSubmitting(false);
    if (result.error) {
      setError(result.error);
      return;
    }
    if (createMode && 'confirmed' in result && !result.confirmed) {
      setNotice('Confira seu e-mail para confirmar o acesso. Se já tiver uma conta, use Entrar.');
      setPassword('');
      setPasswordConfirmation('');
    } else {
      navigate(next, { replace: true });
    }
  };

  return (
    <main className="auth-page">
      <section className="auth-editorial">
        <div className="sidebar-brand">
          <img className="brand-mark" src="/brand-mark.webp" alt="" />
          <div className="wordmark">Vê na Memória<small>gestão do ateliê</small></div>
        </div>
        <div className="auth-copy">
          <p className="auth-kicker">Organização artesanal, com clareza</p>
          <h1 className="auth-title">O que importa<br />fica à vista.</h1>
          <p>Um lugar sereno para cuidar do trabalho do ateliê, com registros reais e cada organização no seu próprio espaço.</p>
        </div>
        <p className="auth-footer">Acesso protegido pelo Supabase Auth.</p>
      </section>
      <section className="auth-form-side">
        <div className="auth-form-wrap">
          <p className="eyebrow">{createMode ? 'Novo acesso' : 'Área reservada'}</p>
          <h1>{createMode ? 'Criar seu acesso' : 'Entrar'}</h1>
          <p className="auth-intro">{createMode ? 'Cadastre seu e-mail. Se a confirmação estiver habilitada, enviaremos um link antes do primeiro acesso.' : 'Entre para consultar apenas as organizações autorizadas para sua sessão.'}</p>
          {storageWarning ? <Alert className="auth-alert" kind="warning">{storageWarning}</Alert> : null}
          {contextError && !error && !notice ? <Alert className="auth-alert" kind="error">{contextError}</Alert> : null}
          {error ? <Alert className="auth-alert" kind="error">{error}</Alert> : null}
          {notice ? <Alert className="auth-alert" kind="success">{notice}</Alert> : null}
          <form className="auth-form" onSubmit={submit}>
            <Field label="E-mail">
              <Input type="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="voce@atelie.com" autoComplete="email" required />
            </Field>
            <Field label="Senha" hint={createMode ? 'Use pelo menos 8 caracteres.' : undefined}>
              <Input type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Sua senha" autoComplete={createMode ? 'new-password' : 'current-password'} required />
            </Field>
            {createMode ? (
              <Field label="Confirme a senha">
                <Input type="password" value={passwordConfirmation} onChange={(event) => setPasswordConfirmation(event.target.value)} placeholder="Repita sua senha" autoComplete="new-password" required />
              </Field>
            ) : null}
            <Button type="submit" loading={submitting} icon={<ArrowRight size={17} />}>{createMode ? 'Criar acesso' : 'Entrar'}</Button>
          </form>
          {!createMode ? <div className="auth-links"><Link className="text-link" to="/recuperar">Esqueci minha senha</Link></div> : null}
          <p className="auth-switch">{createMode ? 'Já possui acesso?' : 'Ainda não possui acesso?'}{' '}<button type="button" onClick={() => { setCreateMode((mode) => !mode); setError(null); setNotice(null); }}>{createMode ? 'Entrar' : 'Criar cadastro'}</button></p>
        </div>
      </section>
    </main>
  );
}
