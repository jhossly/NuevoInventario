/**
 * Lector mínimo de libros de Excel (.xlsx y .xlsm) en el navegador, sin
 * dependencias (D-071): un libro es un zip de XML. Solo lee los valores de
 * las celdas (texto y números); no ejecuta macros ni lee fórmulas.
 */

export interface HojaLeida {
  nombre: string;
  /** Filas de celdas como texto; null si la celda está vacía. */
  filas: (string | null)[][];
}

interface EntradaZip {
  nombre: string;
  metodo: number;
  tamano: number;
  desplazamiento: number;
}

function entradasZip(datos: DataView): EntradaZip[] {
  // Fin del directorio central: firma 0x06054b50, buscada desde el final.
  let fin = -1;
  for (let i = datos.byteLength - 22; i >= Math.max(0, datos.byteLength - 65_557); i--) {
    if (datos.getUint32(i, true) === 0x06054b50) {
      fin = i;
      break;
    }
  }
  if (fin < 0) throw new Error('No es un archivo de Excel (.xlsx o .xlsm)');
  const cantidad = datos.getUint16(fin + 10, true);
  let p = datos.getUint32(fin + 16, true);
  const decodificador = new TextDecoder();
  const entradas: EntradaZip[] = [];
  for (let n = 0; n < cantidad; n++) {
    if (datos.getUint32(p, true) !== 0x02014b50) throw new Error('El archivo de Excel está dañado');
    const metodo = datos.getUint16(p + 10, true);
    const tamano = datos.getUint32(p + 20, true);
    const largoNombre = datos.getUint16(p + 28, true);
    const largoExtra = datos.getUint16(p + 30, true);
    const largoComentario = datos.getUint16(p + 32, true);
    const desplazamiento = datos.getUint32(p + 42, true);
    const nombre = decodificador.decode(new Uint8Array(datos.buffer, datos.byteOffset + p + 46, largoNombre));
    entradas.push({ nombre, metodo, tamano, desplazamiento });
    p += 46 + largoNombre + largoExtra + largoComentario;
  }
  return entradas;
}

