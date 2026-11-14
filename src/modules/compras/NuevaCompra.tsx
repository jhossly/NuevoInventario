import { useState } from 'react';
import { useBorrador } from '@/shared/borrador';
import { useProductos } from '@/modules/catalogo/api';
import { formatearCantidad, formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace, navegar } from '@/shared/ruta';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Cargando, Casilla, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import { ErrorDeNegocio } from '@/shared/rpc';
import { FormProveedor } from './Proveedores';
import { useProveedores, useRegistrarCompra, useSimularCompra } from './api';
import { EditorCompra, OPCIONES_INICIALES, prepararItems, type ItemCompra, type OpcionesCompra } from './LineasCompra';

function hoy(): string {
  // Fecha local del dispositivo (el Dueño está en Ecuador); la base valida de
  // nuevo con la zona horaria de la empresa.
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** Borradores de las líneas y opciones: «¿Cuánto gano?» los llena al pasar a compra. */
export const BORRADOR_ITEMS_COMPRA = 'compra:items';
export const BORRADOR_OPCIONES_COMPRA = 'compra:opciones';

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
  const [items, setItems, borrar5] = useBorrador<ItemCompra[]>(BORRADOR_ITEMS_COMPRA, []);
  const [opciones, setOpciones, borrar7] = useBorrador<OpcionesCompra>(BORRADOR_OPCIONES_COMPRA, OPCIONES_INICIALES);
  const [nuevoProveedor, setNuevoProveedor] = useState(false);
  const [mostrarErrores, setMostrarErrores] = useState(false);
  const [errorCabecera, setErrorCabecera] = useState<string | null>(null);
  // Una clave por compra: un reintento tras un corte de red no la duplica.
  const [clave, , borrar6] = useBorrador('compra:clave', nuevaClave);
  const borrarTodo = () => [borrar1, borrar2, borrar3, borrar4, borrar5, borrar6, borrar7].forEach((b) => b());

  const { validados, lineas } = prepararItems(items, opciones);
  // Las mismas cuentas del registro, sin guardar: totales y lo que entra por línea.
  const simulacion = useSimularCompra(lineas, '0.2');
  const datos = lineas ? simulacion.data : undefined;

  // La base indica en qué línea está el problema (detalle.linea, desde 1).
  const conLinea = [registrar.error, simulacion.error].find((e) => e instanceof ErrorDeNegocio) as
    | ErrorDeNegocio
    | undefined;
  const lineaConError = conLinea ? Number((conLinea.detalle as { linea?: number } | null)?.linea ?? 0) - 1 : -1;
  const nuevos = items.filter((it) => !it.productoId).length;

  const confirmar = () => {
    setMostrarErrores(true);
    setErrorCabecera(null);
    if (conRespaldo && (proveedorId === '' || numero.trim() === '')) {
      setErrorCabecera('Con respaldo: elige el proveedor y escribe el número de la factura.');
      return;
    }
    if (!lineas) {
      setErrorCabecera(items.length === 0 ? 'Agrega al menos un producto.' : 'Revisa las líneas marcadas.');
      return;
    }
    unaVez((terminar) => registrar.mutate(
      {
        proveedorId: proveedorId || null,
        conRespaldo,
        numeroDocumento: numero.trim() || null,
        fecha: fecha || null,
        lineas,
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
        <h2 className="mb-3 font-semibold">Productos</h2>
        <EditorCompra
          productos={productos.data ?? []}
          items={items}
          setItems={setItems}
          opciones={opciones}
          setOpciones={setOpciones}
          validados={validados}
          mostrarErrores={mostrarErrores}
          lineaConError={lineaConError}
          totalCalculado={datos?.compra.total}
          etiquetaPrecio="Precio de venta c/u"
          debajo={(_, i) => {
            const d = datos?.detalle[i];
            if (!d) return null;
            return (
              <p className="mt-2 text-sm text-gray-600">
                {formatearDinero(d.subtotal)} + IVA {formatearDinero(d.iva)} · entran {formatearCantidad(d.unidades)} a{' '}
                {formatearCosto(d.costo_unidad)} c/u
              </p>
            );
          }}
        />
        {nuevos > 0 && (
          <p className="mt-3 text-sm text-gray-600">
            {nuevos === 1 ? 'El producto nuevo se crea' : `Los ${nuevos} productos nuevos se crean`} al registrar y
            {nuevos === 1 ? ' queda' : ' quedan'} en «Productos» marcado{nuevos === 1 ? '' : 's'} «por completar».
          </p>
        )}
      </Tarjeta>

      <div className="sticky bottom-0 -mx-4 flex flex-col gap-2 border-t border-gray-200 bg-gray-50 p-4">
        {datos && (
          <dl className="grid grid-cols-2 gap-x-4 text-sm tabular-nums">
            <dt className="text-gray-600">Subtotal</dt>
            <dd className="text-right">{formatearDinero(datos.compra.subtotal)}</dd>
            {Number(datos.compra.descuento) > 0 && (
              <>
                <dt className="text-gray-600">Descuento</dt>
                <dd className="text-right">−{formatearDinero(datos.compra.descuento)}</dd>
              </>
            )}
            <dt className="text-gray-600">IVA</dt>
            <dd className="text-right">{formatearDinero(datos.compra.iva)}</dd>
            <dt className="font-semibold">Total</dt>
            <dd className="text-right font-semibold">{formatearDinero(datos.compra.total)}</dd>
          </dl>
        )}
        {lineas && <AvisoError error={simulacion.error} />}
        {errorCabecera && <Aviso>{errorCabecera}</Aviso>}
        <AvisoError error={registrar.error} />
        <Boton onClick={confirmar} disabled={registrar.isPending}>
          {registrar.isPending ? 'Registrando…' : 'Registrar compra'}
        </Boton>
      </div>
    </>
  );
}
