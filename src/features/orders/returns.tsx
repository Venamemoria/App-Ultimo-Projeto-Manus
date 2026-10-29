import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { CheckCircle2, History, RotateCcw, ShieldCheck } from 'lucide-react';
import { Alert, Button, Field, Input, Loading, Modal, Textarea } from '../../components/ui';
import type { MembershipRole } from '../../lib/types';
import { Decimal } from '../../lib/decimal';
import { formatDate } from '../../lib/format';
import { decimalAtScale, isUuid, newIdempotencyKey } from './utils';
import type { OrderConsumptionDto, OrderDto, OrderItemDto } from './types';
import {
  decimalQuantity,
  type OrderReturnReadDto,
  useOrderReturnsQuery,
  useRecordOrderReturnMutation,
  userFacingOrderReturnError,
} from './returns-api';

interface OrderReturnsSectionProps {
  organizationId: string | null;
  order: OrderDto;
  items: OrderItemDto[];
  consumptions: OrderConsumptionDto[];
  currentMembershipRole: MembershipRole | null;
}

export interface OrderReturnMaterialSummary {
  materialId: string;
  materialName: string;
  unit: string;
  originalQuantity: Decimal;
  returnedQuantityTotal: Decimal;
  remainingQuantity: Decimal;
  currentStockQuantity: string | null;
  history: OrderReturnReadDto[];
}

interface MutableSummary extends OrderReturnMaterialSummary {
  hasHistoryOriginal: boolean;
}

function canRecordPhysicalReturn(role: MembershipRole | null): boolean {
  return role === 'owner' || role === 'admin';
}

function recipeMaterialLabels(items: OrderItemDto[]): Map<string, { name: string; unit: string }> {
  const result = new Map<string, { name: string; unit: string }>();
  for (const item of items) {
    for (const recipe of item.recipe_snapshot) {
      if (!result.has(recipe.material_id)) result.set(recipe.material_id, { name: recipe.material_name, unit: recipe.unit });
    }
  }
  return result;
}

function fallbackMaterialName(materialId: string): string {
  return `Material ${materialId.slice(0, 8)}…`;
}

export function aggregateOrderReturnMaterials(
  consumptions: OrderConsumptionDto[],
  historyRows: OrderReturnReadDto[],
  items: OrderItemDto[],
): OrderReturnMaterialSummary[] {
  const recipeLabels = recipeMaterialLabels(items);
  const byMaterial = new Map<string, MutableSummary>();

  for (const consumption of consumptions) {
    const recipe = recipeLabels.get(consumption.material_id);
    const existing = byMaterial.get(consumption.material_id);
    const originalQuantity = decimalQuantity(consumption.quantity);
    if (existing) {
      existing.originalQuantity = existing.originalQuantity.plus(originalQuantity);
      if (!existing.unit) existing.unit = consumption.unit;
      continue;
    }
    byMaterial.set(consumption.material_id, {
      materialId: consumption.material_id,
      materialName: recipe?.name ?? fallbackMaterialName(consumption.material_id),
      unit: consumption.unit || recipe?.unit || 'un',
      originalQuantity,
      returnedQuantityTotal: new Decimal(0),
      remainingQuantity: originalQuantity,
      currentStockQuantity: null,
      history: [],
      hasHistoryOriginal: false,
    });
  }

  for (const row of historyRows) {
    const recipe = recipeLabels.get(row.material_id);
    let summary = byMaterial.get(row.material_id);
    if (!summary) {
      const originalQuantity = decimalQuantity(row.original_consumed_quantity);
      summary = {
        materialId: row.material_id,
        materialName: row.material_name || recipe?.name || fallbackMaterialName(row.material_id),
        unit: row.unit || recipe?.unit || 'un',
        originalQuantity,
        returnedQuantityTotal: new Decimal(0),
        remainingQuantity: originalQuantity,
        currentStockQuantity: null,
        history: [],
        hasHistoryOriginal: true,
      };
      byMaterial.set(row.material_id, summary);
    }
    if (!summary.hasHistoryOriginal) {
      summary.originalQuantity = decimalQuantity(row.original_consumed_quantity);
      summary.hasHistoryOriginal = true;
    }
    summary.materialName = row.material_name || summary.materialName;
    summary.unit = row.unit || summary.unit;
    summary.returnedQuantityTotal = summary.returnedQuantityTotal.plus(decimalQuantity(row.returned_quantity));
    summary.currentStockQuantity = row.current_stock_quantity;
    summary.history.push(row);
  }

  return Array.from(byMaterial.values())
    .map((summary) => ({
      materialId: summary.materialId,
      materialName: summary.materialName,
      unit: summary.unit,
      originalQuantity: summary.originalQuantity,
      returnedQuantityTotal: summary.returnedQuantityTotal,
      remainingQuantity: summary.originalQuantity.minus(summary.returnedQuantityTotal),
      currentStockQuantity: summary.currentStockQuantity,
      history: summary.history.slice().sort((left, right) => {
        const dateOrder = left.line_created_at.localeCompare(right.line_created_at);
        return dateOrder || left.return_line_id.localeCompare(right.return_line_id);
      }),
    }))
    .sort((left, right) => left.materialId.localeCompare(right.materialId));
}

