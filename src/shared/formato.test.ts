import { describe, expect, it } from 'vitest';
import { formatearCantidad, formatearCosto, formatearDinero, formatearPorcentaje } from './formato';

// Intl puede usar espacios especiales (U+00A0, U+202F) entre símbolo y número
// según la versión de ICU. Los normalizamos para que la prueba sea estable.
const normalizar = (texto: string) => texto.replace(/[  ]/g, ' ');

describe('formatearDinero', () => {
  it('muestra dos decimales con coma decimal', () => {
    expect(normalizar(formatearDinero('7.5'))).toMatch(/7,50/);
  });

  it('acepta el texto que devuelve un numeric de Postgres', () => {
    expect(normalizar(formatearDinero('1234.56'))).toMatch(/1\.234,56/);
  });

  it('rechaza texto que no es un número', () => {
    expect(() => formatearDinero('7,50')).toThrow();
    expect(() => formatearDinero('abc')).toThrow();
    expect(() => formatearDinero('')).toThrow();
  });

  it('rechaza valores no finitos', () => {
    expect(() => formatearDinero(Number.NaN)).toThrow();
    expect(() => formatearDinero(Number.POSITIVE_INFINITY)).toThrow();
  });
});

describe('formatearCosto', () => {
  it('muestra los 6 decimales del costo promedio del kardex del aceite', () => {
    expect(normalizar(formatearCosto('2.455294'))).toMatch(/2,455294/);
  });

  it('no rellena con ceros más allá de dos decimales', () => {
    expect(normalizar(formatearCosto('2.000000'))).toMatch(/2,00$/);
  });
});

describe('formatearCantidad', () => {
  it('muestra hasta 3 decimales para productos por peso', () => {
    expect(formatearCantidad('1.250')).toBe('1,25');
    expect(formatearCantidad('0.907')).toBe('0,907');
  });

  it('muestra enteros sin decimales', () => {
    expect(formatearCantidad('24')).toBe('24');
  });
});

describe('formatearPorcentaje', () => {
  it('distingue margen sobre venta y recargo sobre costo del ejemplo de la Fase 3', () => {
    expect(normalizar(formatearPorcentaje('0.181569'))).toMatch(/18,2/);
    expect(normalizar(formatearPorcentaje('0.221850'))).toMatch(/22,2/);
  });
});
