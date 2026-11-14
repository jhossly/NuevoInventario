import { useState, type Dispatch, type ReactNode, type SetStateAction } from 'react';
import { CircleCheck, PackagePlus } from 'lucide-react';
import { unidadCorta, type Producto } from '@/modules/catalogo/api';
import { leerDecimal } from '@/shared/decimal';
import { formatearCantidad, formatearDinero } from '@/shared/formato';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, Boton, Campo, Casilla, Selector } from '@/shared/ui';

/**
 * Una línea de compra como se escribe en «Nueva compra» y en «¿Cuánto gano?»
 * (D-068): igual para un producto que ya existe y para uno que aún no.
 */
export interface ItemCompra {
  local: string;
  /** El producto que ya existe; sin él, se crea al registrar la compra (D-067). */
  productoId?: string;
  nombre: string;
  /** Unidades que trae cada bulto. */
  factor: string;
  /** Bultos. */
  cantidad: string;
  /** Precio de un bulto, como viene en la factura. */
  costo: string;
  descuento: string;
  /** IVA de esta línea cuando no es el de la factura. */
  tarifa?: string;
  /** Precio por unidad al que se venderá un producto nuevo; puede quedar vacío. */
  precio: string;
}

/** Lo que vale para toda la factura. */
export interface OpcionesCompra {
  /** IVA de la factura: el de cada línea salvo que se cambie. */
  iva: string;
  /** Los precios de la factura ya traen el IVA: se separa al calcular. */
  conIva: boolean;
  /** Total de la factura, para comparar con lo escrito. */
  totalFactura: string;
}

export const OPCIONES_INICIALES: OpcionesCompra = { iva: '15', conIva: false, totalFactura: '' };

export type ErroresItem = Partial<Record<'nombre' | 'factor' | 'cantidad' | 'costo' | 'descuento' | 'precio', string>>;

/** Tarifas que se pueden elegir en una compra hoy. */
const TARIFAS = ['0', '5', '15'];

export function itemVacio(): ItemCompra {
  return { local: nuevaClave(), nombre: '', factor: '1', cantidad: '', costo: '', descuento: '', precio: '' };
}

export function tarifaDe(item: ItemCompra, opciones: OpcionesCompra): string {
  return item.tarifa ?? opciones.iva;
}

/** Quita el IVA de un precio que lo trae, con 6 decimales. */
function sinIva(valor: string, tarifa: string, decimales: number): string {
  return (Number(valor) / (1 + Number(tarifa) / 100)).toFixed(decimales);
}

/**
 * Las líneas para simular_compra o registrar_compra_con_nuevos, o null si
 * algo falta. Con «precios con IVA», costo y descuento se pasan sin IVA.
 */
export function prepararItems(items: ItemCompra[], opciones: OpcionesCompra) {
  const validados = items.map((it) => {
    const errores: ErroresItem = {};
    const factor = leerDecimal(it.factor, { decimales: 3, permitirCero: false });
    const cantidad = leerDecimal(it.cantidad, { decimales: 3, permitirCero: false });
    const costo = leerDecimal(it.costo, { decimales: 6 });
    const descuento =
      it.descuento.trim() === '' ? ({ ok: true, valor: '0' } as const) : leerDecimal(it.descuento, { decimales: 2 });
    const precio =
      it.productoId || it.precio.trim() === '' ? ({ ok: true, valor: '' } as const) : leerDecimal(it.precio, { decimales: 2 });
    if (!it.productoId && it.nombre.trim() === '') errores.nombre = 'Escribe el nombre';
    if (!factor.ok) errores.factor = factor.mensaje;
    if (!cantidad.ok) errores.cantidad = cantidad.mensaje;
    if (!costo.ok) errores.costo = costo.mensaje;
    if (!descuento.ok) errores.descuento = descuento.mensaje;
    if (!precio.ok) errores.precio = precio.mensaje;
    if (Object.keys(errores).length > 0 || !factor.ok || !cantidad.ok || !costo.ok || !descuento.ok || !precio.ok) {
      return { errores, linea: null };
    }
    const tarifa = tarifaDe(it, opciones);
    const comunes = {
      cantidad: cantidad.valor,
      costo_unitario: opciones.conIva ? sinIva(costo.valor, tarifa, 6) : costo.valor,
      descuento: opciones.conIva ? sinIva(descuento.valor, tarifa, 2) : descuento.valor,
      tarifa_iva: tarifa,
    };
    const linea = it.productoId
      ? { producto_id: it.productoId, factor: factor.valor, ...comunes }
      : { nuevo: { nombre: it.nombre.trim(), factor: factor.valor, precio_venta: precio.valor }, ...comunes };
    return { errores, linea: linea as object };
  });
  const listas = items.length > 0 && validados.every((v) => v.linea !== null);
  return { validados, lineas: listas ? validados.map((v) => v.linea as object) : null };
}

/** Compara sin tildes ni mayúsculas. */
function normalizar(texto: string): string {
  return texto.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
}

