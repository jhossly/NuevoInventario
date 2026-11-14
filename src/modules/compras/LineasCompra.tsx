import { useMemo, useState, type Dispatch, type ReactNode, type SetStateAction } from 'react';
import { unidadCorta, type Presentacion, type Producto } from '@/modules/catalogo/api';
import { leerDecimal } from '@/shared/decimal';
import { formatearCantidad } from '@/shared/formato';
import { nuevaClave } from '@/shared/uuid';
import { Boton, Buscador, Campo, Casilla, Selector } from '@/shared/ui';
import type { LineaCompra } from './api';

/** Una línea de compra mientras se escribe: en «Nueva compra» y en «¿Cuánto gano?». */
export interface LineaEnPantalla {
  /** Solo para la key de React: la misma presentación puede repetirse. */
  local: string;
  producto: Producto;
  presentacion: Presentacion;
  cantidad: string;
  costo: string;
  descuento: string;
  /** IVA de esta compra (D-064). Falta en borradores viejos: se usa el del producto. */
  tarifa?: string;
}

export type ErroresLinea = Partial<Record<'cantidad' | 'costo' | 'descuento', string>>;

/** Tarifas que se pueden elegir en una compra hoy. */
const TARIFAS = ['0', '5', '15'];

export function tarifaDelProducto(p: Producto): string {
  return String(Number(p.tarifa_iva));
}

export function tarifaDe(l: LineaEnPantalla): string {
  return l.tarifa ?? tarifaDelProducto(l.producto);
}

export function validarLinea(l: LineaEnPantalla): { errores: ErroresLinea; linea: LineaCompra | null } {
  const errores: ErroresLinea = {};
  const cantidad = leerDecimal(l.cantidad, { decimales: 3, permitirCero: false });
  const costo = leerDecimal(l.costo, { decimales: 6 });
  const descuento = l.descuento.trim() === '' ? ({ ok: true, valor: '0' } as const) : leerDecimal(l.descuento, { decimales: 2 });
  if (!cantidad.ok) errores.cantidad = cantidad.mensaje;
  if (!costo.ok) errores.costo = costo.mensaje;
  if (!descuento.ok) errores.descuento = descuento.mensaje;
  if (!cantidad.ok || !costo.ok || !descuento.ok) return { errores, linea: null };
  return {
    errores,
    linea: {
      presentacion_id: l.presentacion.id,
      cantidad: cantidad.valor,
      costo_unitario: costo.valor,
      descuento: descuento.valor,
      tarifa_iva: tarifaDe(l),
    },
  };
}

/** Las líneas válidas listas para la base, o null si falta algo. */
export function lineasParaEnviar(lineas: LineaEnPantalla[]) {
  const validadas = lineas.map(validarLinea);
  const todasValidas = lineas.length > 0 && validadas.every((v) => v.linea !== null);
  return { validadas, todasValidas, paraEnviar: todasValidas ? validadas.map((v) => v.linea as LineaCompra) : null };
}

/**
 * Productos de una compra: buscar y agregar, cantidad, costo, descuento e IVA
 * de la compra por línea, y la casilla de «IVA 15 % en todo». `debajo` muestra
 * lo calculado de cada línea.
 */
