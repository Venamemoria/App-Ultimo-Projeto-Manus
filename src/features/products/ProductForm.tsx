import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { Check, ChevronLeft, ChevronRight, FileImage, Info, Plus, Trash2, Upload, X } from 'lucide-react';
import { Alert, Button, Field, Input, Modal, Select, Textarea } from '../../components/ui';
import { COMPOSITION_COST_SCALE, formatDecimal, parseDecimalInput } from '../../lib/decimal';
import { formatCurrency } from '../../lib/format';
import { useProductDetailQuery, useProductFileMutation, useProductMaterialsQuery, useUpsertProductMutation, registerExistingProductFile, ProductFileRegistrationError, userFacingProductError } from './api';
import { resolveProductPrice, validateWholesaleTiers } from './pricing';
import { emptyFormValues, formValuesFromSnapshot, type CompositionMode, type CustomQuestion, type MaterialOption, type ProductComponent, type ProductDto, type ProductFileKind, type ProductFormValues, type ProductUpsertResult, type VariantSnapshot, type WholesaleTier } from './types';

const steps = ['Produto', 'Preço', 'Descrição', 'Ajustes finais'];
const maxFileSize = 52428800;

type Props = { organizationId: string; product: ProductDto | null; materials: MaterialOption[]; onClose: () => void; onSaved: () => void };
type PendingRegistration = { path: string; mimeType: string; sizeBytes: number; name: string; kind: ProductFileKind };

function idempotencyKey() { return globalThis.crypto.randomUUID(); }

function parseTags(value: string) { return value.split(',').map((item) => item.trim()).filter(Boolean); }

async function validatePhoto(file: File): Promise<string | null> {
  if (file.size > maxFileSize) return 'A foto ultrapassa o limite de 50 MiB.';
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) return 'Escolha uma foto JPG, PNG ou WebP.';
  const bytes = new Uint8Array(await file.slice(0, 12).arrayBuffer());
  const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a;
  const webp = bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === 'RIFF' && String.fromCharCode(...bytes.slice(8, 12)) === 'WEBP';
  return jpeg || png || webp ? null : 'O conteúdo da foto não corresponde a um JPG, PNG ou WebP válido.';
}

function decimalField(value: string, label: string, positive = false) {
  try { parseDecimalInput(value, { positive }); return null; } catch (error) { return error instanceof Error ? `${label}: ${error.message}` : `${label} inválido.`; }
}

function validateForm(values: ProductFormValues): string | null {
  if (!values.name.trim()) return 'Informe o nome do produto.';
  if (!values.categories.length || !values.categories[0]?.trim()) return 'Informe ao menos uma categoria; a primeira será a principal.';
  const priceError = decimalField(values.price, 'Preço');
  if (priceError) return priceError;
  if (values.promoPrice.trim()) {
    const promoError = decimalField(values.promoPrice, 'Preço promocional');
    if (promoError) return promoError;
    try {
      if (parseDecimalInput(values.promoPrice).gt(parseDecimalInput(values.price))) return 'O preço promocional não pode ser maior que o preço normal.';
    } catch (error) {
      return error instanceof Error ? error.message : 'Preço promocional inválido.';
    }
  }
  const minimumError = decimalField(values.minimumQuantity, 'Quantidade mínima', true);
  if (minimumError) return minimumError;
  if (values.inventoryMode === 'no_stock' && (values.components.length > 0 || values.variants.some((variant) => variant.active && variant.composition_mode === 'own' && variant.components.length > 0))) return 'Produto sem consumo de estoque não pode ter receita base ou de variação ativa. Remova os insumos ou selecione consumo de materiais.';
  if (values.pricingMode === 'variation' && !values.variants.some((variant) => variant.active)) return 'O modo por variação exige ao menos uma variação ativa.';
  const tierError = validateWholesaleTiers(values.wholesaleTiers);
  if (tierError) return tierError;
  for (const component of values.components) {
    if (!component.material_id) return 'Escolha um material para cada linha da receita base.';
    const error = decimalField(component.quantity, 'Quantidade da receita', true);
    if (error) return error;
  }
  for (const variant of values.variants) {
    if (!variant.name.trim()) return 'Toda variação precisa de nome.';
    const error = decimalField(variant.price, `Preço da variação ${variant.name}`, false);
    if (error) return error;
    if (variant.promo_price?.trim()) {
      const promoError = decimalField(variant.promo_price, 'Preço promocional da variação');
      if (promoError) return promoError;
      try {
        if (parseDecimalInput(variant.promo_price).gt(parseDecimalInput(variant.price))) return `A promoção da variação ${variant.name} não pode superar seu preço normal.`;
      } catch (error) {
        return error instanceof Error ? error.message : 'Preço promocional da variação inválido.';
      }
    }
    if (variant.minimum_quantity?.trim()) {
      const minError = decimalField(variant.minimum_quantity, 'Quantidade mínima da variação', true);
      if (minError) return minError;
    }
    if (variant.composition_mode === 'own') for (const component of variant.components) {
      if (!component.material_id) return `Escolha o material da receita própria de ${variant.name}.`;
      const componentError = decimalField(component.quantity, 'Quantidade da receita própria', true);
      if (componentError) return componentError;
    }
  }
  const days = Number(values.productionDays);
  if (!Number.isInteger(days) || days < 0 || days > 10000) return 'Dias de produção deve ser um inteiro entre 0 e 10.000.';
  for (const [value, label] of [[values.weightKg, 'Peso'], [values.widthCm, 'Largura'], [values.heightCm, 'Altura'], [values.depthCm, 'Profundidade']] as const) if (value.trim() && decimalField(value, label, true)) return decimalField(value, label, true);
  for (const question of values.customQuestions) {
    if (!question.label.trim()) return 'Toda pergunta ao cliente precisa de rótulo.';
    if (question.type === 'select' && !(question.options ?? []).some((option) => option.trim())) return 'Perguntas de seleção precisam de ao menos uma opção.';
  }
  return null;
}

