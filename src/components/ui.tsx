import { useEffect, useId, useRef, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode, type SelectHTMLAttributes, type TextareaHTMLAttributes } from 'react';
import { AlertCircle, CheckCircle2, Info, LoaderCircle, X } from 'lucide-react';

const join = (...classes: Array<string | undefined | false>) => classes.filter(Boolean).join(' ');

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger';

export function Button({
  variant = 'primary',
  loading = false,
  icon,
  className,
  children,
  disabled,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant;
  loading?: boolean;
  icon?: ReactNode;
}) {
  return (
    <button
      className={join('button', `button-${variant}`, className)}
      disabled={disabled || loading}
      {...props}
    >
      {loading ? <LoaderCircle className="button-icon spin" aria-hidden="true" /> : icon}
      <span>{children}</span>
    </button>
  );
}

export function Field({
  label,
  hint,
  error,
  children,
}: {
  label: string;
  hint?: string;
  error?: string;
  children: ReactNode;
}) {
  const hintId = useId();
  const errorId = useId();
  return (
    <div className="field">
      <label className="field-label">{label}</label>
      {children}
      {hint && !error ? <p id={hintId} className="field-hint">{hint}</p> : null}
      {error ? <p id={errorId} className="field-error" role="alert">{error}</p> : null}
    </div>
  );
}

export function Input(props: InputHTMLAttributes<HTMLInputElement>) {
  return <input className={join('input', props.className)} {...props} />;
}

export function Select(props: SelectHTMLAttributes<HTMLSelectElement>) {
  return <select className={join('input', 'select', props.className)} {...props} />;
}

export function Textarea(props: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea className={join('input', 'textarea', props.className)} {...props} />;
}

export function EmptyState({
  title,
  description,
  action,
}: {
  title: string;
  description: string;
  action?: ReactNode;
}) {
  return (
    <section className="empty-state">
      <div className="empty-mark" aria-hidden="true">✦</div>
      <h2>{title}</h2>
      <p>{description}</p>
      {action ? <div className="empty-action">{action}</div> : null}
    </section>
  );
}

export function PageHeader({
  eyebrow,
  title,
  description,
  action,
}: {
  eyebrow?: string;
  title: string;
  description?: string;
  action?: ReactNode;
}) {
  return (
    <div className="page-header">
      <div>
        {eyebrow ? <p className="eyebrow">{eyebrow}</p> : null}
        <h1>{title}</h1>
        {description ? <p className="page-description">{description}</p> : null}
      </div>
      {action ? <div className="page-header-action">{action}</div> : null}
    </div>
  );
}

export function Alert({
  kind = 'info',
  children,
  className,
}: {
  kind?: 'info' | 'success' | 'warning' | 'error';
  children: ReactNode;
  className?: string;
}) {
  const Icon = kind === 'error' ? AlertCircle : kind === 'success' ? CheckCircle2 : kind === 'warning' ? AlertCircle : Info;
  return (
    <div className={join('alert', `alert-${kind}`, className)} role={kind === 'error' ? 'alert' : 'status'}>
      <Icon size={18} aria-hidden="true" />
      <div>{children}</div>
    </div>
  );
}

export function Modal({
  title,
  open,
  onClose,
  children,
}: {
  title: string;
  open: boolean;
  onClose: () => void;
  children: ReactNode;
}) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const previousFocus = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!open) return;
    previousFocus.current = document.activeElement as HTMLElement | null;
    const dialog = dialogRef.current;
    const focusable = dialog?.querySelector<HTMLElement>(
      'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [href], [tabindex]:not([tabindex="-1"])',
    );
    focusable?.focus();

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        onClose();
        return;
      }
      if (event.key !== 'Tab' || !dialog) return;
      const elements = Array.from(dialog.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [href], [tabindex]:not([tabindex="-1"])',
      ));
      if (!elements.length) return;
      const first = elements[0];
      const last = elements[elements.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('keydown', onKeyDown);
      previousFocus.current?.focus();
    };
  }, [onClose, open]);

  if (!open) return null;
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="modal" role="dialog" aria-modal="true" aria-labelledby="modal-title" ref={dialogRef}>
        <div className="modal-header">
          <h2 id="modal-title">{title}</h2>
          <button className="icon-button" type="button" aria-label="Fechar" onClick={onClose}><X size={19} /></button>
        </div>
        <div className="modal-content">{children}</div>
      </div>
    </div>
  );
}

export function StatCard({
  label,
  value,
  footnote,
  icon,
}: {
  label: string;
  value: string;
  footnote?: string;
  icon?: ReactNode;
}) {
  return (
    <article className="stat-card">
      <div className="stat-card-top">
        <span>{label}</span>
        {icon ? <span className="stat-icon">{icon}</span> : null}
      </div>
      <strong>{value}</strong>
      {footnote ? <small>{footnote}</small> : null}
    </article>
  );
}

export function Loading({ label = 'Carregando…' }: { label?: string }) {
  return (
    <div className="loading" role="status">
      <LoaderCircle className="spin" size={22} aria-hidden="true" />
      <span>{label}</span>
    </div>
  );
}
