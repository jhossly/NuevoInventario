/**
 * CSV para el contador (D-038): lo abre Excel en español con doble clic.
 *   * separador `;` y coma decimal (configuración regional es-EC)
 *   * UTF-8 con BOM, para que las tildes se vean bien
 *   * fin de línea CRLF
 * Los textos que empiezan con = + - @ se anteponen con un apóstrofo: un
 * nombre de cliente como «=HYPERLINK(...)» no debe ejecutarse como fórmula.
 */
export interface Columna<T> {
  titulo: string;
  valor: (fila: T) => string | null | undefined;
  /** numeric de la base como texto ("12.50"): se escribe con coma decimal. */
  decimal?: boolean;
}

const BOM = '﻿';
const NECESITA_COMILLAS = /[;"\r\n]|^\s|\s$/;
const FORMULA = /^[=+\-@\t\r]/;

function celda(texto: string, decimal: boolean): string {
  let valor = texto;
  if (decimal) valor = valor.replace('.', ',');
  else if (FORMULA.test(valor)) valor = `'${valor}`;
  return NECESITA_COMILLAS.test(valor) ? `"${valor.replace(/"/g, '""')}"` : valor;
}

export function generarCsv<T>(filas: T[], columnas: Columna<T>[]): string {
  const encabezado = columnas.map((c) => celda(c.titulo, false)).join(';');
  const cuerpo = filas.map((fila) => columnas.map((c) => celda(c.valor(fila) ?? '', Boolean(c.decimal))).join(';'));
  return BOM + [encabezado, ...cuerpo].join('\r\n') + '\r\n';
}

/** Ofrece el texto como archivo descargado por el navegador. */
export function descargarArchivo(nombre: string, contenido: string, tipo = 'text/csv;charset=utf-8'): void {
  const url = URL.createObjectURL(new Blob([contenido], { type: tipo }));
  const enlace = document.createElement('a');
  enlace.href = url;
  enlace.download = nombre;
  document.body.appendChild(enlace);
  enlace.click();
  enlace.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