async function contenido(datos: DataView, e: EntradaZip): Promise<string> {
  const largoNombre = datos.getUint16(e.desplazamiento + 26, true);
  const largoExtra = datos.getUint16(e.desplazamiento + 28, true);
  const inicio = datos.byteOffset + e.desplazamiento + 30 + largoNombre + largoExtra;
  const bytes = new Uint8Array(datos.buffer, inicio, e.tamano);
  if (e.metodo === 0) return new TextDecoder().decode(bytes);
  if (e.metodo !== 8) throw new Error('El archivo de Excel usa una compresión que no se puede leer');
  const flujo = new Blob([bytes.slice()]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Response(flujo).text();
}

/** "AB12" → 27 (columna desde 0). */
function columnaDe(ref: string): number {
  let n = 0;
  for (const ch of ref) {
    const c = ch.charCodeAt(0);
    if (c < 65 || c > 90) break;
    n = n * 26 + (c - 64);
  }
  return n - 1;
}

function textoDe(nodo: Element): string {
  // Un texto con formato viene en varios <t>: se juntan.
  return Array.from(nodo.getElementsByTagName('t'))
    .map((t) => t.textContent ?? '')
    .join('');
}

/** Lee todas las hojas de un libro de Excel. */
export async function leerLibroExcel(archivo: Blob): Promise<HojaLeida[]> {
  const datos = new DataView(await archivo.arrayBuffer());
  const entradas = new Map(entradasZip(datos).map((e) => [e.nombre, e]));
  const leer = async (nombre: string) => {
    const e = entradas.get(nombre);
    return e ? contenido(datos, e) : null;
  };
  const xml = (texto: string) => new DOMParser().parseFromString(texto, 'application/xml');

  const libro = await leer('xl/workbook.xml');
  const relaciones = await leer('xl/_rels/workbook.xml.rels');
  if (!libro || !relaciones) throw new Error('No es un archivo de Excel (.xlsx o .xlsm)');

  const destinos = new Map(
    Array.from(xml(relaciones).getElementsByTagName('Relationship')).map((r) => [
      r.getAttribute('Id') ?? '',
      r.getAttribute('Target') ?? '',
    ]),
  );
  const compartidosXml = await leer('xl/sharedStrings.xml');
  const compartidos = compartidosXml ? Array.from(xml(compartidosXml).getElementsByTagName('si')).map(textoDe) : [];

  const hojas: HojaLeida[] = [];
  for (const hoja of Array.from(xml(libro).getElementsByTagName('sheet'))) {
    const id =
      hoja.getAttribute('r:id') ??
      hoja.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships', 'id') ??
      '';
    const destino = destinos.get(id);
    if (!destino) continue;
    const ruta = destino.startsWith('/') ? destino.slice(1) : `xl/${destino}`;
    const texto = await leer(ruta);
    if (!texto) continue;

    const filas: (string | null)[][] = [];
    for (const fila of Array.from(xml(texto).getElementsByTagName('row'))) {
      const numero = Number(fila.getAttribute('r') ?? filas.length + 1) - 1;
      const celdas: (string | null)[] = [];
      for (const c of Array.from(fila.getElementsByTagName('c'))) {
        const tipo = c.getAttribute('t');
        const v = c.getElementsByTagName('v')[0]?.textContent ?? null;
        let valor: string | null;
        if (tipo === 's') valor = v === null ? null : (compartidos[Number(v)] ?? null);
        else if (tipo === 'inlineStr') valor = textoDe(c);
        else valor = v;
        celdas[columnaDe(c.getAttribute('r') ?? '')] = valor === '' ? null : valor;
      }
      filas[numero] = Array.from(celdas, (x) => x ?? null);
    }
    hojas.push({ nombre: hoja.getAttribute('name') ?? 'Hoja', filas: Array.from(filas, (f) => f ?? []) });
  }
  return hojas;
}

// -----------------------------------------------------------------------------
// Productos del libro del dueño (D-071)
// -----------------------------------------------------------------------------

export interface ProductoDelLibro {
  hoja: string;
  /** Fila en Excel (desde 1). */
  fila: number;
  codigo: string | null;
  nombre: string;
  /** Stock tal como está en el Excel; null si no se pudo leer. */
  stock: number | null;
}

function normalizar(texto: string): string {
  return texto.normalize('NFD').replace(/\p{Diacritic}/gu, '').trim().toLowerCase();
}

const NOMBRES = ['articulo', 'producto', 'nombre', 'descripcion'];
const STOCKS = ['stock', 'existencia', 'existencias', 'saldo'];

/**
 * Busca en cada hoja la primera fila con CODIGO, ARTICULO (o PRODUCTO,
 * NOMBRE, DESCRIPCION) y STOCK, y toma las filas de abajo con nombre. Las
 * hojas sin esa tabla se ignoran.
 */
export function productosDelLibro(hojas: HojaLeida[]): ProductoDelLibro[] {
  const productos: ProductoDelLibro[] = [];
  for (const hoja of hojas) {
    let encabezado = -1;
    let cCodigo = -1;
    let cNombre = -1;
    let cStock = -1;
    for (let f = 0; f < hoja.filas.length && encabezado < 0; f++) {
      const textos = (hoja.filas[f] ?? []).map((x) => (x === null ? '' : normalizar(x)));
      const codigo = textos.findIndex((t) => t === 'codigo' || t === 'cod');
      if (codigo < 0) continue;
      const nombre = textos.findIndex((t, i) => i > codigo && NOMBRES.includes(t));
      const stock = textos.findIndex((t, i) => i > Math.max(codigo, nombre) && STOCKS.includes(t));
      if (nombre < 0 || stock < 0) continue;
      [encabezado, cCodigo, cNombre, cStock] = [f, codigo, nombre, stock];
    }
    if (encabezado < 0) continue;

    for (let f = encabezado + 1; f < hoja.filas.length; f++) {
      const celdas = hoja.filas[f] ?? [];
      const nombre = (celdas[cNombre] ?? '').replace(/\s+/g, ' ').trim();
      if (nombre === '') continue;
      const codigo = (celdas[cCodigo] ?? '').trim() || null;
      const stockTexto = (celdas[cStock] ?? '').trim();
      const stock = stockTexto === '' ? null : Number(stockTexto);
      productos.push({
        hoja: hoja.nombre.trim(),
        fila: f + 1,
        codigo,
        nombre,
        stock: stock === null || Number.isNaN(stock) ? null : stock,
      });
    }
  }
  return productos;
}
