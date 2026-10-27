import { describe, expect, it } from 'vitest';
import { leerRespuesta } from './respuesta';

describe('leerRespuesta', () => {
  it('acepta una respuesta exitosa', () => {
    expect(leerRespuesta({ ok: true, data: { id: 1 } })).toEqual({ ok: true, data: { id: 1 } });
  });

  it('acepta un error conocido, con el formato de privado.error()', () => {
    const r = leerRespuesta({
      ok: false,
      error: { codigo: 'SIN_PERMISO', mensaje: 'No tienes permiso para esta acción', detalle: null },
    });
    expect(r).toEqual({
      ok: false,
      error: { codigo: 'SIN_PERMISO', mensaje: 'No tienes permiso para esta acción', detalle: null },
    });
  });

  it('convierte un código desconocido en ERROR_INTERNO', () => {
    const r = leerRespuesta({ ok: false, error: { codigo: 'ALGO_RARO', mensaje: 'x' } });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.codigo).toBe('ERROR_INTERNO');
  });

  it('no adivina ante una forma inesperada', () => {
    for (const crudo of [null, undefined, 'ok', 42, [], { data: 1 }, { ok: 'true' }]) {
      const r = leerRespuesta(crudo);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.error.codigo).toBe('ERROR_INTERNO');
    }
  });

  it('trata un error sin código como ERROR_INTERNO', () => {
    const r = leerRespuesta({ ok: false, error: {} });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.codigo).toBe('ERROR_INTERNO');
  });
});
