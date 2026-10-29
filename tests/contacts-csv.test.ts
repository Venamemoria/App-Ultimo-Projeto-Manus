import { describe, expect, it } from 'vitest';
import { CsvParseError, normalizeTaxId, parseContactsCsv, serializeContactsCsv } from '../src/features/contacts/csv';
import type { ClientDto } from '../src/features/contacts/types';

describe('cadastros CSV', () => {
  it('preserva zeros e letras do CPF/CNPJ sem usar filtro numérico', () => {
    expect(normalizeTaxId('  001.234.567-89 ')).toBe('00123456789');
    expect(normalizeTaxId('ab12.cd34/ef56-78')).toBe('AB12CD34EF5678');
  });

  it('lê BOM, delimitador ponto e vírgula, aspas escapadas e newline em campo', () => {
    const csv = '\uFEFFNome;Telefone;Observações;Cidade;UF\r\n"Papelaria; Central";"+55 11 90000-0000";"linha 1\r\nlinha 2";São Paulo;sp\r\n';
    const parsed = parseContactsCsv(csv, 'supplier');
    expect(parsed.delimiter).toBe(';');
    expect(parsed.rows).toHaveLength(1);
    expect(parsed.rows[0]).toMatchObject({
      name: 'Papelaria; Central',
      phone: '+55 11 90000-0000',
      notes: 'linha 1\nlinha 2',
      address: { city: 'São Paulo', state: 'sp' },
    });
  });

  it('lê CSV separado por vírgula e rejeita cabeçalho desconhecido', () => {
    const parsed = parseContactsCsv('name,email\nAna,ana@example.com\n', 'client');
    expect(parsed.rows[0]).toMatchObject({ name: 'Ana', email: 'ana@example.com', birth_date: null });
    expect(() => parseContactsCsv('name,segredo\nAna,valor\n', 'client')).toThrow(/cabeçalho desconhecido/i);
  });

  it('rejeita aspas malformadas e lotes maiores que 500 linhas', () => {
    expect(() => parseContactsCsv('name;email\n"Ana;ana@example.com\n', 'client')).toThrow(CsvParseError);
    const rows = Array.from({ length: 501 }, (_, index) => `Nome ${index};ana${index}@example.com`).join('\n');
    expect(() => parseContactsCsv(`name;email\n${rows}`, 'client')).toThrow(/no máximo 500/i);
  });

  it('exporta as linhas filtradas com escape de fórmula sem perder a representação do telefone', () => {
    const contact: ClientDto = {
      id: '00000000-0000-0000-0000-000000000001',
      organization_id: '00000000-0000-0000-0000-000000000002',
      name: '=Nome perigoso',
      email: 'ana@example.com',
      phone: '+55 11 90000-0000',
      notes: 'nota; com "aspas"',
      person_type: 'individual',
      tax_id: '00123456789',
      birth_date: null,
      address: { postal_code: null, street: null, number: null, district: null, complement: null, city: 'São Paulo', state: 'SP' },
      archived_at: null,
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
    };
    const csv = serializeContactsCsv('client', [contact]);
    expect(csv.startsWith('\uFEFF')).toBe(true);
    expect(csv).toContain('"\'=Nome perigoso"');
    expect(csv).toContain('"\'+55 11 90000-0000"');
    expect(csv).toContain('nota; com ""aspas""');
    const roundTrip = parseContactsCsv(csv, 'client');
    expect(roundTrip.rows[0].phone).toBe('+55 11 90000-0000');
  });
});