export function EditorLineas({
  productos,
  lineas,
  setLineas,
  validadas,
  mostrarErrores,
  lineaConError,
  debajo,
}: {
  productos: Producto[];
  lineas: LineaEnPantalla[];
  setLineas: Dispatch<SetStateAction<LineaEnPantalla[]>>;
  validadas: { errores: ErroresLinea }[];
  mostrarErrores: boolean;
  lineaConError: number;
  debajo?: (linea: LineaEnPantalla, indice: number) => ReactNode;
}) {
  const [busqueda, setBusqueda] = useState('');

  const opciones = useMemo(() => {
    const texto = busqueda.trim().toLowerCase();
    if (texto === '') return [];
    return productos
      .filter((p) => p.activo && p.nombre.toLowerCase().includes(texto))
      .flatMap((p) => p.presentaciones.filter((r) => r.activo && r.se_compra).map((r) => ({ producto: p, presentacion: r })))
      .slice(0, 12);
  }, [productos, busqueda]);

  // «Esta factura trae IVA 15 %»: marcada si todas las líneas van con 15 %.
  const todasCon15 = lineas.length > 0 && lineas.every((l) => tarifaDe(l) === '15');
  const ponerTodasCon15 = (si: boolean) =>
    setLineas((ls) => ls.map((l) => ({ ...l, tarifa: si ? '15' : tarifaDelProducto(l.producto) })));

  const agregar = (producto: Producto, presentacion: Presentacion) => {
    setLineas((ls) => [
      ...ls,
      {
        local: nuevaClave(),
        producto,
        presentacion,
        cantidad: '',
        costo: '',
        descuento: '',
        tarifa: todasCon15 ? '15' : tarifaDelProducto(producto),
      },
    ]);
    setBusqueda('');
  };

  const cambiar = (indice: number, cambios: Partial<LineaEnPantalla>) =>
    setLineas((ls) => ls.map((l, i) => (i === indice ? { ...l, ...cambios } : l)));

  return (
    <>
      <p className="mb-3 text-sm text-gray-500">
        Costos por presentación, sin IVA, como vienen en la factura. El IVA es el que cobró el proveedor: cambiarlo
        aquí no cambia el producto ni cómo se vende.
      </p>
      {lineas.length > 0 && (
        <div className="mb-3">
          <Casilla
            etiqueta="Esta factura trae IVA 15 % en todo"
            checked={todasCon15}
            onChange={(e) => ponerTodasCon15(e.target.checked)}
          />
        </div>
      )}

      <ol className="flex flex-col gap-3">
        {lineas.map((l, i) => {
          const errores = mostrarErrores ? (validadas[i]?.errores ?? {}) : {};
          const unidad = unidadCorta(l.producto.unidad_base);
          return (
            <li
              key={l.local}
              className={`rounded-lg border p-3 ${lineaConError === i ? 'border-red-400 bg-red-50' : 'border-gray-200'}`}
            >
              <div className="mb-2 flex items-start gap-2">
                <p className="flex-1 font-medium">
                  {l.producto.nombre} — {l.presentacion.nombre}
                  <span className="block text-sm font-normal text-gray-500">
                    {formatearCantidad(l.presentacion.factor)} {unidad}
                    {tarifaDe(l) !== tarifaDelProducto(l.producto) &&
                      ` · se vende con IVA ${tarifaDelProducto(l.producto)} %`}
                  </span>
                </p>
                <Boton
                  variante="secundario"
                  aria-label={`Quitar ${l.producto.nombre}`}
                  onClick={() => setLineas((ls) => ls.filter((_, j) => j !== i))}
                >
                  ✕
                </Boton>
              </div>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                <Campo
                  etiqueta="Cantidad"
                  inputMode="decimal"
                  value={l.cantidad}
                  onChange={(e) => cambiar(i, { cantidad: e.target.value })}
                  error={errores.cantidad}
                />
                <Campo
                  etiqueta="Costo c/u"
                  inputMode="decimal"
                  value={l.costo}
                  onChange={(e) => cambiar(i, { costo: e.target.value })}
                  error={errores.costo}
                />
                <Campo
                  etiqueta="Descuento $"
                  inputMode="decimal"
                  placeholder="0"
                  value={l.descuento}
                  onChange={(e) => cambiar(i, { descuento: e.target.value })}
                  error={errores.descuento}
                />
                <Selector
                  etiqueta="IVA de la compra"
                  value={tarifaDe(l)}
                  onChange={(e) => cambiar(i, { tarifa: e.target.value })}
                >
                  {[...new Set([...TARIFAS, tarifaDelProducto(l.producto)])].map((t) => (
                    <option key={t} value={t}>
                      {t} %
                    </option>
                  ))}
                </Selector>
              </div>
              {debajo?.(l, i)}
            </li>
          );
        })}
      </ol>

      <div className="mt-3">
        <Buscador
          etiqueta="Agregar producto: escribe el nombre"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
        {opciones.length > 0 && (
          <ul className="mt-1 divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white">
            {opciones.map(({ producto, presentacion }) => (
              <li key={presentacion.id}>
                <button
                  type="button"
                  onClick={() => agregar(producto, presentacion)}
                  className="flex min-h-11 w-full items-center justify-between px-3 text-left hover:bg-gray-50"
                >
                  <span>
                    {producto.nombre} — {presentacion.nombre}
                  </span>
                  <span className="text-sm text-gray-500">
                    {formatearCantidad(presentacion.factor)} {unidadCorta(producto.unidad_base)}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {busqueda.trim() !== '' && opciones.length === 0 && (
          <p className="mt-2 text-sm text-gray-500">Ningún producto activo con presentación de compra coincide.</p>
        )}
      </div>
    </>
  );
}
