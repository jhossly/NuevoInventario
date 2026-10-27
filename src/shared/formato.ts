/**
 * Formato de valores para mostrar en pantalla.
 *
 * IMPORTANTE: estas funciones solo FORMATEAN. No redondean para calcular.
 * Los cálculos de dinero, IVA y costos viven en las funciones SQL
 * (ver docs/DECISIONES.md, D-011). Aquí solo convertimos un valor que ya
 * llegó calculado desde la base en texto legible.
 *
 * Los valores llegan desde PostgreSQL `numeric` como texto (por ejemplo "7.50")
 * para no perder precisión al pasar por un `number` de JavaScript.
 */

const formatoDinero = new Intl.NumberFormat('es-EC', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

const formatoCantidad = new Intl.NumberFormat('es-EC', {
  minimumFractionDigits: 0,
  maximumFractionDigits: 3,
});

const formatoPorcentaje = new Intl.NumberFormat('es-EC', {
  style: 'percent',
  minimumFractionDigits: 1,
  maximumFractionDigits: 1,
});

const NUMERO_DECIMAL = /^-?\d+(\.\d+)?$/;

/** Convierte un numeric de Postgres (texto) a number solo para mostrarlo. */
function aNumeroParaMostrar(valor: string | number): number {
  if (typeof valor === 'number') {
    if (!Number.isFinite(valor)) throw new Error(`Valor no finito: ${valor}`);
    return valor;
  }
  const limpio = valor.trim();
  if (!NUMERO_DECIMAL.test(limpio)) {
    throw new Error(`No es un número decimal válido: "${valor}"`);
  }
  return Number(limpio);
}

/** "7.5" → "$7,50" (separadores según es-EC). */
export function formatearDinero(valor: string | number): string {
  return formatoDinero.format(aNumeroParaMostrar(valor));
}

/** "1.250" → "1,25"; "24" → "24". Hasta 3 decimales (gramos). */
export function formatearCantidad(valor: string | number): string {
  return formatoCantidad.format(aNumeroParaMostrar(valor));
}

/** 0.18157 → "18,2 %". Recibe una fracción, no un porcentaje. */
export function formatearPorcentaje(fraccion: string | number): string {
  return formatoPorcentaje.format(aNumeroParaMostrar(fraccion));
}
