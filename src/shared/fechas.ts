/**
 * Fechas de negocio como texto "AAAA-MM-DD" en la hora local del dispositivo
 * (la bodega está en Ecuador). La base vuelve a interpretar las fechas con la
 * zona horaria de la empresa.
 */
export function aTexto(fecha: Date): string {
  return `${fecha.getFullYear()}-${String(fecha.getMonth() + 1).padStart(2, '0')}-${String(fecha.getDate()).padStart(2, '0')}`;
}

export interface Rango {
  desde: string;
  hasta: string;
}

/** El mes de `referencia` desplazado `meses` (0 = este mes, −1 = el anterior). */
export function rangoMes(referencia: Date, meses = 0): Rango {
  const inicio = new Date(referencia.getFullYear(), referencia.getMonth() + meses, 1);
  const fin = new Date(inicio.getFullYear(), inicio.getMonth() + 1, 0);
  return { desde: aTexto(inicio), hasta: aTexto(fin) };
}

const nombreMes = new Intl.DateTimeFormat('es-EC', { month: 'long', year: 'numeric', timeZone: 'UTC' });

/** "2026-10-01" → "octubre de 2026". */
export function nombrarMes(desde: string): string {
  return nombreMes.format(new Date(`${desde}T00:00:00Z`));
}