function materialName(materials: MaterialOption[], id: string) { return materials.find((material) => material.id === id)?.name ?? id.slice(0, 8); }

function CompositionEditor({ components, materials, onChange, title = 'Receita base' }: { components: ProductComponent[]; materials: MaterialOption[]; onChange: (next: ProductComponent[]) => void; title?: string }) {
  const add = () => { const material = materials[0]; if (material) onChange([...components, { material_id: material.id, quantity: '1', unit: material.unit }]); };
  const update = (index: number, patch: Partial<ProductComponent>) => onChange(components.map((component, itemIndex) => itemIndex === index ? { ...component, ...patch } : component));
  return <section className="composition-editor"><div className="subsection-heading"><div><h4>{title}</h4><p>Quantidade fracionária, até 8 casas, na unidade real do insumo.</p></div><Button type="button" variant="secondary" icon={<Plus size={15} />} disabled={!materials.length} onClick={add}>Adicionar material</Button></div>{!components.length ? <p className="muted-note">Nenhum material na receita. Para serviços, o custo real permanece R$ 0,00.</p> : <div className="composition-lines">{components.map((component, index) => { const material = materials.find((item) => item.id === component.material_id); return <div className="composition-line" key={`${component.material_id}-${index}`}><label><span>Material</span><Select value={component.material_id} onChange={(event) => { const next = materials.find((item) => item.id === event.target.value); update(index, { material_id: event.target.value, unit: next?.unit ?? component.unit }); }}><option value="">Selecione</option>{materials.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.unit}</option>)}</Select></label><label><span>Quantidade</span><Input inputMode="decimal" value={component.quantity} onChange={(event) => update(index, { quantity: event.target.value })} placeholder="0,00000000" /></label><label><span>Unidade</span><Input value={material?.unit ?? component.unit} readOnly aria-label="Unidade do material" /></label><Button type="button" variant="ghost" className="remove-line" aria-label={`Remover ${materialName(materials, component.material_id)}`} icon={<Trash2 size={15} />} onClick={() => onChange(components.filter((_, itemIndex) => itemIndex !== index))}>Remover</Button></div>; })}</div>}</section>;
}