/** Compara el total escrito de la factura con el calculado. */
function ComparaTotal({ opciones, total }: { opciones: OpcionesCompra; total?: string }) {
  const escrito = leerDecimal(opciones.totalFactura, { decimales: 2 });
  if (opciones.totalFactura.trim() === '' || !escrito.ok || total === undefined) return null;
  const diferencia = Number(total) - Number(escrito.valor);
  // Hasta 5 centavos es redondeo (D-056).
  if (Math.abs(diferencia) <= 0.05) {
    return (
      <p className="flex items-center gap-1 text-sm font-medium text-emerald-800">
        <CircleCheck className="size-4" aria-hidden />
        Coincide con el total de la factura ({formatearDinero(escrito.valor)}).
      </p>
    );
  }
  return (
    <Aviso>
      La factura dice {formatearDinero(escrito.valor)} y con lo que escribiste da {formatearDinero(total)} (
      {diferencia > 0 ? 'sobran' : 'faltan'} {formatearDinero(Math.abs(diferencia).toFixed(2))}). Revisa bultos y costos
      {opciones.conIva
        ? '.'
        : '. Si al sumar los precios de la factura te da el total, marca «Los precios ya incluyen IVA».'}
    </Aviso>
  );
}

/**
 * Las líneas de una compra (D-068): el nombre busca entre los productos que ya
 * hay; si no se elige ninguno, queda como nuevo. Arriba, lo que vale para toda
 * la factura: su IVA, si los precios ya lo traen y su total para comparar.
 */