function quantityEight(value: Decimal | string | null | undefined): string {
  if (value === null || value === undefined || value === '') return '—';
  try {
    return (value instanceof Decimal ? value : decimalQuantity(value)).toFixed(8);
  } catch {
    return '—';
  }
}

export function OrderReturnsSection({ organizationId, order, items, consumptions, currentMembershipRole }: OrderReturnsSectionProps) {
  const eligible = order.status === 'Cancelado' && Boolean(order.consumed_at) && consumptions.length > 0;
  const historyQuery = useOrderReturnsQuery(organizationId, order.id, eligible);
  const mutation = useRecordOrderReturnMutation(organizationId, order.id);
  const canRecord = canRecordPhysicalReturn(currentMembershipRole);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [quantities, setQuantities] = useState<Record<string, string>>({});
  const [lineErrors, setLineErrors] = useState<Record<string, string>>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const intentRef = useRef<{ context: string; fingerprint: string; key: string } | null>(null);

  const summaries = useMemo(
    () => historyQuery.data ? aggregateOrderReturnMaterials(consumptions, historyQuery.data, items) : [],
    [consumptions, historyQuery.data, items],
  );

  useEffect(() => {
    setQuantities((current) => {
      const next = { ...current };
      for (const summary of summaries) {
        if (!(summary.materialId in next)) next[summary.materialId] = '';
      }
      return next;
    });
  }, [summaries]);

  useEffect(() => () => {
    intentRef.current = null;
  }, [organizationId, order.id]);

  if (!eligible) return null;

  const selectedCount = summaries.filter((summary) => Boolean(quantities[summary.materialId]?.trim())).length;
  const historyReady = Boolean(historyQuery.data && !historyQuery.error);

  const openForm = () => {
    setFormError(null);
    setLineErrors({});
    setOpen(true);
  };

  const closeForm = () => {
    if (mutation.isPending) return;
    setOpen(false);
  };

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!organizationId || !isUuid(order.id)) return;

    const trimmedReason = reason.trim();
    if (!trimmedReason || trimmedReason.length > 2000) {
      setFormError('Informe um motivo obrigatório com até 2000 caracteres.');
      return;
    }

    const nextLineErrors: Record<string, string> = {};
    const selected: Array<{ material_id: string; quantity: string }> = [];
    for (const summary of summaries) {
      const rawQuantity = quantities[summary.materialId]?.trim() ?? '';
      if (!rawQuantity) continue;
      try {
        const quantity = decimalAtScale(rawQuantity, 8, true, `Quantidade de ${summary.materialName}`);
        if (new Decimal(quantity).gt(summary.remainingQuantity)) {
          nextLineErrors[summary.materialId] = `Informe no máximo ${quantityEight(summary.remainingQuantity)} ${summary.unit}.`;
          continue;
        }
        selected.push({ material_id: summary.materialId, quantity });
      } catch (error) {
        nextLineErrors[summary.materialId] = error instanceof Error ? error.message : 'Quantidade inválida.';
      }
    }

    setLineErrors(nextLineErrors);
    if (Object.keys(nextLineErrors).length) {
      setFormError('Revise as quantidades físicas informadas antes de confirmar.');
      return;
    }
    if (!selected.length) {
      setFormError('Selecione ao menos um material e informe a quantidade física conferida.');
      return;
    }

    const fingerprint = JSON.stringify({ orderId: order.id, reason: trimmedReason, returns: selected });
    const context = `${organizationId}:${order.id}`;
    const currentIntent = intentRef.current;
    const key = currentIntent?.context === context && currentIntent.fingerprint === fingerprint
      ? currentIntent.key
      : newIdempotencyKey();
    intentRef.current = { context, fingerprint, key };
    setFormError(null);
    setSuccess(null);

    try {
      await mutation.mutateAsync({
        organizationId,
        orderId: order.id,
        reason: trimmedReason,
        returns: selected,
        idempotencyKey: key,
      });
      intentRef.current = null;
      setReason('');
      setQuantities(Object.fromEntries(summaries.map((summary) => [summary.materialId, ''])));
      setLineErrors({});
      setOpen(false);
      setSuccess('Devolução física confirmada pelo servidor. O histórico e o estoque serão consultados novamente.');
    } catch (error) {
      setFormError(userFacingOrderReturnError(error, 'Não foi possível confirmar a devolução física. A tentativa permanece identificada; repita sem mudar os dados para verificar o resultado.'));
    }
  };

  return (
    <section className="panel order-returns-panel">
      <div className="order-detail-section-heading">
        <div>
          <h2>Devolução física de insumos</h2>
          <p>Histórico por material devolvido, com leitura disponível para todos os membros desta organização.</p>
        </div>
        {canRecord ? (
          <Button
            variant="secondary"
            icon={<RotateCcw size={15} />}
            onClick={openForm}
            disabled={!historyReady || !summaries.length}
          >
            Registrar devolução
          </Button>
        ) : <span className="truth-badge"><History size={15} /> somente leitura</span>}
      </div>
      {success ? <Alert kind="success"><CheckCircle2 size={16} /> {success}</Alert> : null}
      {historyQuery.isPending ? <Loading label="Consultando o histórico de devoluções reais…" /> : null}
      {historyQuery.error ? (
        <div className="order-returns-error">
          <Alert kind="error">{userFacingOrderReturnError(historyQuery.error, 'Não foi possível carregar o histórico de devoluções físicas.')}</Alert>
          <Button variant="secondary" loading={historyQuery.isFetching} onClick={() => void historyQuery.refetch()}>Tentar novamente</Button>
        </div>
      ) : null}
      {historyReady && summaries.length ? (
        <div className="order-return-materials">
          {summaries.map((summary) => (
            <article className="order-return-material" key={summary.materialId}>
              <div className="order-return-material-heading">
                <div>
                  <h3>{summary.materialName}</h3>
                  <p>Material {summary.materialId.slice(0, 8)}… · unidade {summary.unit}</p>
                </div>
                <ShieldCheck size={18} aria-label="Linha de estoque auditável" />
              </div>
              <div className="detail-grid order-return-metrics">
                <div><span>Consumo original</span><strong>{quantityEight(summary.originalQuantity)} {summary.unit}</strong></div>
                <div><span>Total devolvido neste material</span><strong>{quantityEight(summary.returnedQuantityTotal)} {summary.unit}</strong></div>
                <div><span>Restante deste material</span><strong>{quantityEight(summary.remainingQuantity)} {summary.unit}</strong></div>
                {summary.currentStockQuantity !== null ? <div><span>Saldo atual</span><strong>{quantityEight(summary.currentStockQuantity)} {summary.unit}</strong></div> : null}
              </div>
              {summary.history.length ? (
                <div className="order-return-history">
                  <h4>Histórico por linha</h4>
                  {summary.history.map((row) => (
                    <div className="order-return-history-line" key={row.return_line_id}>
                      <div className="order-return-history-line-heading">
                        <strong>{formatDate(row.line_created_at)}</strong>
                        <span>{row.unit}</span>
                      </div>
                      <div className="order-return-history-values">
                        <div><span>Linha devolvida</span><strong>{quantityEight(row.returned_quantity)} {row.unit}</strong></div>
                        <div><span>Total devolvido</span><strong>{quantityEight(summary.returnedQuantityTotal)} {summary.unit}</strong></div>
                        <div><span>Restante</span><strong>{quantityEight(summary.remainingQuantity)} {summary.unit}</strong></div>
                        <div><span>Saldo após retorno</span><strong>{quantityEight(row.stock_after)} {row.unit}</strong></div>
                        <div><span>Saldo atual</span><strong>{quantityEight(row.current_stock_quantity)} {row.unit}</strong></div>
                      </div>
                      <small>{row.reason}</small>
                    </div>
                  ))}
                </div>
              ) : <p className="detail-footnote">Nenhuma devolução física registrada para este material; o restante usa o consumo original real.</p>}
            </article>
          ))}
        </div>
      ) : null}
      {historyReady && !summaries.length ? <p className="detail-text order-returns-empty">Nenhum consumo físico deste pedido está disponível para devolução.</p> : null}

      {canRecord ? (
        <Modal title="Registrar devolução física" open={open} onClose={closeForm}>
          <form className="return-form" onSubmit={submit}>
            <Alert kind="warning">Informe somente a quantidade fisicamente conferida. Esta ação aumenta o estoque real, não altera status ou consumo do pedido e não cria reembolso financeiro.</Alert>
            {formError ? <Alert kind="error">{formError}</Alert> : null}
            <Field label="Motivo obrigatório" hint="O motivo fica no histórico imutável da operação.">
              <Textarea value={reason} maxLength={2000} onChange={(event) => { setReason(event.target.value); setFormError(null); }} placeholder="Ex.: conferência física do material remanescente" />
            </Field>
            <div className="return-form-lines">
              {summaries.map((summary) => (
                <Field
                  key={summary.materialId}
                  label={`${summary.materialName} · ${summary.unit}`}
                  hint={`Consumo original ${quantityEight(summary.originalQuantity)} ${summary.unit}; restante disponível ${quantityEight(summary.remainingQuantity)} ${summary.unit}. Deixe vazio se não houver devolução.`}
                  error={lineErrors[summary.materialId]}
                >
                  <Input
                    inputMode="decimal"
                    placeholder="0,00000000"
                    value={quantities[summary.materialId] ?? ''}
                    disabled={summary.remainingQuantity.lte(0)}
                    onChange={(event) => {
                      setQuantities((current) => ({ ...current, [summary.materialId]: event.target.value }));
                      setLineErrors((current) => { const next = { ...current }; delete next[summary.materialId]; return next; });
                      setFormError(null);
                    }}
                  />
                </Field>
              ))}
            </div>
            <div className="form-actions">
              <Button type="button" variant="ghost" onClick={closeForm}>Cancelar</Button>
              <Button type="submit" loading={mutation.isPending} disabled={!historyReady || !reason.trim() || selectedCount < 1}>Confirmar devolução física</Button>
            </div>
          </form>
        </Modal>
      ) : null}
    </section>
  );
}
