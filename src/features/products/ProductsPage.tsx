import { useMemo, useState } from 'react';
import { Archive, ChevronRight, Download, Edit3, Eye, ImageOff, Package, Plus, Search, Tag, Upload, X } from 'lucide-react';
import { Link } from 'react-router-dom';
import { Alert, Button, EmptyState, Loading, Modal, PageHeader, Select, StatCard } from '../../components/ui';
import { COMPOSITION_COST_SCALE, UNIT_COST_SCALE, formatDecimal } from '../../lib/decimal';
import { formatCurrency, formatDate, formatNumber } from '../../lib/format';
import { useSession } from '../../app/AuthProvider';
import { OrganizationContext, OrganizationPicker } from '../inventory/OrganizationContext';
import { ProductFileRegistrationError, registerExistingProductFile, useProductDetailQuery, useProductFileMutation, useProductMaterialsQuery, useProductsQuery, userFacingProductError } from './api';
import { canEditProducts, type ProductDto, type ProductEditSnapshot, type PricingMode, type ProductFileKind } from './types';
import { ProductForm } from './ProductForm';
import './products.css';

type ProductWithThumbnail = ProductDto & { thumbnail_url?: string };

type PriceFilter = 'all' | 'promo' | 'regular';

function formatCost(value: string | null | undefined, scale = COMPOSITION_COST_SCALE) {
  const text = formatDecimal(value, scale);
  return text === '—' ? text : `R$ ${text}`;
}

function csvCell(value: string | number | null | undefined) {
  const text = String(value ?? '');
  const safe = /^[=+\-@]/.test(text) ? `'${text}` : text;
  return `"${safe.replace(/"/g, '""')}"`;
}

function exportProducts(products: ProductWithThumbnail[]) {
  const rows = [
    ['Nome', 'Categoria principal', 'Categorias', 'Modo de preço', 'Preço normal', 'Preço promocional', 'MOQ', 'Custo da composição', 'Custo corrente dos materiais', 'SKU', 'Visível no catálogo', 'Destaque', 'Atualizado em'],
    ...products.map((product) => [
      product.name,
      product.category,
      product.categories.join(', '),
      pricingModeLabel(product.pricing_mode),
      formatCurrency(product.price),
      product.promo_price ? formatCurrency(product.promo_price) : '',
      product.minimum_quantity,
      formatCost(product.current_composition_cost),
      formatCost(product.current_material_cost),
      product.sku ?? '',
      product.is_catalog_visible ? 'Sim' : 'Não',
      product.is_featured ? 'Sim' : 'Não',
      formatDate(product.updated_at),
    ]),
  ];
  const content = `\uFEFF${rows.map((row) => row.map(csvCell).join(';')).join('\r\n')}`;
  const url = URL.createObjectURL(new Blob([content], { type: 'text/csv;charset=utf-8' }));
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = 'produtos.csv';
  anchor.click();
  URL.revokeObjectURL(url);
}

function pricingModeLabel(mode: PricingMode) {
  return mode === 'variation' ? 'Por variação' : mode === 'm2' ? 'Por m²' : 'Fixo por unidade';
}

