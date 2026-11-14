import { useState } from 'react';
import { useBorrador } from '@/shared/borrador';
import { unidadCorta, useProductos } from '@/modules/catalogo/api';
import { formatearCantidad, formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace, navegar } from '@/shared/ruta';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Cargando, Casilla, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import { ErrorDeNegocio } from '@/shared/rpc';
import { FormProveedor } from './Proveedores';
import { useCalculoCompra, useProveedores, useRegistrarCompra } from './api';
import { EditorLineas, lineasParaEnviar, type LineaEnPantalla } from './LineasCompra';

function hoy(): string {
  // Fecha local del dispositivo (el Dueño está en Ecuador); la base valida de
  // nuevo con la zona horaria de la empresa.
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** Nombre del borrador de líneas: «¿Cuánto gano?» lo llena al pasar a compra. */
export const BORRADOR_LINEAS_COMPRA = 'compra:lineas';

export function NuevaCompra() {
  const productos = useProductos();
  const proveedores = useProveedores();
  const registrar = useRegistrarCompra();
  const unaVez = useUnSoloEnvio();

  // Lo escrito queda en el aparato hasta guardar (D-062).
  const [conRespaldo, setConRespaldo, borrar1] = useBorrador('compra:respaldo', true);
  const [proveedorId, setProveedorId, borrar2] = useBorrador('compra:proveedor', '');
  const [numero, setNumero, borrar3] = useBorrador('compra:numero', '');
  const [fecha, setFecha, borrar4] = useBorrador('compra:fecha', hoy);
  const [lineas, setLineas, borrar5] = useBorrador<LineaEnPantalla[]>(BORRADOR_LINEAS_COMPRA, []);
  const [nuevoProveedor, setNuevoProveedor] = useState(false);
  const [mostrarErrores, setMostrarErrores] = useState(false);
  const [errorCabecera, setErrorCabecera] = useState<string | null>(null);
  // Una clave por compra: un reintento tras un corte de red no la duplica.
  const [clave, , borrar6] = useBorrador('compra:clave', nuevaClave);
  const borrarTodo = () => [borrar1, borrar2, borrar3, borrar4, borrar5, borrar6].forEach((b) => b());

  const { validadas, todasValidas, paraEnviar } = lineasParaEnviar(lineas);
  const calculo = useCalculoCompra(paraEnviar);

  // La base indica en qué línea está el problema (detalle.linea, desde 1).
  const lineaConError =
    calculo.error instanceof ErrorDeNegocio
      ? Number((calculo.error.detalle as { linea?: number } | null)?.linea ?? 0) - 1
      : -1;

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
      {
        onSuccess: (r) => {
          borrarTodo();
          navegar({ nombre: 'compra', id: r.compra_id });
        },
        onSettled: terminar,
      },
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
        <EditorLineas
          productos={productos.data ?? []}
          lineas={lineas}
          setLineas={setLineas}
          validadas={validadas}
          mostrarErrores={mostrarErrores}
          lineaConError={lineaConError}
          debajo={(l, i) => {
            const calculada = calculo.data?.lineas[i];
            if (!calculada || !todasValidas) return null;
            const unidad = unidadCorta(l.producto.unidad_base);
            return (
              <p className="mt-2 text-sm text-gray-600">
                {formatearDinero(calculada.subtotal)} + IVA {formatearDinero(calculada.iva)} · entran{' '}
                {formatearCantidad(calculada.cantidad_base)} {unidad} a {formatearCosto(calculada.costo_unitario_base)}
              </p>
            );
          }}
        />
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
