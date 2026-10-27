import { describe, expect, it } from 'vitest';
import { leerDecimal, negar, paraEditar, restarDinero, sumarDinero } from './decimal';

describe('leerDecimal', () => {
  it('acepta coma o punto y devuelve texto con punto', () => {
    expect(leerDecimal('1,25', { decimales: 3 })).toEqual({ ok: true, valor: '1.25' });
    expect(leerDecimal('1.25', { decimales: 3 })).toEqual({ ok: true, valor: '1.25' });
  });

  it('limpia espacios y ceros sobrantes', () => {
    expect(leerDecimal(' 007,500 ', { decimales: 3 })).toEqual({ ok: true, valor: '7.5' });
    expect(leerDecimal('0,453592', { decimales: 6 })).toEqual({ ok: true, valor: '0.453592' });
    expect(leerDecimal('24', { decimales: 0 })).toEqual({ ok: true, valor: '24' });
  });

  it('no redondea: avisa si hay más decimales de los permitidos', () => {
    const r = leerDecimal('3,456', { decimales: 2 });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.mensaje).toBe('Máximo 2 decimales');
  });

  it('rechaza texto que no es un número', () => {
    for (const texto of ['', 'abc', '1,2,3', '1.000,50', '$3', '1e3']) {
      expect(leerDecimal(texto, { decimales: 2 }).ok).toBe(false);
    }
  });

  it('rechaza negativos salvo que se permitan', () => {
    expect(leerDecimal('-2', { decimales: 3 }).ok).toBe(false);
    expect(leerDecimal('-2', { decimales: 3, permitirNegativo: true })).toEqual({ ok: true, valor: '-2' });
  });

  it('puede rechazar el cero', () => {
    expect(leerDecimal('0,000', { decimales: 3, permitirCero: false }).ok).toBe(false);
    expect(leerDecimal('-0', { decimales: 3, permitirNegativo: true })).toEqual({ ok: true, valor: '0' });
  });
});

describe('paraEditar', () => {
  it('quita los ceros de relleno sin tocar los enteros', () => {
    expect(paraEditar('12.000000')).toBe('12');
    expect(paraEditar('10.000000')).toBe('10');
    expect(paraEditar('120.500000')).toBe('120,5');
    expect(paraEditar('0.453592')).toBe('0,453592');
    expect(paraEditar('100')).toBe('100');
  });

  it('lo que devuelve se vuelve a leer igual', () => {
    for (const v of ['3.45', '0.907', '45.359237']) {
      expect(leerDecimal(paraEditar(v), { decimales: 6 })).toEqual({ ok: true, valor: v });
    }
  });
});

describe('restarDinero', () => {
  it('calcula el vuelto en centavos exactos', () => {
    expect(restarDinero('20', '7.50')).toBe('12.50');
    expect(restarDinero('10.35', '10.35')).toBe('0.00');
    expect(restarDinero('0.3', '0.1')).toBe('0.20');
  });

  it('indica cuánto falta con signo negativo', () => {
    expect(restarDinero('5', '7.5')).toBe('-2.50');
  });
});

describe('sumarDinero', () => {
  it('suma sin errores de coma flotante', () => {
    expect(sumarDinero(['0.10', '0.20'])).toBe('0.30');
    expect(sumarDinero(['10.35', '-4.00', '2.90'])).toBe('9.25');
    expect(sumarDinero([])).toBe('0.00');
  });
});

describe('negar', () => {
  it('cambia el signo sin tocar los dígitos', () => {
    expect(negar('2.5')).toBe('-2.5');
    expect(negar('-1')).toBe('1');
    expect(negar('0')).toBe('0');
  });
});
