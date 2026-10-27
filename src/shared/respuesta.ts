/**
 * Formato único de respuesta de las funciones de negocio (Fase 2, contratos de API):
 *   { ok: true,  data: ... }
 *   { ok: false, error: { codigo, mensaje, detalle } }
 * Debe coincidir con privado.ok() y privado.error() en la base de datos.
 */

export const CODIGOS_ERROR = [
  'SIN_PERMISO',
  'STOCK_INSUFICIENTE',
  'LIMITE_FIADO',
  'CAJA_CERRADA',
  'DATOS_INVALIDOS',
  'DUPLICADO',
  'ERROR_INTERNO',
] as const;

export type CodigoError = (typeof CODIGOS_ERROR)[number];

export interface ErrorNegocio {
  codigo: CodigoError;
  mensaje: string;
  detalle: unknown;
}

export type Respuesta<T> = { ok: true; data: T } | { ok: false; error: ErrorNegocio };

function esObjeto(valor: unknown): valor is Record<string, unknown> {
  return typeof valor === 'object' && valor !== null && !Array.isArray(valor);
}

/**
 * Valida la forma de lo que devuelve una función SQL.
 * Si la forma no es la esperada, NO se adivina: se devuelve ERROR_INTERNO.
 * El contenido de `data` se valida después con el esquema Zod de cada operación.
 */
export function leerRespuesta(crudo: unknown): Respuesta<unknown> {
  if (!esObjeto(crudo) || typeof crudo.ok !== 'boolean') {
    return errorInterno('Respuesta con formato desconocido');
  }

  if (crudo.ok) {
    return { ok: true, data: crudo.data };
  }

  const error = crudo.error;
  if (!esObjeto(error) || typeof error.codigo !== 'string') {
    return errorInterno('Error sin código');
  }

  const codigo = (CODIGOS_ERROR as readonly string[]).includes(error.codigo)
    ? (error.codigo as CodigoError)
    : 'ERROR_INTERNO';

  return {
    ok: false,
    error: {
      codigo,
      mensaje: typeof error.mensaje === 'string' ? error.mensaje : 'Ocurrió un error inesperado',
      detalle: error.detalle ?? null,
    },
  };
}

function errorInterno(detalle: string): Respuesta<never> {
  return {
    ok: false,
    error: { codigo: 'ERROR_INTERNO', mensaje: 'Ocurrió un error inesperado', detalle },
  };
}
