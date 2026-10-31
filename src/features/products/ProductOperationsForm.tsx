import { useEffect, useRef, useState, type FormEvent } from 'react';
import { Alert, Button, Field, Input, Loading, Modal, Select, Textarea } from '../../components/ui';
import { useProductDetailQuery, useProductOperationsMutation, productOperationsRpcParams, userFacingProductError } from './api';
import { CompositionEditor } from './ProductForm';
import { formValuesFromSnapshot, type CompositionMode, type MaterialOption, type ProductDto, type ProductFormValues, type ProductOperationsInput } from './types';

type Props = { organizationId: string; product: ProductDto; materials: MaterialOption[]; onClose: () => void; onSaved: () => void };

/** The operational editor never needs, renders or sends pricing fields. */
export function ProductOperationsForm({ organizationId, product, materials, onClose, onSaved }: Props) {
  const detail = useProductDetailQuery(organizationId, product.id);
  const mutation = useProductOperationsMutation(organizationId);
  const [values, setValues] = useState<ProductFormValues | null>(null);
  const [expectedVersion, setExpectedVersion] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState<ProductOperationsInput | null>(null);
  const initialized = useRef(false);
  const nonce = useRef(globalThis.crypto.randomUUID());

  useEffect(() => {
    if (detail.data && !initialized.current) {
      initialized.current = true;
      setValues(formValuesFromSnapshot(detail.data));
      setExpectedVersion(detail.data.product.current_version);
    }
  }, [detail.data]);

  const update = <K extends keyof ProductFormValues>(key: K, value: ProductFormValues[K]) =>
    setValues((current) => current ? { ...current, [key]: value } : current);
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!values) return;
    let input = attempt;
    if (!input) {
      input = {
        organizationId, productId: product.id, expectedVersion, idempotencyKey: nonce.current,
        inventoryMode: values.inventoryMode, description: values.description, materialInfo: values.materialInfo,
        personalizationInfo: values.personalizationInfo, productionDays: values.productionDays,
        components: values.components, variants: values.variants,
      };
      // Validate before freezing an attempt. After a network failure the exact
      // same payload/nonce is retried, avoiding accidental duplicate versions.
      try { productOperationsRpcParams(input); } catch (validation) { setError(userFacingProductError(validation)); return; }
      input = structuredClone(input);
      setAttempt(input);
    }
    setError(null);
    try { await mutation.mutateAsync(input); onSaved(); }
    catch (failure) { setError(userFacingProductError(failure, 'Não foi possível salvar os dados de produção.')); }
  };

  if (detail.isLoading || (!detail.error && !values)) return <Modal open title="Dados de produção" onClose={onClose}><Loading label="Carregando composição atual…" /></Modal>;
  if (detail.error || !values) return <Modal open title="Dados de produção" onClose={onClose}><Alert kind="error">{userFacingProductError(detail.error, 'Não foi possível carregar o produto.')}</Alert></Modal>;

  return <Modal open title={`Dados de produção · ${product.name}`} onClose={onClose}>
    <form className="product-form" onSubmit={(event) => void submit(event)}>
      <p className="form-intro">Edite os dados de produção e as receitas da versão {expectedVersion}. Preços e condições comerciais permanecem inalterados.</p>
      {error ? <Alert kind="error">{error}{attempt ? ' Para alterar os dados, feche e recarregue o produto; ou tente novamente a mesma operação.' : ''}</Alert> : null}
      <fieldset disabled={Boolean(attempt)} className="form-step" style={{ border: 0, padding: 0, margin: 0 }}>
        <Field label="Descrição"><Textarea value={values.description} onChange={(event) => update('description', event.target.value)} maxLength={20000} /></Field>
        <div className="form-grid">
          <Field label="Material e acabamento"><Textarea value={values.materialInfo} onChange={(event) => update('materialInfo', event.target.value)} maxLength={5000} /></Field>
          <Field label="Personalização"><Textarea value={values.personalizationInfo} onChange={(event) => update('personalizationInfo', event.target.value)} maxLength={5000} /></Field>
          <Field label="Dias de produção"><Input inputMode="numeric" value={values.productionDays} onChange={(event) => update('productionDays', event.target.value.replace(/[^0-9]/g, ''))} /></Field>
          <Field label="Consumo de estoque" hint="A escolha será congelada nos novos pedidos e orçamentos."><Select value={values.inventoryMode} onChange={(event) => update('inventoryMode', event.target.value as ProductFormValues['inventoryMode'])}><option value="materials">Consumir insumos da composição</option><option value="no_stock">Produto sem consumo de estoque</option></Select></Field>
        </div>
        {values.inventoryMode === 'no_stock' ? <Alert kind="warning">Remova as receitas base e das variações ativas para marcar o produto sem consumo de estoque.</Alert> : null}
        <CompositionEditor components={values.components} materials={materials} onChange={(components) => update('components', components)} />
        <section className="variants-editor"><h4>Receitas de variações</h4>{values.variants.length ? values.variants.map((variant, index) => <article className="variant-card" key={variant.id}>
          <strong>{variant.name}{variant.active ? '' : ' · desativada'}</strong>
          <Field label="Composição"><Select value={variant.composition_mode} onChange={(event) => update('variants', values.variants.map((item, i) => i === index ? { ...item, composition_mode: event.target.value as CompositionMode, components: event.target.value === 'own' ? item.components : [] } : item))}><option value="inherit_base">Herdar receita base</option><option value="own">Receita própria</option></Select></Field>
          {variant.composition_mode === 'own' ? <CompositionEditor title={`Receita de ${variant.name}`} components={variant.components} materials={materials} onChange={(components) => update('variants', values.variants.map((item, i) => i === index ? { ...item, components } : item))} /> : null}
        </article>) : <p className="muted-note">Nenhuma variação cadastrada.</p>}</section>
      </fieldset>
      <div className="form-actions"><Button type="button" variant="ghost" onClick={onClose}>Fechar</Button><Button type="submit" loading={mutation.isPending}>{attempt ? 'Tentar novamente' : 'Salvar dados de produção'}</Button></div>
    </form>
  </Modal>;
}