export function EditorCompra({
  productos,
  items,
  setItems,
  opciones,
  setOpciones,
  validados,
  mostrarErrores,
  lineaConError,
  totalCalculado,
  etiquetaPrecio,
  debajo,
}: {
  productos: Producto[];
  items: ItemCompra[];
  setItems: Dispatch<SetStateAction<ItemCompra[]>>;
  opciones: OpcionesCompra;
  setOpciones: Dispatch<SetStateAction<OpcionesCompra>>;
  validados: { errores: ErroresItem }[];
  mostrarErrores: boolean;
  /** Índice desde 0 de la línea que la base rechazó, o -1. */
  lineaConError: number;
  totalCalculado?: string;
  etiquetaPrecio: string;
  debajo?: (item: ItemCompra, indice: number) => ReactNode;
}) {
  const [enfocado, setEnfocado] = useState<string | null>(null);
  const cambiar = (indice: number, cambios: Partial<ItemCompra>) =>
    setItems((xs) => xs.map((x, i) => (i === indice ? { ...x, ...cambios } : x)));
  const porId = new Map(productos.map((p) => [p.id, p]));

  const parecidos = (nombre: string) => {
    const texto = normalizar(nombre.trim());
    if (texto.length < 2) return [];
    return productos
      .filter((p) => p.activo && normalizar(p.nombre).includes(texto))
      .flatMap((p) => p.presentaciones.filter((r) => r.activo && r.se_compra).map((r) => ({ producto: p, presentacion: r })))
      .slice(0, 8);
  };

  return (
    <>
      <div className="mb-4 grid gap-3 rounded-lg bg-gray-50 p-3 sm:grid-cols-3">
        <Selector
          etiqueta="IVA de la factura"
          value={opciones.iva}
          onChange={(e) => {
            const iva = e.target.value;
            setOpciones((o) => ({ ...o, iva }));
            // Cambiar el IVA de la factura lo aplica a todas las líneas.
            setItems((xs) => xs.map(({ tarifa: _quitada, ...x }) => x));
          }}
        >
          {TARIFAS.map((t) => (
            <option key={t} value={t}>
              {t} %
            </option>
          ))}
        </Selector>
        <Campo
          etiqueta="Total de la factura (opcional)"
          inputMode="decimal"
          placeholder="Para comparar"
          value={opciones.totalFactura}
          onChange={(e) => {
            const totalFactura = e.target.value;
            setOpciones((o) => ({ ...o, totalFactura }));
          }}
        />
        <div className="flex flex-col justify-end pb-1">
          <Casilla
            etiqueta="Los precios ya incluyen IVA"
            checked={opciones.conIva}
            onChange={(e) => {
              const conIva = e.target.checked;
              setOpciones((o) => ({ ...o, conIva }));
            }}
          />
        </div>
        <p className="text-xs text-gray-500 sm:col-span-3">
          Marca «Los precios ya incluyen IVA» si al sumar los precios de la factura te da el total a pagar: así el
          IVA no se cuenta dos veces.
        </p>
      </div>

      <ol className="flex flex-col gap-3">
        {items.map((it, i) => {
          const errores = mostrarErrores ? (validados[i]?.errores ?? {}) : {};
          const producto = it.productoId ? porId.get(it.productoId) : undefined;
          const opcionesNombre = enfocado === it.local && !it.productoId ? parecidos(it.nombre) : [];
          const tarifa = tarifaDe(it, opciones);
          return (
            <li
              key={it.local}
              className={`rounded-lg border p-3 ${lineaConError === i ? 'border-red-400 bg-red-50' : 'border-gray-200'}`}
            >
              <div className="mb-2 flex items-end gap-2">
                <div className="relative flex-1">
                  {producto ? (
                    <div>
                      <p className="text-sm font-medium text-gray-700">Producto</p>
                      <p className="flex min-h-11 flex-wrap items-center gap-2">
                        <span className="font-medium">{producto.nombre}</span>
                        <span className="rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-800">
                          Ya lo tienes
                        </span>
                        <button
                          type="button"
                          className="text-sm text-emerald-800 underline"
                          onClick={() => cambiar(i, { productoId: undefined })}
                        >
                          Cambiar
                        </button>
                      </p>
                    </div>
                  ) : (
                    <>
                      <Campo
                        etiqueta="Producto"
                        placeholder="Escribe el nombre: si ya lo tienes, aparece"
                        autoComplete="off"
                        value={it.nombre}
                        onFocus={() => setEnfocado(it.local)}
                        // Deja tiempo al toque en una sugerencia antes de cerrarlas.
                        onBlur={() => setTimeout(() => setEnfocado((e) => (e === it.local ? null : e)), 150)}
                        onChange={(e) => cambiar(i, { nombre: e.target.value })}
                        error={errores.nombre}
                      />
                      {it.nombre.trim() !== '' && opcionesNombre.length === 0 && (
                        <p className="mt-1 text-xs text-amber-800">Nuevo: se crea al registrar la compra.</p>
                      )}
                      {opcionesNombre.length > 0 && (
                        <ul className="absolute inset-x-0 top-full z-20 mt-1 divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white shadow-lg">
                          <li className="px-3 py-1 text-xs text-gray-500">Ya lo tienes: elígelo para usar ese producto</li>
                          {opcionesNombre.map(({ producto: p, presentacion: r }) => (
                            <li key={r.id}>
                              <button
                                type="button"
                                onMouseDown={(e) => e.preventDefault()}
                                onClick={() => {
                                  setEnfocado(null);
                                  cambiar(i, { productoId: p.id, nombre: p.nombre, factor: String(Number(r.factor)) });
                                }}
                                className="flex min-h-11 w-full items-center justify-between px-3 text-left hover:bg-gray-50"
                              >
                                <span>
                                  {p.nombre} — {r.nombre}
                                </span>
                                <span className="text-sm text-gray-500">
                                  {formatearCantidad(r.factor)} {unidadCorta(p.unidad_base)}
                                </span>
                              </button>
                            </li>
                          ))}
                        </ul>
                      )}
                    </>
                  )}
                </div>
                <Boton
                  variante="secundario"
                  aria-label={`Quitar ${it.nombre || 'línea'}`}
                  onClick={() => setItems((xs) => xs.filter((_, j) => j !== i))}
                >
                  ✕
                </Boton>
              </div>
              <div className={`grid grid-cols-2 gap-2 ${producto ? 'sm:grid-cols-5' : 'sm:grid-cols-6'}`}>
                <Campo
                  etiqueta={producto ? `${unidadCorta(producto.unidad_base)} por bulto` : 'Unidades por bulto'}
                  inputMode="decimal"
                  value={it.factor}
                  onChange={(e) => cambiar(i, { factor: e.target.value })}
                  error={errores.factor}
                />
                <Campo
                  etiqueta="Bultos"
                  inputMode="decimal"
                  value={it.cantidad}
                  onChange={(e) => cambiar(i, { cantidad: e.target.value })}
                  error={errores.cantidad}
                />
                <Campo
                  etiqueta={opciones.conIva ? 'Costo del bulto (con IVA)' : 'Costo del bulto'}
                  inputMode="decimal"
                  value={it.costo}
                  onChange={(e) => cambiar(i, { costo: e.target.value })}
                  error={errores.costo}
                />
                <Campo
                  etiqueta="Descuento $"
                  inputMode="decimal"
                  placeholder="0"
                  value={it.descuento}
                  onChange={(e) => cambiar(i, { descuento: e.target.value })}
                  error={errores.descuento}
                />
                <Selector
                  etiqueta="IVA"
                  value={tarifa}
                  onChange={(e) => cambiar(i, { tarifa: e.target.value === opciones.iva ? undefined : e.target.value })}
                >
                  {TARIFAS.map((t) => (
                    <option key={t} value={t}>
                      {t} %{t === opciones.iva ? ' (factura)' : ''}
                    </option>
                  ))}
                </Selector>
                {!producto && (
                  <Campo
                    etiqueta={etiquetaPrecio}
                    inputMode="decimal"
                    placeholder="Opcional"
                    value={it.precio}
                    onChange={(e) => cambiar(i, { precio: e.target.value })}
                    error={errores.precio}
                  />
                )}
              </div>
              {debajo?.(it, i)}
            </li>
          );
        })}
      </ol>

      <div className="mt-3 flex flex-col gap-2">
        <div>
          <Boton variante="secundario" icono={PackagePlus} onClick={() => setItems((xs) => [...xs, itemVacio()])}>
            Agregar producto
          </Boton>
        </div>
        <ComparaTotal opciones={opciones} total={totalCalculado} />
      </div>
    </>
  );
}
