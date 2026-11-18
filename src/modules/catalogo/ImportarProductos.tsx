import { useMemo, useState } from 'react';
import { useBorrador } from '@/shared/borrador';
import { leerDecimal } from '@/shared/decimal';
import { ElegirArchivo } from '@/shared/ElegirArchivo';
import { enlace } from '@/shared/ruta';
import { Aviso, AvisoError, Boton, Campo, Cargando, Casilla, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import { nuevaClave } from '@/shared/uuid';
import { leerLibroExcel, productosDelLibro } from '@/shared/xlsx';
import { useImportarProductos, useProductos, type FilaImportar, type Producto } from './api';

/** Una fila del Excel en la vista previa: stock y costo se pueden corregir. */
interface Fila {
  id: string;
  hoja: string;
  fila: number;
  codigo: string;
  nombre: string;
  /** Stock como venía en el Excel. */
  stockExcel: number | null;
  stock: string;
  costo: string;
}

interface Opciones {
  tarifa: string;
  categoriaHoja: boolean;
}

type Estado = { tipo: 'nuevo' } | { tipo: 'existe'; como: string } | { tipo: 'repetido'; fila: Fila };

function normalizar(texto: string): string {
  return texto.normalize('NFD').replace(/\p{Diacritic}/gu, '').replace(/\s+/g, ' ').trim().toLowerCase();
}

/** Qué pasa con cada fila: nueva, ya existe en la app o repetida en el mismo archivo. */
function estados(filas: Fila[], productos: Producto[]): Estado[] {
  const porCodigo = new Map<string, Producto>();
  const porNombre = new Map<string, Producto>();
  for (const p of productos) {
    for (const c of [p.codigo_principal, p.codigo_auxiliar, ...p.presentaciones.map((r) => r.codigo_barras)]) {
      if (c) porCodigo.set(c.trim(), p);
    }
    if (p.activo) porNombre.set(normalizar(p.nombre), p);
  }
  const vistosCodigo = new Map<string, Fila>();
  const vistosNombre = new Map<string, Fila>();
  return filas.map((f) => {
    const codigo = f.codigo.trim();
    const nombre = normalizar(f.nombre);
    const existente = (codigo && porCodigo.get(codigo)) || porNombre.get(nombre);
    if (existente) return { tipo: 'existe', como: existente.nombre };
    const anterior = (codigo && vistosCodigo.get(codigo)) || vistosNombre.get(nombre);
    if (anterior) return { tipo: 'repetido', fila: anterior };
    if (codigo) vistosCodigo.set(codigo, f);
    vistosNombre.set(nombre, f);
    return { tipo: 'nuevo' };
  });
}

/** Errores de una fila nueva y lo que se manda a la base. */
function validar(f: Fila, opciones: Opciones) {
  const errores: Partial<Record<'nombre' | 'codigo' | 'stock' | 'costo', string>> = {};
  const stock = f.stock.trim() === '' ? ({ ok: true, valor: '0' } as const) : leerDecimal(f.stock, { decimales: 3 });
  const costo = f.costo.trim() === '' ? ({ ok: true, valor: '' } as const) : leerDecimal(f.costo, { decimales: 6 });
  if (f.nombre.trim() === '') errores.nombre = 'Escribe el nombre';
  if (f.codigo.trim().length > 25) errores.codigo = 'Hasta 25 caracteres';
  if (!stock.ok) errores.stock = stock.mensaje;
  if (!costo.ok) errores.costo = costo.mensaje;
  if (Object.keys(errores).length > 0 || !stock.ok || !costo.ok) return { errores, fila: null };
  const fila: FilaImportar = {
    nombre: f.nombre.trim(),
    codigo: f.codigo.trim() || null,
    categoria: opciones.categoriaHoja ? f.hoja : null,
    stock: stock.valor,
    costo: costo.valor,
  };
  return { errores, fila };
}

/**
 * Importar productos del libro de Excel (D-071): lee la tabla de productos de
 * cada hoja, muestra qué es nuevo y qué ya existe, y deja poner el costo y
 * corregir el stock antes de crear. Un stock negativo entra en cero.
 */
export function ImportarProductos() {
  const productos = useProductos();
  const importar = useImportarProductos();
  const [filas, setFilas, borrarFilas] = useBorrador<Fila[]>('importar:filas', []);
  const [opciones, setOpciones] = useBorrador<Opciones>('importar:opciones', { tarifa: '15', categoriaHoja: true });
  const [leyendo, setLeyendo] = useState(false);
  const [errorArchivo, setErrorArchivo] = useState<string | null>(null);
  const [hoja, setHoja] = useState('');
  const [verTodos, setVerTodos] = useState(false);
  const [mostrarErrores, setMostrarErrores] = useState(false);
  const [resultado, setResultado] = useState<{ creados: number; con_stock: number; existentes: number } | null>(null);

  const lista = useMemo(() => estados(filas, productos.data ?? []), [filas, productos.data]);
  const validadas = filas.map((f) => validar(f, opciones));
  const nuevas = filas.flatMap((_, i) => (lista[i]?.tipo === 'nuevo' ? [i] : []));
  const conStock = nuevas.filter((i) => Number(validadas[i]?.fila?.stock ?? 0) > 0 && validadas[i]?.fila?.costo).length;
  const hojas = [...new Set(filas.map((f) => f.hoja))];
  const visibles = filas
    .map((f, i) => ({ f, i }))
    .filter(({ f, i }) => (hoja === '' || f.hoja === hoja) && (verTodos || lista[i]?.tipo === 'nuevo'));

  const elegir = async (archivos: File[]) => {
    const elegido = archivos[0];
    if (!elegido) return;
    setErrorArchivo(null);
    setResultado(null);
    setLeyendo(true);
    try {
      const encontrados = productosDelLibro(await leerLibroExcel(elegido));
      if (encontrados.length === 0) {
        setErrorArchivo('No encontré ninguna tabla con las columnas CODIGO, ARTICULO y STOCK en este libro.');
        return;
      }
      setFilas(
        encontrados.map((p) => ({
          id: nuevaClave(),
          hoja: p.hoja,
          fila: p.fila,
          codigo: p.codigo ?? '',
          nombre: p.nombre,
          stockExcel: p.stock,
          // Un stock negativo o vacío entra en cero.
          stock: p.stock !== null && p.stock > 0 ? String(p.stock) : '0',
          costo: '',
        })),
      );
      setHoja('');
    } catch (e) {
      setErrorArchivo(e instanceof Error ? e.message : 'No se pudo leer el archivo');
    } finally {
      setLeyendo(false);
    }
  };

  const cambiar = (i: number, cambios: Partial<Fila>) =>
    setFilas((fs) => fs.map((f, j) => (j === i ? { ...f, ...cambios } : f)));

  const confirmar = () => {
    setMostrarErrores(true);
    const enviar = nuevas.map((i) => validadas[i]?.fila ?? null);
    if (enviar.length === 0 || enviar.some((x) => x === null)) return;
    importar.mutate(
      { filas: enviar as FilaImportar[], tarifa: opciones.tarifa },
      {
        onSuccess: (r) => {
          setResultado(r);
          borrarFilas();
          setMostrarErrores(false);
        },
      },
    );
  };

  if (productos.isPending) return <Cargando />;
  const hayErrores = nuevas.some((i) => validadas[i]?.fila === null);

  return (
    <>
      <Encabezado titulo="Importar productos de Excel" volver={enlace({ nombre: 'productos' })} />

      {resultado && (
        <div className="mb-4">
          <Aviso tipo="exito">
            Listo: se crearon {resultado.creados} productos, {resultado.con_stock} con stock.
            {resultado.existentes > 0 && ` ${resultado.existentes} ya existían y no se tocaron.`} Quedan en «Productos»
            marcados «por completar» para que les pongas precio y foto.{' '}
            <a href={enlace({ nombre: 'productos' })} className="font-semibold underline">
              Ver productos
            </a>
          </Aviso>
        </div>
      )}

      <Tarjeta className="mb-4">
        <p className="mb-3 text-sm text-gray-600">
          Elige tu libro de Excel (.xlsx o .xlsm). Se lee la tabla con CODIGO, ARTICULO y STOCK de cada hoja; no se
          sube el archivo ni se ejecutan sus macros. Los productos que ya tienes (mismo código o mismo nombre) no se
          duplican.
        </p>
        <ElegirArchivo etiqueta="Elegir libro de Excel" ocupado={leyendo ? 'Leyendo…' : undefined} alElegir={(a) => void elegir(a)} />
        {errorArchivo && (
          <div className="mt-2">
            <Aviso>{errorArchivo}</Aviso>
          </div>
        )}
      </Tarjeta>

      {filas.length > 0 && (
        <>
          <Tarjeta className="mb-4">
            <div className="grid gap-3 sm:grid-cols-3">
              <Selector
                etiqueta="IVA de estos productos"
                value={opciones.tarifa}
                onChange={(e) => {
                  const tarifa = e.target.value;
                  setOpciones((o) => ({ ...o, tarifa }));
                }}
              >
                <option value="0">0 %</option>
                <option value="5">5 %</option>
                <option value="15">15 %</option>
              </Selector>
              <Selector etiqueta="Hoja" value={hoja} onChange={(e) => setHoja(e.target.value)}>
                <option value="">Todas ({hojas.length})</option>
                {hojas.map((h) => (
                  <option key={h} value={h}>
                    {h}
                  </option>
                ))}
              </Selector>
              <div className="flex flex-col justify-end gap-1 pb-1">
                <Casilla
                  etiqueta="El nombre de la hoja es la categoría"
                  checked={opciones.categoriaHoja}
                  onChange={(e) => {
                    const categoriaHoja = e.target.checked;
                    setOpciones((o) => ({ ...o, categoriaHoja }));
                  }}
                />
                <Casilla etiqueta="Ver también los que ya existen" checked={verTodos} onChange={(e) => setVerTodos(e.target.checked)} />
              </div>
            </div>
            <p className="mt-3 text-sm text-gray-700">
              <strong>{nuevas.length}</strong> nuevos ({conStock} con stock) ·{' '}
              {lista.filter((e) => e.tipo === 'existe').length} ya existen ·{' '}
              {lista.filter((e) => e.tipo === 'repetido').length} repetidos en el archivo
            </p>
            <p className="mt-1 text-xs text-gray-500">
              El stock entra solo si pones el costo por unidad; sin costo, el producto se crea sin stock. Si vendes con
              IVA 0 %, eso se configura en «IVA de ventas».
            </p>
          </Tarjeta>

          <ol className="mb-4 flex flex-col gap-2">
            {visibles.map(({ f, i }) => {
              const estado = lista[i]!;
              const errores = mostrarErrores ? (validadas[i]?.errores ?? {}) : {};
              const negativo = f.stockExcel !== null && f.stockExcel < 0;
              const sinCosto = estado.tipo === 'nuevo' && Number(f.stock.replace(',', '.')) > 0 && f.costo.trim() === '';
              return (
                <li
                  key={f.id}
                  className={`rounded-lg border bg-white p-3 ${estado.tipo === 'nuevo' ? 'border-gray-200' : 'border-dashed border-gray-300 opacity-70'}`}
                >
                  <div className="mb-2 flex flex-wrap items-center gap-2 text-sm">
                    <span className="font-medium">{f.nombre}</span>
                    {f.codigo && <span className="text-gray-500">· {f.codigo}</span>}
                    <span className="text-gray-500">
                      · {f.hoja}, fila {f.fila}
                    </span>
                    {estado.tipo === 'nuevo' && (
                      <span className="rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-800">Nuevo</span>
                    )}
                    {estado.tipo === 'existe' && (
                      <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700">
                        Ya existe: {estado.como}
                      </span>
                    )}
                    {estado.tipo === 'repetido' && (
                      <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700">
                        Repetido: {estado.fila.hoja}, fila {estado.fila.fila}
                      </span>
                    )}
                  </div>
                  {estado.tipo === 'nuevo' && (
                    <>
                      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                        <div className="col-span-2">
                          <Campo
                            etiqueta="Nombre"
                            value={f.nombre}
                            onChange={(e) => cambiar(i, { nombre: e.target.value })}
                            error={errores.nombre}
                          />
                        </div>
                        <Campo
                          etiqueta="Stock"
                          inputMode="decimal"
                          value={f.stock}
                          disabled={negativo}
                          onChange={(e) => cambiar(i, { stock: e.target.value })}
                          error={errores.stock}
                        />
                        <Campo
                          etiqueta="Costo c/u"
                          inputMode="decimal"
                          placeholder="Para el stock"
                          value={f.costo}
                          disabled={negativo}
                          onChange={(e) => cambiar(i, { costo: e.target.value })}
                          error={errores.costo}
                        />
                      </div>
                      {negativo && (
                        <p className="mt-1 text-sm text-amber-800">
                          En el Excel el stock es {f.stockExcel}: se crea el producto sin stock.
                        </p>
                      )}
                      {sinCosto && !negativo && (
                        <p className="mt-1 text-sm text-amber-800">Sin costo por unidad: se crea sin stock.</p>
                      )}
                    </>
                  )}
                </li>
              );
            })}
          </ol>

          <div className="sticky bottom-0 -mx-4 flex flex-col gap-2 border-t border-gray-200 bg-gray-50 p-4">
            {mostrarErrores && hayErrores && <Aviso>Revisa las filas marcadas.</Aviso>}
            <AvisoError error={importar.error} />
            <div className="flex flex-wrap gap-2">
              <Boton onClick={confirmar} disabled={importar.isPending || nuevas.length === 0}>
                {importar.isPending
                  ? 'Importando…'
                  : nuevas.length === 0
                    ? 'No hay productos nuevos'
                    : `Crear ${nuevas.length} producto${nuevas.length === 1 ? '' : 's'}`}
              </Boton>
              <Boton
                variante="secundario"
                onClick={() => {
                  borrarFilas();
                  setMostrarErrores(false);
                }}
              >
                Empezar de nuevo
              </Boton>
            </div>
          </div>
        </>
      )}
    </>
  );
}
