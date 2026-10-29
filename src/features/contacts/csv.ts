import type { AddressKey, ClientContactData, ContactData, ContactDto, ContactEntity, SupplierContactData } from './types';
import { ADDRESS_KEYS } from './types';

export class CsvParseError extends Error {
  readonly row: number | null;

  constructor(message: string, row: number | null = null) {
    super(row ? `Linha ${row}: ${message}` : message);
    this.name = 'CsvParseError';
    this.row = row;
  }
}

export interface ParsedContactsCsv {
  delimiter: ';' | ',';
  headers: string[];
  rows: ContactData[];
}

type CanonicalColumn = 'name' | 'email' | 'phone' | 'notes' | 'person_type' | 'tax_id' | 'birth_date' | 'website' | AddressKey;

const aliases: Record<string, CanonicalColumn> = {
  name: 'name', nome: 'name',
  email: 'email', 'e mail': 'email', 'e-mail': 'email',
  phone: 'phone', telefone: 'phone', celular: 'phone', contato: 'phone',
  notes: 'notes', notas: 'notes', observacoes: 'notes', observacao: 'notes',
  person_type: 'person_type', 'person type': 'person_type', tipo_pessoa: 'person_type', 'tipo pessoa': 'person_type', 'tipo de pessoa': 'person_type', tipo: 'person_type',
  tax_id: 'tax_id', 'tax id': 'tax_id', 'cpf cnpj': 'tax_id', 'cpf/cnpj': 'tax_id', documento: 'tax_id',
  birth_date: 'birth_date', 'birth date': 'birth_date', data_nascimento: 'birth_date', 'data nascimento': 'birth_date', nascimento: 'birth_date',
  website: 'website', site: 'website', url: 'website',
  postal_code: 'postal_code', 'postal code': 'postal_code', cep: 'postal_code',
  street: 'street', rua: 'street', logradouro: 'street',
  number: 'number', numero: 'number', 'nº': 'number',
  district: 'district', bairro: 'district',
  complement: 'complement', complemento: 'complement',
  city: 'city', cidade: 'city',
  state: 'state', uf: 'state', estado: 'state',
};

const clientAllowed = new Set<CanonicalColumn>(['name', 'email', 'phone', 'notes', 'person_type', 'tax_id', 'birth_date', ...ADDRESS_KEYS]);
const supplierAllowed = new Set<CanonicalColumn>(['name', 'email', 'phone', 'notes', 'person_type', 'tax_id', 'website', ...ADDRESS_KEYS]);

function stripAccents(value: string): string {
  return value.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
}

export function normalizeCsvHeader(value: string): string {
  return stripAccents(value.replace(/^\uFEFF/, '').trim().toLocaleLowerCase('pt-BR'))
    .replace(/[\/_-]+/g, ' ')
    .replace(/\s+/g, ' ');
}

export function normalizeTaxId(value: string): string {
  return value.trim().replace(/[.\/-\s]/g, '').toUpperCase();
}

function isBlankRow(row: string[]): boolean {
  return row.every((value) => value.trim() === '');
}

function detectDelimiter(text: string): ';' | ',' {
  let semicolons = 0;
  let commas = 0;
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (character === '"') {
      if (quoted && text[index + 1] === '"') index += 1;
      else quoted = !quoted;
    } else if (!quoted && character === ';') semicolons += 1;
    else if (!quoted && character === ',') commas += 1;
    else if (!quoted && (character === '\n' || character === '\r')) break;
  }
  return semicolons >= commas && semicolons > 0 ? ';' : ',';
}

interface RawCsvRow {
  values: string[];
  rowNumber: number;
}

function parseRawCsv(input: string, delimiter: ';' | ','): RawCsvRow[] {
  const rows: RawCsvRow[] = [];
  let values: string[] = [];
  let field = '';
  let inQuotes = false;
  let closedQuote = false;
  let line = 1;
  let rowNumber = 1;

  const finishRow = () => {
    values.push(field);
    field = '';
    closedQuote = false;
    if (!isBlankRow(values)) rows.push({ values, rowNumber });
    values = [];
    rowNumber = line + 1;
  };

  for (let index = 0; index < input.length; index += 1) {
    const character = input[index];
    if (inQuotes) {
      if (character === '"') {
        if (input[index + 1] === '"') {
          field += '"';
          index += 1;
        } else {
          inQuotes = false;
          closedQuote = true;
        }
      } else if (character === '\r') {
        if (input[index + 1] === '\n') index += 1;
        field += '\n';
        line += 1;
      } else if (character === '\n') {
        field += '\n';
        line += 1;
      } else {
        field += character;
      }
      continue;
    }

    if (closedQuote) {
      if (character === delimiter) {
        values.push(field);
        field = '';
        closedQuote = false;
      } else if (character === '\r' || character === '\n') {
        if (character === '\r' && input[index + 1] === '\n') index += 1;
        line += 1;
        finishRow();
      } else if (character !== ' ' && character !== '\t') {
        throw new CsvParseError('há conteúdo depois do fechamento de aspas.', line);
      }
      continue;
    }

    if (character === '"' && field === '') {
      inQuotes = true;
    } else if (character === '"') {
      throw new CsvParseError('aspas devem envolver o campo desde o primeiro caractere.', line);
    } else if (character === delimiter) {
      values.push(field);
      field = '';
    } else if (character === '\r' || character === '\n') {
      if (character === '\r' && input[index + 1] === '\n') index += 1;
      line += 1;
      finishRow();
    } else {
      field += character;
    }
  }

  if (inQuotes) throw new CsvParseError('aspas não fechadas.', line);
  if (field !== '' || values.length) finishRow();
  return rows;
}

