import { describe, expect, it } from 'vitest';
import { generarCsv, type Columna } from './csv';
import { rangoMes } from './fechas';

interface Fila {
  cliente: string;
  total: string;
}
const columnas: Columna<Fila>[] = [
  { titulo: 'Cliente', valor: (f) => f.cliente },
  { titulo: 'Total', valor: (f) => f.total, decimal: true },
];

describe('generarCsv', () => {
  it('usa BOM, punto y coma, coma decimal y CRLF', () => {
    expect(generarCsv([{ cliente: 'María', total: '10.35' }], columnas)).toBe('﻿Cliente;Total\r\nMaría;10,35\r\n');
  });

  it('pone comillas cuando hace falta y duplica las internas', () => {
    const csv = generarCsv([{ cliente: 'Tienda "La 5"; centro', total: '1.00' }], columnas);
    expect(csv).toContain('"Tienda ""La 5""; centro";1,00');
  });

  it('neutraliza textos que Excel ejecutaría como fórmula', () => {
    const csv = generarCsv([{ cliente: '=HYPERLINK("http://x")', total: '-2.50' }], columnas);
    expect(csv).toContain(`"'=HYPERLINK(""http://x"")"`);
    // Un número negativo sí se deja como número.
    expect(csv).toContain(';-2,50');
  });

  it('deja vacío lo que no tiene valor', () => {
    expect(generarCsv([{ cliente: '', total: '0.00' }], columnas)).toContain('\r\n;0,00\r\n');
  });
});

describe('rangoMes', () => {
  it('da el primer y el último día del mes', () => {
    expect(rangoMes(new Date(2026, 9, 27))).toEqual({ desde: '2026-10-01', hasta: '2026-10-31' });
  });

  it('el mes anterior cruza de año y respeta febrero', () => {
    expect(rangoMes(new Date(2026, 0, 15), -1)).toEqual({ desde: '2025-12-01', hasta: '2025-12-31' });
    expect(rangoMes(new Date(2028, 2, 10), -1)).toEqual({ desde: '2028-02-01', hasta: '2028-02-29' });
  });
});
