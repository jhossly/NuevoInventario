export class ArchivoNoXml extends Error {}

const LIMITE = 1_000_000;

/**
 * Lee un archivo elegido como XML del SRI. No se fía de la extensión ni del
 * tipo que diga el celular (Android a veces no lo dice): mira el contenido.
 */
export async function leerXml(archivo: File): Promise<string> {
  if (archivo.size === 0) throw new ArchivoNoXml('El archivo está vacío: vuelve a descargarlo');
  if (archivo.size > LIMITE) throw new ArchivoNoXml('El archivo es demasiado grande para ser una factura');
  const texto = (await archivo.text()).replace(/^﻿/, '');
  if (!/^\s*</.test(texto) || !/<(factura|autorizacion)[\s>]/.test(texto)) {
    throw new ArchivoNoXml(
      /%PDF/.test(texto.slice(0, 8)) ? 'Ese archivo es el PDF: sube el XML de la factura' : 'Ese archivo no es el XML de una factura',
    );
  }
  return texto;
}
