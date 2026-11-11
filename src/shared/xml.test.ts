import { describe, expect, it } from 'vitest';
import { leerXml } from './xml';

const archivo = (contenido: string, nombre = 'f.xml', tipo = '') => new File([contenido], nombre, { type: tipo });

describe('leerXml', () => {
  it('acepta una factura aunque el celular no diga el tipo', async () => {
    await expect(leerXml(archivo('<?xml version="1.0"?><factura id="comprobante"></factura>'))).resolves.toContain('<factura');
  });

  it('acepta el sobre de autorización y quita el BOM', async () => {
    const texto = await leerXml(archivo('﻿<autorizacion><estado>AUTORIZADO</estado></autorizacion>', 'f.bin', 'application/octet-stream'));
    expect(texto.startsWith('<autorizacion>')).toBe(true);
  });

  it('avisa si es el PDF, si está vacío o si es otra cosa', async () => {
    await expect(leerXml(archivo('%PDF-1.7 ...', 'f.pdf'))).rejects.toThrow('Ese archivo es el PDF');
    await expect(leerXml(archivo(''))).rejects.toThrow('vacío');
    await expect(leerXml(archivo('<html></html>'))).rejects.toThrow('no es el XML de una factura');
  });
});