function VariantsEditor({ variants, materials, onChange }: { variants: VariantSnapshot[]; materials: MaterialOption[]; onChange: (next: VariantSnapshot[]) => void }) {
  const add = () => onChange([...variants, { id: '', name: '', sku: null, price: '', promo_price: null, active: true, minimum_quantity: null, composition_mode: 'inherit_base', components: [] }]);
  const update = (index: number, patch: Partial<VariantSnapshot>) => onChange(variants.map((variant, itemIndex) => itemIndex === index ? { ...variant, ...patch } : variant));
  const remove = (index: number) => { const variant = variants[index]; if (variant?.id) update(index, { active: false }); else onChange(variants.filter((_, itemIndex) => itemIndex !== index)); };
  return <section className="variants-editor"><div className="subsection-heading"><div><h4>Variações</h4><p>Variações omitidas permanecem no banco; desative as que não devem mais ser escolhidas.</p></div><Button type="button" variant="secondary" icon={<Plus size={15} />} onClick={add}>Adicionar variação</Button></div>{!variants.length ? <p className="muted-note">Nenhuma variação cadastrada.</p> : variants.map((variant, index) => <article className="variant-card" key={variant.id || `new-${index}`}><div className="variant-card-header"><strong>{variant.name || `Variação ${index + 1}`}</strong><Button type="button" variant="ghost" aria-label={variant.id ? 'Desativar variação' : 'Remover variação'} icon={<Trash2 size={15} />} onClick={() => remove(index)}>{variant.id ? 'Desativar' : 'Remover'}</Button></div><div className="form-grid"><Field label="Nome"><Input value={variant.name} onChange={(event) => update(index, { name: event.target.value })} maxLength={200} placeholder="Ex.: Papel kraft" /></Field><Field label="Preço"><Input inputMode="decimal" value={variant.price} onChange={(event) => update(index, { price: event.target.value })} placeholder="0,00" /></Field><Field label="Promoção"><Input inputMode="decimal" value={variant.promo_price ?? ''} onChange={(event) => update(index, { promo_price: event.target.value || null })} placeholder="Opcional" /></Field><Field label="MOQ da variação"><Input inputMode="decimal" value={variant.minimum_quantity ?? ''} onChange={(event) => update(index, { minimum_quantity: event.target.value || null })} placeholder="Usa o MOQ do produto se vazio" /></Field><Field label="SKU da variação"><Input value={variant.sku ?? ''} onChange={(event) => update(index, { sku: event.target.value || null })} maxLength={120} /></Field><Field label="Composição"><Select value={variant.composition_mode} onChange={(event) => update(index, { composition_mode: event.target.value as CompositionMode, components: event.target.value === 'own' ? variant.components : [] })}><option value="inherit_base">Herdar receita base</option><option value="own">Receita própria</option></Select></Field></div><label className="check-line"><input type="checkbox" checked={variant.active} onChange={(event) => update(index, { active: event.target.checked })} /> Variação ativa</label>{variant.composition_mode === 'own' ? <CompositionEditor title={`Receita própria de ${variant.name || 'variação'}`} components={variant.components} materials={materials} onChange={(components) => update(index, { components })} /> : null}</article>)}</section>;
}

function QuestionsEditor({ questions, onChange }: { questions: CustomQuestion[]; onChange: (next: CustomQuestion[]) => void }) {
  const add = () => onChange([...questions, { label: '', type: 'text', required: false }]);
  const update = (index: number, patch: Partial<CustomQuestion>) => onChange(questions.map((question, itemIndex) => itemIndex === index ? { ...question, ...patch } : question));
  return <section className="questions-editor"><div className="subsection-heading"><div><h4>Perguntas ao cliente</h4><p>As respostas serão dados do pedido futuro, não são preenchidas neste cadastro.</p></div><Button type="button" variant="secondary" icon={<Plus size={15} />} onClick={add}>Adicionar pergunta</Button></div>{questions.map((question, index) => <article className="question-card" key={`question-${index}`}><div className="form-grid"><Field label="Rótulo"><Input value={question.label} maxLength={200} onChange={(event) => update(index, { label: event.target.value })} placeholder="Ex.: Texto para personalização" /></Field><Field label="Tipo"><Select value={question.type} onChange={(event) => update(index, { type: event.target.value as CustomQuestion['type'], options: event.target.value === 'select' ? (question.options ?? ['']) : undefined })}><option value="text">Texto curto</option><option value="textarea">Texto longo</option><option value="select">Seleção</option><option value="boolean">Sim ou não</option><option value="number">Número</option></Select></Field></div><label className="check-line"><input type="checkbox" checked={question.required} onChange={(event) => update(index, { required: event.target.checked })} /> Resposta obrigatória</label>{question.type === 'select' ? <Field label="Opções" hint="Uma opção por linha"><Textarea value={(question.options ?? []).join('\n')} onChange={(event) => update(index, { options: event.target.value.split('\n') })} placeholder="Opção 1\nOpção 2" /></Field> : null}<Button type="button" variant="ghost" icon={<Trash2 size={15} />} onClick={() => onChange(questions.filter((_, itemIndex) => itemIndex !== index))}>Remover pergunta</Button></article>)}</section>;
}

