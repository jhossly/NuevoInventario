import type { ZodType } from 'zod';
import { leerRespuesta, type ErrorNegocio, type Respuesta } from './respuesta';

/**
 * Interpretación de lo que devuelve Supabase, sin depender del cliente
 * (así se prueba sin variables de entorno). Las llamadas reales están en
 * src/lib/datos.ts.
 */

/** Forma común de { data, error } en supabase-js (rpc y consultas). */
export interface ResultadoSupabase {
  data: unknown;
  error: { code?: string; message: string } | null;
}

/** Error que lanzan las llamadas para que TanStack Query lo muestre. */
export class ErrorDeNegocio extends Error {
  readonly codigo: ErrorNegocio['codigo'];
  readonly detalle: unknown;

  constructor(error: ErrorNegocio) {
    super(error.mensaje);
    this.name = 'ErrorDeNegocio';
    this.codigo = error.codigo;
    this.detalle = error.detalle;
  }
}

function errorDeTransporte(error: NonNullable<ResultadoSupabase['error']>): Respuesta<never> {
  // 42501: permisos SQL o RLS. Es el único error de PostgREST que la interfaz
  // distingue; cualquier otro es un fallo inesperado.
  if (error.code === '42501') {
    return {
      ok: false,
      error: { codigo: 'SIN_PERMISO', mensaje: 'No tienes permiso para esta acción', detalle: null },
    };
  }
  return {
    ok: false,
    error: { codigo: 'ERROR_INTERNO', mensaje: 'Ocurrió un error inesperado', detalle: error.message },
  };
}

function datosInesperados(): Respuesta<never> {
  return {
    ok: false,
    error: {
      codigo: 'ERROR_INTERNO',
      mensaje: 'Ocurrió un error inesperado',
      detalle: 'Respuesta con datos inesperados',
    },
  };
}

/** Resultado de una función de negocio ({ ok, data } / { ok, error }). */
export function interpretarFuncion<T>(resultado: ResultadoSupabase, esquema: ZodType<T>): Respuesta<T> {
  if (resultado.error) return errorDeTransporte(resultado.error);

  const respuesta = leerRespuesta(resultado.data);
  if (!respuesta.ok) return respuesta;

  const validado = esquema.safeParse(respuesta.data);
  return validado.success ? { ok: true, data: validado.data } : datosInesperados();
}

/** Resultado de una lectura directa de tablas (lista de filas). */
export function interpretarConsulta<T>(resultado: ResultadoSupabase, esquema: ZodType<T>): Respuesta<T> {
  if (resultado.error) return errorDeTransporte(resultado.error);

  const validado = esquema.safeParse(resultado.data);
  return validado.success ? { ok: true, data: validado.data } : datosInesperados();
}

/** Convierte una Respuesta en valor o excepción. */
export function exigir<T>(respuesta: Respuesta<T>): T {
  if (!respuesta.ok) throw new ErrorDeNegocio(respuesta.error);
  return respuesta.data;
}