function nullText(value: string | undefined): string | null {
  const trimmed = value?.trim() ?? '';
  return trimmed ? trimmed : null;
}

function phoneText(value: string | undefined): string | null {
  const text = nullText(value);
  return text?.replace(/^'(?=[=+\-@])/, '') ?? null;
}

function buildAddress(values: Record<string, string>): ClientContactData['address'] {
  const address = Object.fromEntries(ADDRESS_KEYS.map((key) => [key, nullText(values[key])])) as unknown as ClientContactData['address'];
  return ADDRESS_KEYS.some((key) => address?.[key] !== null) ? address : null;
}

export function contactDataFromCsvRow(entity: ContactEntity, values: Record<string, string>): ContactData {
  const common = {
    name: values.name?.trim() ?? '',
    email: nullText(values.email)?.toLocaleLowerCase('pt-BR') ?? null,
    phone: phoneText(values.phone),
    notes: nullText(values.notes),
    person_type: (nullText(values.person_type)?.toLocaleLowerCase('pt-BR') || 'individual') as ClientContactData['person_type'],
    tax_id: values.tax_id ? normalizeTaxId(values.tax_id) || null : null,
    address: buildAddress(values),
  };
  if (entity === 'client') {
    return { ...common, birth_date: nullText(values.birth_date) } satisfies ClientContactData;
  }
  return { ...common, website: nullText(values.website) } satisfies SupplierContactData;
}

export function parseContactsCsv(input: string, entity: ContactEntity): ParsedContactsCsv {
  const text = input.replace(/^\uFEFF/, '');
  if (!text.trim()) throw new CsvParseError('o arquivo CSV está vazio.');
  const delimiter = detectDelimiter(text);
  const records = parseRawCsv(text, delimiter);
  if (!records.length) throw new CsvParseError('o arquivo CSV não possui cabeçalho.');

  const allowed = entity === 'client' ? clientAllowed : supplierAllowed;
  const canonicalHeaders = records[0].values.map((header) => {
    const key = aliases[normalizeCsvHeader(header)];
    if (!key || !allowed.has(key)) throw new CsvParseError(`cabeçalho desconhecido: “${header || '(vazio)'}”.`, records[0].rowNumber);
    return key;
  });
  if (new Set(canonicalHeaders).size !== canonicalHeaders.length) throw new CsvParseError('há cabeçalhos duplicados.', records[0].rowNumber);
  if (!canonicalHeaders.includes('name')) throw new CsvParseError('o cabeçalho Nome/name é obrigatório.', records[0].rowNumber);

  const rows: ContactData[] = [];
  for (const record of records.slice(1)) {
    if (record.values.length !== canonicalHeaders.length) {
      throw new CsvParseError(`esperava ${canonicalHeaders.length} campos e recebeu ${record.values.length}.`, record.rowNumber);
    }
    const values = canonicalHeaders.reduce<Record<string, string>>((result, header, index) => {
      result[header] = record.values[index] ?? '';
      return result;
    }, {});
    rows.push(contactDataFromCsvRow(entity, values));
    if (rows.length > 500) throw new CsvParseError('a importação aceita no máximo 500 linhas de dados.', record.rowNumber);
  }
  return { delimiter, headers: records[0].values, rows };
}

export const exportHeaders: Record<ContactEntity, string[]> = {
  client: ['Nome', 'E-mail', 'Telefone', 'Tipo de pessoa', 'CPF/CNPJ', 'Nascimento', 'CEP', 'Rua', 'Número', 'Bairro', 'Complemento', 'Cidade', 'UF', 'Observações'],
  supplier: ['Nome', 'E-mail', 'Telefone', 'Tipo de pessoa', 'CPF/CNPJ', 'Site', 'CEP', 'Rua', 'Número', 'Bairro', 'Complemento', 'Cidade', 'UF', 'Observações'],
};

function formulaSafe(value: string): string {
  return /^[=+\-@]/.test(value) ? `'${value}` : value;
}

export function escapeCsvCell(value: string | null | undefined): string {
  const safe = formulaSafe(String(value ?? ''));
  return `"${safe.replace(/"/g, '""')}"`;
}

function exportRow(entity: ContactEntity, contact: ContactDto): string[] {
  const address = contact.address;
  const common = [contact.name, contact.email ?? '', contact.phone ?? '', contact.person_type, contact.tax_id ?? '', address?.postal_code ?? '', address?.street ?? '', address?.number ?? '', address?.district ?? '', address?.complement ?? '', address?.city ?? '', address?.state ?? '', contact.notes ?? ''];
  return entity === 'client'
    ? [contact.name, contact.email ?? '', contact.phone ?? '', contact.person_type, contact.tax_id ?? '', 'birth_date' in contact ? contact.birth_date ?? '' : '', ...common.slice(5)]
    : [contact.name, contact.email ?? '', contact.phone ?? '', contact.person_type, contact.tax_id ?? '', 'website' in contact ? contact.website ?? '' : '', ...common.slice(5)];
}

export function serializeContactsCsv(entity: ContactEntity, contacts: readonly ContactDto[]): string {
  const lines = [exportHeaders[entity], ...contacts.map((contact) => exportRow(entity, contact))];
  return `\uFEFF${lines.map((row) => row.map(escapeCsvCell).join(';')).join('\r\n')}`;
}

export function downloadContactsCsv(entity: ContactEntity, contacts: readonly ContactDto[]): void {
  const content = serializeContactsCsv(entity, contacts);
  const url = URL.createObjectURL(new Blob([content], { type: 'text/csv;charset=utf-8' }));
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = entity === 'client' ? 'clientes.csv' : 'fornecedores.csv';
  anchor.click();
  URL.revokeObjectURL(url);
}
