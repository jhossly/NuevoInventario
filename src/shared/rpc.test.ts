import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { ErrorDeNegocio, exigir, interpretarConsulta, interpretarFuncion } from './rpc';

const esquema = z.object({ id: z.string() });

describe('interpretarFuncion', () => {
  it('devuelve los datos validados de una respuesta exitosa', () => {
    expect(interpretarFuncion({ data: { ok: true, data: { id: 'a' } }, error: null }, esquema)).toEqual({
      ok: true,
      data: { id: 'a' },
    });
  });

  it('pasa el error de negocio de la función tal cual', () => {
    const r = interpretarFuncion(
      {
        data: { ok: false, error: { codigo: 'STOCK_INSUFICIENTE', mensaje: 'No hay stock suficiente', detalle: null } },
        error: null,
      },
      esquema,
    );
    expect(r).toEqual({
      ok: false,
      error: { codigo: 'STOCK_INSUFICIENTE', mensaje: 'No hay stock suficiente', detalle: null },
    });
  });

  it('convierte un 42501 de PostgREST en SIN_PERMISO', () => {
    const r = interpretarFuncion({ data: null, error: { code: '42501', message: 'permission denied' } }, esquema);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.codigo).toBe('SIN_PERMISO');
  });

  it('trata otros errores de transporte como ERROR_INTERNO', () => {
    const r = interpretarFuncion({ data: null, error: { code: 'PGRST202', message: 'no existe' } }, esquema);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.codigo).toBe('ERROR_INTERNO');
  });

  it('no acepta datos con otra forma aunque ok sea true', () => {
    const r = interpretarFuncion({ data: { ok: true, data: { id: 5 } }, error: null }, esquema);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.codigo).toBe('ERROR_INTERNO');
  });
});

describe('interpretarConsulta', () => {
  it('valida las filas de una lectura directa', () => {
    expect(interpretarConsulta({ data: [{ id: 'a' }], error: null }, z.array(esquema))).toEqual({
      ok: true,
      data: [{ id: 'a' }],
    });
    expect(interpretarConsulta({ data: [{ otro: 1 }], error: null }, z.array(esquema)).ok).toBe(false);
  });
});

describe('exigir', () => {
  it('lanza ErrorDeNegocio con el código y el mensaje del servidor', () => {
    try {
      exigir({ ok: false, error: { codigo: 'DUPLICADO', mensaje: 'Ya existe', detalle: null } });
      expect.unreachable();
    } catch (e) {
      expect(e).toBeInstanceOf(ErrorDeNegocio);
      expect((e as ErrorDeNegocio).codigo).toBe('DUPLICADO');
      expect((e as ErrorDeNegocio).message).toBe('Ya existe');
    }
  });
});
