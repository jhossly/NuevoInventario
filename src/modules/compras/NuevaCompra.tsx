import { useMemo, useState } from 'react';
import { UNIDADES, useProductos, type Presentacion, type Producto } from '@/modules/catalogo/api';
import { leerDecimal } from '@/shared/decimal';
import { formatearCantidad, formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace, navegar } from '@/shared/ruta';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Cargando, Casilla, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import { ErrorDeNegocio } from '@/shared/rpc';
import { FormProveedor } from './Proveedores';
import { useCalculoCompra, useProveedores, useRegistrarCompra, type LineaCompra } from './api';

interface LineaEnPantalla {
  /** Solo para la key de React: la misma presentación puede repetirse. */
  local: string;
  producto: Producto;
  presentacion: Presentacion;
  cantidad: string;
  costo: string;
  descuento: string;
}

type Errores = Partial<Record<'cantidad' | 'costo' | 'descuento', string>>;

function validarLinea(l: LineaEnPantalla): { errores: Errores; linea: LineaCompra | null } {
  const errores: Errores = {};
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
    },
  };
}

function hoy(): string {
  // Fecha local del dispositivo (el Dueño está en Ecuador); la base valida de
  // nuevo con la zona horaria de la empresa.
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function NuevaCompra() {
  const productos = useProductos();
  const proveedores = useProveedores();
  const registrar = useRegistrarCompra();
  const unaVez = useUnSoloEnvio();

  const [conRespaldo, setConRespaldo] = useState(true);
  const [proveedorId, setProveedorId] = useState('');
  const [numero, setNumero] = useState('');
  const [fecha, setFecha] = useState(hoy);
  const [lineas, setLineas] = useState<LineaEnPantalla[]>([]);
  const [busqueda, setBusqueda] = useState('');
  const [nuevoProveedor, setNuevoProveedor] = useState(false);
  const [mostrarErrores, setMostrarErrores] = useState(false);
  const [errorCabecera, setErrorCabecera] = useState<string | null>(null);
  // Una clave por compra: un reintento tras un corte de red no la duplica.
  const [clave] = useState(nuevaClave);

  const validadas = lineas.map(validarLinea);
  const todasValidas = lineas.length > 0 && validadas.every((v) => v.linea !== null);
  const paraEnviar = todasValidas ? validadas.map((v) => v.linea as LineaCompra) : null;
  const calculo = useCalculoCompra(paraEnviar);

  // La base indica en qué línea está el problema (detalle.linea, desde 1).
  const lineaConError =
    calculo.error instanceof ErrorDeNegocio
      ? Number((calculo.error.detalle as { linea?: number } | null)?.linea ?? 0) - 1
      : -1;

  const opciones = useMemo(() => {
    const texto = busqueda.trim().toLowerCase();
    if (texto === '') return [];
    return (productos.data ?? [])
      .filter((p) => p.activo && p.nombre.toLowerCase().includes(texto))
      .flatMap((p) => p.presentaciones.filter((r) => r.activo && r.se_compra).map((r) => ({ producto: p, presentacion: r })))
      .slice(0, 12);
  }, [productos.data, busqueda]);

  const agregar = (producto: Producto, presentacion: Presentacion) => {
    setLineas((ls) => [...ls, { local: nuevaClave(), producto, presentacion, cantidad: '', costo: '', descuento: '' }]);
    setBusqueda('');
  };

  const cambiar = (indice: number, cambios: Partial<LineaEnPantalla>) =>
    setLineas((ls) => ls.map((l, i) => (i === indice ? { ...l, ...cambios } : l)));

  const confirmar = () => {
    setMostrarErrores(true);
    setErrorCabecera(null);
    if (conRespaldo && (proveedorId === '' || numero.trim() === '')) {
      setErrorCabecera('Con respaldo: elige el proveedor y escribe el número de la factura.');
      return;
    }
    if (!paraEnviar) {
      setErrorCabecera(lineas.length === 0 ? 'Agrega al menos un producto.' : 'Revisa las líneas marcadas.');
      return;
    }
    unaVez((terminar) => registrar.mutate(
      {
        proveedorId: proveedorId || null,
        conRespaldo,
        numeroDocumento: numero.trim() || null,
        fecha: fecha || null,
        lineas: paraEnviar,
        clave,
      },
      { onSuccess: (r) => navegar({ nombre: 'compra', id: r.compra_id }), onSettled: terminar },
    ));
  };

  if (productos.isPending || proveedores.isPending) return <Cargando />;

  return (
    <>
      <Encabezado titulo="Nueva compra" volver={enlace({ nombre: 'compras' })} />

      <Tarjeta className="mb-4">
        <div className="flex flex-col gap-4">
          <Casilla
            etiqueta="Con respaldo (factura o nota de venta del proveedor)"
            checked={conRespaldo}
            onChange={(e) => setConRespaldo(e.target.checked)}
          />
          {!conRespaldo && (
            <Aviso tipo="info">Quedará marcada «sin respaldo – requiere revisión» para el contador.</Aviso>
          )}

          {nuevoProveedor ? (
            <div className="rounded-lg bg-gray-50 p-3">
              <p className="mb-2 font-medium">Nuevo proveedor</p>
              <FormProveedor
                alTerminar={(id) => {
                  if (id) setProveedorId(id);
                  setNuevoProveedor(false);
                }}
              />
            </div>
          ) : (
            <div className="flex items-end gap-2">
              <div className="flex-1">
                <Selector etiqueta="Proveedor" value={proveedorId} onChange={(e) => setProveedorId(e.target.value)}>
                  <option value="">{conRespaldo ? 'Elige un proveedor' : 'Sin proveedor'}</option>
                  {proveedores.data
                    ?.filter((p) => p.activo)
                    .map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.nombre}
                      </option>
                    ))}
                </Selector>
              </div>
              <Boton variante="secundario" onClick={() => setNuevoProveedor(true)}>
                Nuevo
              </Boton>
            </div>
          )}

          <div className="grid grid-cols-2 gap-3">
            <Campo
              etiqueta="N.º de documento"
              placeholder="001-001-000000123"
              value={numero}
              onChange={(e) => setNumero(e.target.value)}
              autoComplete="off"
            />
            <Campo etiqueta="Fecha" type="date" max={hoy()} value={fecha} onChange={(e) => setFecha(e.target.value)} />
          </div>
        </div>
      </Tarjeta>

      <Tarjeta className="mb-4">
        <h2 className="mb-2 font-semibold">Productos</h2>
        <p className="mb-3 text-sm text-gray-500">Costos por presentación, sin IVA, como vienen en la factura.</p>

        <ol className="flex flex-col gap-3">
          {lineas.map((l, i) => {
            const errores = mostrarErrores ? (validadas[i]?.errores ?? {}) : {};
            const calculada = calculo.data?.lineas[i];
            const unidad = UNIDADES[l.producto.unidad_base];
            return (
              <li
                key={l.local}
                className={`rounded-lg border p-3 ${lineaConError === i ? 'border-red-400 bg-red-50' : 'border-gray-200'}`}
              >
                <div className="mb-2 flex items-start gap-2">
                  <p className="flex-1 font-medium">
                    {l.producto.nombre} — {l.presentacion.nombre}
                    <span className="block text-sm font-normal text-gray-500">
                      {formatearCantidad(l.presentacion.factor)} {unidad} · IVA {Number(l.producto.tarifa_iva)} %
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
                <div className="grid grid-cols-3 gap-2">
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
                </div>
                {calculada && todasValidas && (
                  <p className="mt-2 text-sm text-gray-600">
                    {formatearDinero(calculada.subtotal)} + IVA {formatearDinero(calculada.iva)} · entran{' '}
                    {formatearCantidad(calculada.cantidad_base)} {unidad} a {formatearCosto(calculada.costo_unitario_base)}
                  </p>
                )}
              </li>
            );
          })}
        </ol>

        <div className="mt-3">
          <input
            type="search"
            placeholder="Agregar producto: escribe el nombre"
            aria-label="Buscar producto para agregar"
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            className="min-h-11 w-full rounded-lg border border-gray-300 bg-white px-3 text-base"
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
                      {formatearCantidad(presentacion.factor)} {UNIDADES[producto.unidad_base]}
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
      </Tarjeta>

      <div className="sticky bottom-0 -mx-4 flex flex-col gap-2 border-t border-gray-200 bg-gray-50 p-4">
        {calculo.data && todasValidas && (
          <dl className="grid grid-cols-2 gap-x-4 text-sm tabular-nums">
            <dt className="text-gray-600">Subtotal</dt>
            <dd className="text-right">{formatearDinero(calculo.data.subtotal)}</dd>
            {Number(calculo.data.descuento) > 0 && (
              <>
                <dt className="text-gray-600">Descuento</dt>
                <dd className="text-right">−{formatearDinero(calculo.data.descuento)}</dd>
              </>
            )}
            <dt className="text-gray-600">IVA</dt>
            <dd className="text-right">{formatearDinero(calculo.data.iva)}</dd>
            <dt className="font-semibold">Total</dt>
            <dd className="text-right font-semibold">{formatearDinero(calculo.data.total)}</dd>
          </dl>
        )}
        {todasValidas && <AvisoError error={calculo.error} />}
        {errorCabecera && <Aviso>{errorCabecera}</Aviso>}
        <AvisoError error={registrar.error} />
        <Boton onClick={confirmar} disabled={registrar.isPending}>
          {registrar.isPending ? 'Registrando…' : 'Registrar compra'}
        </Boton>
      </div>
    </>
  );
}
