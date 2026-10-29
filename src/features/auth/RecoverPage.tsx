import { useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ArrowLeft, KeyRound } from 'lucide-react';
import { Alert, Button, Field, Input } from '../../components/ui';
import { useSession } from '../../app/AuthProvider';

export function RecoverPage() {
  const { session, recoveryMode, storageWarning, error: contextError, resetPassword, updatePassword } = useSession();
  const navigate = useNavigate();
  const updating = Boolean(session && recoveryMode);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [passwordUpdated, setPasswordUpdated] = useState(false);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(null);
    setNotice(null);
    if (updating) {
      if (password.length < 8) {
        setError('A nova senha deve ter pelo menos 8 caracteres.');
        return;
      }
      if (password !== confirmation) {
        setError('As senhas precisam ser iguais.');
        return;
      }
      setSubmitting(true);
      const result = await updatePassword(password);
      setSubmitting(false);
      if (result.error) setError(result.error);
      else {
        setNotice('Senha atualizada. Seu acesso está pronto.');
        setPasswordUpdated(true);
        setPassword('');
        setConfirmation('');
      }
      return;
    }

    const normalizedEmail = email.trim().toLowerCase();
    if (!normalizedEmail || !normalizedEmail.includes('@')) {
      setError('Informe um e-mail válido.');
      return;
    }
    setSubmitting(true);
    const result = await resetPassword(normalizedEmail);
    setSubmitting(false);
    if (result.error) setError(result.error);
    else setNotice('Se este e-mail estiver cadastrado, você receberá um link para continuar.');
  };

  return (
    <main className="auth-page">
      <section className="auth-editorial">
        <div className="sidebar-brand">
          <img className="brand-mark" src="/brand-mark.webp" alt="" />
          <div className="wordmark">Vê na Memória<small>gestão do ateliê</small></div>
        </div>
        <div className="auth-copy">
          <p className="auth-kicker">Acesso com cuidado</p>
          <h1 className="auth-title">Sua conta<br />continua sua.</h1>
          <p>Use um link enviado ao seu e-mail para recuperar o acesso. Depois, escolha uma nova senha para continuar.</p>
        </div>
        <p className="auth-footer">Nenhuma organização é assumida durante a recuperação.</p>
      </section>
      <section className="auth-form-side">
        <div className="auth-form-wrap">
          <p className="eyebrow">{updating ? 'Atualizar senha' : 'Recuperar acesso'}</p>
          <h1>{passwordUpdated ? 'Acesso recuperado' : updating ? 'Escolha uma nova senha' : 'Esqueci minha senha'}</h1>
          <p className="auth-intro">{passwordUpdated ? 'Sua senha foi alterada. Você pode continuar na sua organização.' : updating ? 'Esta atualização vale para sua sessão autenticada pelo fluxo de recuperação.' : 'Informe seu e-mail e enviaremos um link de recuperação, quando houver uma conta correspondente.'}</p>
          {storageWarning ? <Alert className="auth-alert" kind="warning">{storageWarning}</Alert> : null}
          {contextError && !error && !notice ? <Alert className="auth-alert" kind="error">{contextError}</Alert> : null}
          {error ? <Alert className="auth-alert" kind="error">{error}</Alert> : null}
          {notice ? <Alert className="auth-alert" kind="success">{notice}</Alert> : null}
          {passwordUpdated ? <Button onClick={() => navigate('/')}>Ir para o painel</Button> : <form className="auth-form" onSubmit={submit}>
            {!updating ? <Field label="E-mail"><Input type="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="voce@atelie.com" autoComplete="email" required /></Field> : null}
            {updating ? <>
              <Field label="Nova senha" hint="Use pelo menos 8 caracteres."><Input type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Nova senha" autoComplete="new-password" required /></Field>
              <Field label="Confirme a nova senha"><Input type="password" value={confirmation} onChange={(event) => setConfirmation(event.target.value)} placeholder="Repita sua nova senha" autoComplete="new-password" required /></Field>
            </> : null}
            <Button type="submit" loading={submitting} icon={updating ? <KeyRound size={17} /> : undefined}>{updating ? 'Atualizar senha' : 'Enviar link'}</Button>
          </form>}
          <div className="auth-links"><Link className="text-link" to="/entrar"><ArrowLeft size={14} /> Voltar para entrar</Link>{notice && updating ? <button className="text-link" type="button" onClick={() => navigate('/')}>Ir para o painel</button> : null}</div>
        </div>
      </section>
    </main>
  );
}