export function ProductForm({ organizationId, product, materials: suppliedMaterials, onClose, onSaved }: Props) {
  const detailQuery = useProductDetailQuery(organizationId, product?.id ?? null);
  const materialsQuery = useProductMaterialsQuery(organizationId);
  const materials = suppliedMaterials.length ? suppliedMaterials : materialsQuery.data ?? [];
  const saveMutation = useUpsertProductMutation(organizationId);
  const fileMutation = useProductFileMutation(organizationId);
  const [values, setValues] = useState<ProductFormValues>(() => emptyFormValues());
  const [step, setStep] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [selectedPhoto, setSelectedPhoto] = useState<File | null>(null);
  const [previewOpen, setPreviewOpen] = useState(false);
  const [savedResult, setSavedResult] = useState<ProductUpsertResult | null>(null);
  const [pending, setPending] = useState<PendingRegistration | null>(null);
  const [pendingMessage, setPendingMessage] = useState<string | null>(null);
  const keyRef = useRef(idempotencyKey());

  useEffect(() => {
    if (product && detailQuery.data) setValues(formValuesFromSnapshot(detailQuery.data));
    if (!product) setValues(emptyFormValues());
  }, [detailQuery.data, product]);

  const update = <K extends keyof ProductFormValues>(key: K, value: ProductFormValues[K]) => setValues((current) => ({ ...current, [key]: value }));
  const pricePreview = useMemo(() => { try { return resolveProductPrice({ pricingMode: values.pricingMode, normalPrice: values.price, promoPrice: values.promoPrice || null, quantity: values.minimumQuantity || '1', minimumQuantity: values.minimumQuantity, wholesaleTiers: values.wholesaleTiers, variant: values.variants.find((variant) => variant.active) ?? null, areaM2: values.minimumQuantity || '1' }); } catch { return null; } }, [values.minimumQuantity, values.price, values.pricingMode, values.promoPrice, values.variants, values.wholesaleTiers]);
  const quality = [values.name.trim(), values.categories[0], values.price, values.description.trim(), values.components.length ? 'recipe' : '', values.productionDays, values.sku.trim()].filter(Boolean).length;

  if (product && detailQuery.isLoading) return <Modal open title="Editar produto" onClose={onClose}><div className="form-loading">Carregando snapshot da versão atual…</div></Modal>;
  if (product && detailQuery.error) return <Modal open title="Editar produto" onClose={onClose}><Alert kind="error">{userFacingProductError(detailQuery.error, 'Não foi possível carregar o snapshot atual.')}</Alert></Modal>;

  const onPhotoChange = async (file: File | undefined) => {
    if (!file) return;
    const validation = await validatePhoto(file);
    if (validation) { setError(validation); return; }
    setError(null);
    setSelectedPhoto(file);
  };

  const submit = async (event?: FormEvent) => {
    event?.preventDefault();
    const validation = validateForm(values);
    if (validation) { setError(validation); setStep(validation.includes('variação') ? 1 : 0); return; }
    setError(null);
    try {
      const result = await saveMutation.mutateAsync({ organizationId, productId: product?.id ?? null, idempotencyKey: keyRef.current, values });
      setSavedResult(result);
      if (selectedPhoto) {
        try {
          await fileMutation.mutateAsync({ organizationId, productId: result.product_id, kind: 'photo', file: selectedPhoto });
          onSaved();
        } catch (uploadError) {
          if (uploadError instanceof ProductFileRegistrationError) setPending({ path: uploadError.path, mimeType: selectedPhoto.type, sizeBytes: selectedPhoto.size, name: selectedPhoto.name, kind: 'photo' });
          setPendingMessage(userFacingProductError(uploadError, 'O produto foi salvo, mas o registro da foto ficou pendente.'));
        }
      } else onSaved();
    } catch (saveError) {
      setError(userFacingProductError(saveError, 'Não foi possível salvar o produto. Mantenha os mesmos dados ao tentar novamente.'));
    }
  };

  const retryRegistration = async () => {
    if (!pending || !savedResult) return;
    setPendingMessage(null);
    try {
      await registerExistingProductFile({ organizationId, productId: savedResult.product_id, kind: pending.kind, path: pending.path, mimeType: pending.mimeType, sizeBytes: pending.sizeBytes, name: pending.name });
      setPending(null);
      onSaved();
    } catch (retryError) { setPendingMessage(userFacingProductError(retryError, 'Não foi possível registrar a foto pendente. O objeto não será reenviado.')); }
  };

  const addCategory = () => { const tags = parseTags(values.categoryInput); update('categories', Array.from(new Set([...values.categories, ...tags]))); update('categoryInput', ''); };
  const addTier = () => update('wholesaleTiers', [...values.wholesaleTiers, { minimum_quantity: '', unit_price: '' }]);

  return <Modal open title={product ? 'Editar produto' : 'Novo produto'} onClose={onClose}><form className="product-form" onSubmit={(event) => void submit(event)}>
    <div className="form-stepper" role="tablist" aria-label="Etapas do produto">{steps.map((label, index) => <button key={label} type="button" role="tab" aria-selected={step === index} className={step === index ? 'step active' : 'step'} onClick={() => setStep(index)}><span>{index + 1}</span>{label}</button>)}</div>
    {error ? <Alert kind="error">{error}</Alert> : null}
    {pendingMessage ? <Alert kind="warning"><p>{pendingMessage}</p>{pending ? <><p className="pending-path">A transferência foi confirmada. O arquivo privado aguarda registro, sem precisar de outro envio.</p><Button type="button" variant="secondary" loading={saveMutation.isPending || fileMutation.isPending} onClick={() => void retryRegistration()}>Tentar registrar novamente</Button></> : <><p>O produto foi salvo, mas a transferência da foto não foi confirmada. Você poderá anexá-la na seção Arquivos do produto.</p><Button type="button" variant="secondary" onClick={onSaved}>Continuar com o produto salvo</Button></>}</Alert> : null}
    {savedResult ? <Alert kind="success">Produto salvo na versão {savedResult.version}. Custo congelado da receita: R$ {formatDecimal(savedResult.composition_cost, COMPOSITION_COST_SCALE)}.</Alert> : null}
    {step === 0 ? <section className="form-step"><p className="form-intro">Identifique o produto e anexe uma foto real opcional. A foto só é enviada depois que o produto for aceito pela RPC.</p><Field label="Nome do produto"><Input autoFocus value={values.name} onChange={(event) => update('name', event.target.value)} maxLength={200} placeholder="Ex.: Caixa de memórias" /></Field><div className="tag-editor"><span className="field-label">Categorias <small>(a primeira é a principal)</small></span><div className="tag-list">{values.categories.map((category, index) => <span className={index === 0 ? 'tag primary' : 'tag'} key={`${category}-${index}`}>{category}{index === 0 ? ' · principal' : ''}<button type="button" aria-label={`Remover categoria ${category}`} onClick={() => update('categories', values.categories.filter((_, itemIndex) => itemIndex !== index))}><X size={13} /></button></span>)}</div><div className="tag-input"><Input value={values.categoryInput} onChange={(event) => update('categoryInput', event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ',') { event.preventDefault(); addCategory(); } }} onBlur={addCategory} placeholder="Digite uma categoria e pressione Enter" /><Button type="button" variant="secondary" onClick={addCategory}>Adicionar</Button></div><p className="field-hint">A categoria principal também será enviada em p_category; múltiplas categorias ficam preservadas no snapshot.</p></div><Field label="Subcategoria" hint="Opcional"><Input value={values.subcategory} onChange={(event) => update('subcategory', event.target.value)} maxLength={120} /></Field><Field label="Foto do produto" hint="JPG, PNG ou WebP real, até 50 MiB. O objeto ficará privado e receberá URL assinada somente para visualização."><label className="file-picker"><FileImage size={18} /><span>{selectedPhoto?.name ?? 'Escolher foto'}</span><input type="file" accept="image/jpeg,image/png,image/webp" onChange={(event) => void onPhotoChange(event.target.files?.[0])} /></label></Field></section> : null}
    {step === 1 ? <section className="form-step"><p className="form-intro">Preços e receitas usam precisão decimal textual. O custo indicativo é calculado pelo banco a partir do snapshot do custo atual de cada material.</p><div className="mode-options" role="radiogroup" aria-label="Modo de preço">{(['unit', 'variation', 'm2'] as const).map((mode) => <label className={values.pricingMode === mode ? 'mode-option selected' : 'mode-option'} key={mode}><input type="radio" name="pricing-mode" value={mode} checked={values.pricingMode === mode} onChange={() => update('pricingMode', mode)} /><strong>{mode === 'unit' ? 'Fixo por unidade' : mode === 'variation' ? 'Por variação' : 'Por metro quadrado'}</strong><small>{mode === 'm2' ? 'Cobrança rotulada em 1 m²' : mode === 'variation' ? 'Cada opção tem preço próprio' : 'Um preço para o produto'}</small></label>)}</div><div className="form-grid"><Field label={values.pricingMode === 'm2' ? 'Preço normal por 1 m²' : 'Preço normal'}><Input inputMode="decimal" value={values.price} onChange={(event) => update('price', event.target.value)} placeholder="0,00" /></Field><Field label="Preço promocional" hint="Opcional; não pode superar o normal"><Input inputMode="decimal" value={values.promoPrice} onChange={(event) => update('promoPrice', event.target.value)} placeholder="0,00" /></Field></div>{pricePreview ? <div className="price-preview"><span>Prévia para o MOQ configurado</span><strong>{formatCurrency(pricePreview.totalPrice)} · {formatCurrency(pricePreview.unitPrice)} / {pricePreview.billingUnit === 'm2' ? 'm²' : 'un.'}</strong><small>{pricePreview.source === 'wholesale' ? 'Faixa de atacado qualificada' : pricePreview.source === 'promo' || pricePreview.source === 'variant-promo' ? 'Preço promocional' : 'Preço normal'}</small></div> : null}<div className="subsection-heading"><div><h4>Faixas de atacado</h4><p>Quantidade mínima crescente e preço por unidade.</p></div><Button type="button" variant="secondary" icon={<Plus size={15} />} onClick={addTier}>Adicionar faixa</Button></div>{values.wholesaleTiers.map((tier, index) => <div className="tier-line" key={`tier-${index}`}><Input aria-label="Quantidade mínima da faixa" inputMode="decimal" value={tier.minimum_quantity} onChange={(event) => update('wholesaleTiers', values.wholesaleTiers.map((item, itemIndex) => itemIndex === index ? { ...item, minimum_quantity: event.target.value } : item))} placeholder="A partir de" /><Input aria-label="Preço da faixa" inputMode="decimal" value={tier.unit_price} onChange={(event) => update('wholesaleTiers', values.wholesaleTiers.map((item, itemIndex) => itemIndex === index ? { ...item, unit_price: event.target.value } : item))} placeholder="Preço" /><Button type="button" variant="ghost" icon={<Trash2 size={15} />} aria-label="Remover faixa" onClick={() => update('wholesaleTiers', values.wholesaleTiers.filter((_, itemIndex) => itemIndex !== index))}>Remover</Button></div>)}<Field label="Consumo de estoque" hint="Esta escolha será congelada nos novos pedidos e orçamentos."><Select value={values.inventoryMode} onChange={(event) => update('inventoryMode', event.target.value as ProductFormValues['inventoryMode'])}><option value="materials">Consumir insumos da composição</option><option value="no_stock">Produto sem consumo de estoque</option></Select></Field>{values.inventoryMode === 'no_stock' ? <Alert kind="warning">Escolha explícita: este produto não fará baixa de materiais. Remova as receitas base e das variações ativas antes de salvar.</Alert> : <p className="field-hint">Produtos com consumo precisam de uma composição válida antes de gerar pedidos e orçamentos. Para preço por variação, cada opção precisa usar uma receita válida.</p>}<CompositionEditor components={values.components} materials={materials} onChange={(components) => update('components', components)} /><VariantsEditor variants={values.variants} materials={materials} onChange={(variants) => update('variants', variants)} /></section> : null}
    {step === 2 ? <section className="form-step"><Field label="Descrição" hint="Texto puro, sem HTML ou scripts"><Textarea value={values.description} onChange={(event) => update('description', event.target.value)} maxLength={20000} placeholder="Descreva o produto, acabamento e uso." /></Field><div className="form-grid"><Field label="Material e acabamento"><Textarea value={values.materialInfo} onChange={(event) => update('materialInfo', event.target.value)} maxLength={5000} /></Field><Field label="Personalização"><Textarea value={values.personalizationInfo} onChange={(event) => update('personalizationInfo', event.target.value)} maxLength={5000} /></Field></div><Field label="Dias de produção" hint="Inteiro entre 0 e 10.000"><Input inputMode="numeric" value={values.productionDays} onChange={(event) => update('productionDays', event.target.value.replace(/[^0-9]/g, ''))} /></Field><div className="plain-info"><Info size={17} /><span>O editor é uma textarea simples. Não há HTML renderizado e o valor fica salvo como texto para evitar XSS.</span></div></section> : null}
    {step === 3 ? <section className="form-step"><div className="form-grid"><Field label="Quantidade mínima (MOQ)"><Input inputMode="decimal" value={values.minimumQuantity} onChange={(event) => update('minimumQuantity', event.target.value)} placeholder="1" /></Field><Field label="Peso (kg)" hint="Opcional"><Input inputMode="decimal" value={values.weightKg} onChange={(event) => update('weightKg', event.target.value)} /></Field><Field label="Largura (cm)" hint="Opcional"><Input inputMode="decimal" value={values.widthCm} onChange={(event) => update('widthCm', event.target.value)} /></Field><Field label="Altura (cm)" hint="Opcional"><Input inputMode="decimal" value={values.heightCm} onChange={(event) => update('heightCm', event.target.value)} /></Field><Field label="Profundidade (cm)" hint="Opcional"><Input inputMode="decimal" value={values.depthCm} onChange={(event) => update('depthCm', event.target.value)} /></Field><Field label="SKU" hint="Único por organização"><Input value={values.sku} onChange={(event) => update('sku', event.target.value)} maxLength={120} /></Field><Field label="Código de barras" hint="Único por organização"><Input value={values.barcode} onChange={(event) => update('barcode', event.target.value)} maxLength={120} /></Field></div><QuestionsEditor questions={values.customQuestions} onChange={(questions) => update('customQuestions', questions)} /><div className="preferences-box"><label className="check-line"><input type="checkbox" checked={values.isCatalogVisible} onChange={(event) => update('isCatalogVisible', event.target.checked)} /> Marcar como visível no catálogo</label><p>A preferência é persistida, mas permanece inativa enquanto o catálogo público não estiver habilitado. Esta tela não publica uma vitrine.</p><label className="check-line"><input type="checkbox" checked={values.isFeatured} onChange={(event) => update('isFeatured', event.target.checked)} /> Marcar como destaque</label></div><div className="quality-preview"><div><span>Qualidade do cadastro</span><strong>{quality}/7 sinais preenchidos</strong></div><Button type="button" variant="secondary" onClick={() => setPreviewOpen(true)}>Prévia do layout</Button></div></section> : null}
    <div className="form-actions form-navigation"><Button type="button" variant="ghost" disabled={step === 0} icon={<ChevronLeft size={16} />} onClick={() => setStep((current) => Math.max(0, current - 1))}>Voltar</Button>{step < steps.length - 1 ? <Button type="button" icon={<ChevronRight size={16} />} onClick={() => { const validation = step === 0 && !values.name.trim() ? 'Informe o nome do produto.' : step === 0 && !values.categories.length ? 'Informe ao menos uma categoria.' : null; if (validation) setError(validation); else { setError(null); setStep((current) => current + 1); } }}>Continuar</Button> : <Button type="submit" loading={saveMutation.isPending || fileMutation.isPending} icon={<Check size={16} />}>{product ? 'Salvar nova versão' : 'Salvar produto'}</Button>}</div>
  </form>{previewOpen ? <Modal open title="Prévia do layout do produto" onClose={() => setPreviewOpen(false)}><div className="catalog-preview">{selectedPhoto ? <img src={URL.createObjectURL(selectedPhoto)} alt="Prévia da foto escolhida" /> : <div className="preview-photo-empty">Sem foto escolhida</div>}<p className="eyebrow">{values.categories[0] ?? 'Categoria'}</p><h3>{values.name || 'Nome do produto'}</h3><p>{values.description || 'A descrição digitada aparecerá aqui.'}</p><strong>{values.price ? formatCurrency(values.promoPrice || values.price) : 'Informe um preço'}</strong><span>Prévia visual, sem carrinho ou publicação.</span></div></Modal> : null}</Modal>;
}