function ProductFilesPanel({ organizationId, productId, canEdit }: { organizationId: string; productId: string; canEdit: boolean }) {
  const fileMutation = useProductFileMutation(organizationId);
  const [kind, setKind] = useState<ProductFileKind>('production');
  const [message, setMessage] = useState<string | null>(null);
  const [pending, setPending] = useState<{ path: string; mimeType: string; sizeBytes: number; name: string; kind: ProductFileKind } | null>(null);
  const handleFile = async (file: File | undefined) => {
    if (!file) return;
    if (file.size > 52428800) { setMessage('O arquivo ultrapassa o limite de 50 MiB.'); return; }
    const allowed = ['image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'application/zip'];
    if (!allowed.includes(file.type) || (kind === 'photo' && !file.type.startsWith('image/'))) { setMessage('Escolha um arquivo com MIME permitido para este tipo.'); return; }
    setMessage(null);
    try {
      await fileMutation.mutateAsync({ organizationId, productId, kind, file });
      setPending(null);
      setMessage('Arquivo enviado e registrado no produto.');
    } catch (error) {
      if (error instanceof ProductFileRegistrationError) setPending({ path: error.path, mimeType: file.type, sizeBytes: file.size, name: file.name, kind });
      setMessage(userFacingProductError(error, 'O upload não foi concluído.'));
    }
  };
  const retry = async () => {
    if (!pending) return;
    try {
      await registerExistingProductFile({ organizationId, productId, kind: pending.kind, path: pending.path, mimeType: pending.mimeType, sizeBytes: pending.sizeBytes, name: pending.name });
      setPending(null);
      setMessage('Arquivo pendente registrado.');
    } catch (error) { setMessage(userFacingProductError(error, 'Não foi possível registrar o objeto já enviado. Ele não será reenviado.')); }
  };
  return <section className="detail-section"><h4>Arquivos privados</h4>{canEdit ? <div className="file-attachment"><div className="form-grid"><label className="filter-field"><span>Tipo</span><Select value={kind} onChange={(event) => setKind(event.target.value as ProductFileKind)}><option value="photo">Foto</option><option value="digital">Arquivo digital</option><option value="production">Arquivo de produção</option></Select></label><label className="file-picker compact-file-picker"><Upload size={16} /><span>Selecionar arquivo (50 MiB)</span><input type="file" accept="image/jpeg,image/png,image/webp,application/pdf,application/zip" onChange={(event) => void handleFile(event.target.files?.[0])} /></label></div><p className="field-hint">Fotos aceitam JPG, PNG e WebP. Documentos aceitam PDF ou ZIP; nada é publicado.</p>{message ? <Alert kind={pending ? 'warning' : 'info'}>{message}{pending ? <Button type="button" variant="secondary" onClick={() => void retry()}>Tentar registrar sem reenviar</Button> : null}</Alert> : null}</div> : null}</section>;
}

function ProductDetails({ organizationId, canEdit, snapshot, onClose }: { organizationId: string; canEdit: boolean; snapshot: ProductEditSnapshot; onClose: () => void }) {
  const { product, version, versionHistory, files } = snapshot;
  return (
    <Modal open title="Detalhes do produto" onClose={onClose}>
      <div className="product-detail">
        <div className="detail-heading">
          <div><p className="eyebrow">Versão {version.product_version}</p><h3>{product.name}</h3><p>{product.category}{version.subcategory ? ` · ${version.subcategory}` : ''}</p></div>
          {files.find((file) => file.kind === 'photo')?.signed_url ? <img className="detail-photo" src={files.find((file) => file.kind === 'photo')?.signed_url} alt={`Foto de ${product.name}`} /> : <div className="detail-photo-empty"><ImageOff size={20} />Sem foto</div>}
        </div>
        <div className="detail-grid">
          <div><span>Preço normal</span><strong>{formatCurrency(version.price)}</strong></div>
          <div><span>Preço promocional</span><strong>{version.promo_price ? formatCurrency(version.promo_price) : '—'}</strong></div>
          <div><span>Custo congelado da versão</span><strong>{formatCost(version.composition_cost)}</strong></div>
          <div><span>Custo corrente dos materiais</span><strong>{formatCost(product.current_material_cost)}</strong></div>
          <div><span>Modo de preço</span><strong>{pricingModeLabel(version.pricing_mode)}</strong></div>
          <div><span>Consumo de estoque atual</span><strong>{product.inventory_mode === 'no_stock' ? 'Sem consumo de estoque' : 'Composição de insumos'}</strong></div>
        </div>
        {version.description ? <section className="detail-section"><h4>Descrição</h4><p className="detail-text">{version.description}</p></section> : null}
        <section className="detail-section"><h4>Receita da versão</h4>{version.composition_snapshot.length ? <div className="detail-lines">{version.composition_snapshot.map((component) => <div key={component.material_id}><span>{component.material_id.slice(0, 8)}… · {component.unit}</span><strong>{component.quantity} × {formatCost(component.unit_cost, UNIT_COST_SCALE)}</strong></div>)}</div> : <p className="muted-note">{product.inventory_mode === 'no_stock' ? 'Produto classificado sem consumo de estoque.' : 'Sem receita: cadastre insumos antes de criar pedidos ou orçamentos.'}</p>}</section>
        <section className="detail-section"><h4>Variações preservadas</h4>{snapshot.variants.length ? <div className="detail-lines">{snapshot.variants.map((variant) => <div key={variant.id}><span>{variant.name}{variant.active ? '' : ' · desativada'}</span><strong>{formatCurrency(variant.price)}</strong></div>)}</div> : <p className="muted-note">Nenhuma variação registrada.</p>}</section>
        <section className="detail-section"><h4>Histórico de versões</h4><div className="detail-lines">{versionHistory.map((item) => <div key={item.product_version}><span>Versão {item.product_version} · {formatDate(item.created_at)}{item.product_version === version.product_version ? ' · atual' : ''}</span><strong>{formatCost(item.composition_cost)}</strong></div>)}</div></section>
        <section className="detail-section"><h4>Arquivos privados registrados</h4>{files.length ? <div className="detail-files">{files.map((file) => <div key={file.id}><span>{file.name} · {file.kind}</span>{file.signed_url ? <a className="text-link" href={file.signed_url} target="_blank" rel="noreferrer">Abrir</a> : <span className="muted-note">URL temporária indisponível</span>}</div>)}</div> : <p className="muted-note">Nenhum arquivo registrado.</p>}</section>
        <ProductFilesPanel organizationId={organizationId} productId={product.id} canEdit={canEdit} />
      </div>
    </Modal>
  );
}

function ProductTable({ products, canEdit, onEdit, onDetails }: { products: ProductWithThumbnail[]; canEdit: boolean; onEdit: (product: ProductDto) => void; onDetails: (product: ProductDto) => void }) {
  return <div className="table-scroll"><table className="data-table products-table"><caption className="sr-only">Produtos cadastrados</caption><thead><tr><th>Produto</th><th>Categoria</th><th>Preço</th><th>Modo</th><th>Custo receita</th><th>Catálogo</th><th>Ações</th></tr></thead><tbody>{products.map((product) => <tr key={product.id}><th scope="row"><div className="product-cell">{product.thumbnail_url ? <img className="product-thumb" src={product.thumbnail_url} alt="" /> : <div className="product-thumb-empty" aria-hidden="true"><ImageOff size={16} /></div>}<span><strong>{product.name}</strong><small>{product.sku ? `SKU ${product.sku}` : 'Sem SKU'}</small></span></div></th><td>{product.category}<small className="table-subline">{product.categories.length > 1 ? `+${product.categories.length - 1} categorias` : 'categoria principal'}</small></td><td className="numeric"><strong>{formatCurrency(product.promo_price ?? product.price)}</strong>{product.promo_price ? <small className="table-subline">de {formatCurrency(product.price)}</small> : null}</td><td>{pricingModeLabel(product.pricing_mode)}</td><td className="numeric">{formatCost(product.current_composition_cost)}</td><td><span className={product.is_catalog_visible ? 'status-pill status-on' : 'status-pill'}>{product.is_catalog_visible ? 'Visível' : 'Inativo'}</span>{product.is_featured ? <small className="table-subline">Destaque</small> : null}</td><td><div className="table-actions"><Button variant="ghost" icon={<Eye size={15} />} onClick={() => onDetails(product)}>Detalhar</Button>{canEdit ? <Button variant="secondary" icon={<Edit3 size={15} />} onClick={() => onEdit(product)}>Editar</Button> : null}</div></td></tr>)}</tbody></table></div>;
}

export function ProductsPage() {
  const { organizationId } = useSession();
  return <OrganizationContext><ProductsWorkspace key={organizationId ?? 'none'} /></OrganizationContext>;
}

function ProductsWorkspace() {
  const { organizationId, organization, currentMembershipRole } = useSession();
  const productsQuery = useProductsQuery(organizationId);
  const materialsQuery = useProductMaterialsQuery(organizationId);
  const [search, setSearch] = useState('');
  const [category, setCategory] = useState('');
  const [mode, setMode] = useState('');
  const [priceFilter, setPriceFilter] = useState<PriceFilter>('all');
  const [formProduct, setFormProduct] = useState<ProductDto | null | undefined>(undefined);
  const [detailsProductId, setDetailsProductId] = useState<string | null>(null);
  const detailQuery = useProductDetailQuery(organizationId, detailsProductId);
  const canEdit = canEditProducts(currentMembershipRole);
  const products = (productsQuery.data ?? []) as ProductWithThumbnail[];
  const categories = useMemo(() => Array.from(new Set(products.map((product) => product.category).filter(Boolean))).sort((a, b) => a.localeCompare(b, 'pt-BR')), [products]);
  const normalizedSearch = search.trim().toLocaleLowerCase('pt-BR');
  const filteredProducts = useMemo(() => products.filter((product) => {
    const haystack = `${product.name} ${product.category} ${(product.categories ?? []).join(' ')} ${product.sku ?? ''}`.toLocaleLowerCase('pt-BR');
    return (!normalizedSearch || haystack.includes(normalizedSearch)) && (!category || product.category === category) && (!mode || product.pricing_mode === mode) && (priceFilter === 'all' || (priceFilter === 'promo' ? Boolean(product.promo_price) : !product.promo_price));
  }), [category, mode, normalizedSearch, priceFilter, products]);
  const visibleCount = products.filter((product) => product.is_catalog_visible).length;

  if (productsQuery.isLoading || materialsQuery.isLoading) return <Loading label="Consultando produtos e materiais da organização…" />;

  return <>
    <PageHeader eyebrow="Catálogo & Produção" title="Produtos" description={`Produtos, preços e receitas versionadas de ${organization?.name ?? 'sua organização'}, sem registros demonstrativos.`} action={canEdit ? <Button icon={<Plus size={17} />} onClick={() => setFormProduct(null)}>Novo produto</Button> : undefined} />
    <OrganizationPicker />
    <div className="stats-grid product-stats"><StatCard label="Produtos" value={String(products.length)} footnote="registros reais nesta organização" icon={<Package size={17} />} /><StatCard label="Visíveis no catálogo" value={String(visibleCount)} footnote="preferência persistida; vitrine ainda inativa" icon={<Eye size={17} />} /><StatCard label="Com receita" value={String(products.filter((product) => product.current_composition_cost !== '0').length)} footnote="custo congelado na última versão" icon={<Archive size={17} />} /></div>
    {productsQuery.isError ? <section className="panel query-error-panel"><Alert kind="error">{userFacingProductError(productsQuery.error, 'Não foi possível carregar os produtos.')}</Alert><Button variant="secondary" loading={productsQuery.isFetching} onClick={() => void productsQuery.refetch()}>Tentar novamente</Button></section> : <section className="panel inventory-panel products-panel">
      <div className="inventory-toolbar"><div><h2 className="panel-title">Lista de produtos</h2><p className="panel-caption">A busca e os filtros abaixo usam somente dados carregados do Supabase.</p></div><Button variant="secondary" icon={<Download size={16} />} disabled={!filteredProducts.length} onClick={() => exportProducts(filteredProducts)}>Exportar CSV</Button></div>
      <div className="filter-row product-filter-row"><label className="search-field"><Search size={17} aria-hidden="true" /><span className="sr-only">Buscar produto</span><input className="input" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Buscar por nome, categoria ou SKU" /></label><label className="filter-field"><span>Categoria</span><Select value={category} onChange={(event) => setCategory(event.target.value)}><option value="">Todas as categorias</option>{categories.map((item) => <option key={item} value={item}>{item}</option>)}</Select></label><label className="filter-field"><span>Modo de preço</span><Select value={mode} onChange={(event) => setMode(event.target.value)}><option value="">Todos</option><option value="unit">Fixo por unidade</option><option value="variation">Por variação</option><option value="m2">Por m²</option></Select></label><label className="filter-field"><span>Preço</span><Select value={priceFilter} onChange={(event) => setPriceFilter(event.target.value as PriceFilter)}><option value="all">Todos</option><option value="promo">Com promoção</option><option value="regular">Sem promoção</option></Select></label></div>
      {!products.length ? <EmptyState title="Nenhum produto cadastrado" description="O catálogo desta organização começa vazio. Cadastre o primeiro produto com preço, descrição e uma receita real de materiais quando aplicável." action={canEdit ? <Button onClick={() => setFormProduct(null)} icon={<Plus size={16} />}>Cadastrar primeiro produto</Button> : <Link className="text-link" to="/conta">Confira sua permissão na Conta</Link>} /> : null}
      {products.length > 0 && !filteredProducts.length ? <EmptyState title="Nenhum resultado para estes filtros" description="Ajuste a busca ou remova os filtros para consultar os produtos reais carregados." /> : null}
      {filteredProducts.length ? <ProductTable products={filteredProducts} canEdit={canEdit} onEdit={setFormProduct} onDetails={(product) => setDetailsProductId(product.id)} /> : null}
      <div className="product-stock-note"><Tag size={16} aria-hidden="true" /><span>Saldo de produto acabado não é exibido nesta etapa: não existe campo SQL de estoque acabado no contrato. O estoque de insumos continua no <Link className="text-link" to="/estoque">Inventário</Link>.</span></div>
    </section>}
    {formProduct !== undefined ? <ProductForm organizationId={organizationId!} product={formProduct} materials={materialsQuery.data ?? []} onClose={() => setFormProduct(undefined)} onSaved={() => { setFormProduct(undefined); void productsQuery.refetch(); }} /> : null}
    {detailsProductId ? <>{detailQuery.isLoading ? <Modal open title="Detalhes do produto" onClose={() => setDetailsProductId(null)}><Loading label="Carregando snapshot e histórico…" /></Modal> : detailQuery.error ? <Modal open title="Detalhes do produto" onClose={() => setDetailsProductId(null)}><Alert kind="error">{userFacingProductError(detailQuery.error, 'Não foi possível carregar os detalhes.')}</Alert></Modal> : detailQuery.data ? <ProductDetails organizationId={organizationId!} canEdit={canEdit} snapshot={detailQuery.data} onClose={() => setDetailsProductId(null)} /> : null}</> : null}
  </>;
}
