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
import { useCalculoCompra, useProveedores, useRegistrarCompra, useSimularCompra } from './api';
import {
  aLineaExistente,
  EditorLineas,
  EditorNuevos,
  lineasParaEnviar,
  validarNuevo,
  type LineaEnPantalla,
  type NuevoEnPantalla,
} from './LineasCompra';

function hoy(): string {
  // Fecha local del dispositivo (el Dueño está en Ecuador); la base valida de
  // nuevo con la zona horaria de la empresa.
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** Nombre del borrador de líneas: «¿Cuánto gano?» lo llena al pasar a compra. */
export const BORRADOR_LINEAS_COMPRA = 'compra:lineas';
/** Productos que aún no existen: se crean al registrar (D-067). */
export const BORRADOR_NUEVOS_COMPRA = 'compra:nuevos';

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
  const [nuevos, setNuevos, borrar7] = useBorrador<NuevoEnPantalla[]>(BORRADOR_NUEVOS_COMPRA, []);
  const [nuevoProveedor, setNuevoProveedor] = useState(false);
  const [mostrarErrores, setMostrarErrores] = useState(false);
  const [errorCabecera, setErrorCabecera] = useState<string | null>(null);
  // Una clave por compra: un reintento tras un corte de red no la duplica.
  const [clave, , borrar6] = useBorrador('compra:clave', nuevaClave);
  const borrarTodo = () => [borrar1, borrar2, borrar3, borrar4, borrar5, borrar6, borrar7].forEach((b) => b());

  const { validadas, todasValidas, paraEnviar } = lineasParaEnviar(lineas);
  const nuevosValidados = nuevos.map(validarNuevo);
  const hayAlgo = lineas.length + nuevos.length > 0;
  const todoEnviable =
    hayAlgo && (lineas.length === 0 || todasValidas) && nuevosValidados.every((v) => v.linea !== null)
      ? [...(paraEnviar ?? []), ...nuevosValidados.map((v) => v.linea as object)]
      : null;
  const calculo = useCalculoCompra(nuevos.length === 0 ? paraEnviar : null);
  // Con productos nuevos los totales salen de la simulación, que los entiende.
  const simulacion = useSimularCompra(nuevos.length > 0 ? todoEnviable : null, '0.2');
  const totales = nuevos.length > 0 ? (todoEnviable ? simulacion.data?.compra : undefined) : todasValidas ? calculo.data : undefined;
  const errorCalculo = nuevos.length > 0 ? simulacion.error : calculo.error;

  // La base indica en qué línea está el problema (detalle.linea, desde 1),
  // contando primero los productos que ya existen y luego los nuevos.
  const conLinea = [registrar.error, errorCalculo].find((e) => e instanceof ErrorDeNegocio) as ErrorDeNegocio | undefined;
  const lineaConError = conLinea ? Number((conLinea.detalle as { linea?: number } | null)?.linea ?? 0) - 1 : -1;

  const confirmar = () => {
    setMostrarErrores(true);
    setErrorCabecera(null);
    if (conRespaldo && (proveedorId === '' || numero.trim() === '')) {
      setErrorCabecera('Con respaldo: elige el proveedor y escribe el número de la factura.');
      return;
    }
    if (!todoEnviable) {
      setErrorCabecera(hayAlgo ? 'Revisa las líneas marcadas.' : 'Agrega al menos un producto.');
      return;
    }
    unaVez((terminar) => registrar.mutate(
      {
        proveedorId: proveedorId || null,
        conRespaldo,
        numeroDocumento: numero.trim() || null,
        fecha: fecha || null,
        lineas: todoEnviable,
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
            const calculada = nuevos.length === 0 ? calculo.data?.lineas[i] : undefined;
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

      <Tarjeta className="mb-4">
        <h2 className="mb-1 font-semibold">Productos que aún no tienes</h2>
        <p className="mb-3 text-sm text-gray-500">
          Escribe el nombre: si ya lo tienes aparece para elegirlo; si no, se crea al registrar la compra y queda en
          «Productos» marcado «por completar».
        </p>
        <EditorNuevos
          productos={productos.data ?? []}
          nuevos={nuevos}
          setNuevos={setNuevos}
          alElegirExistente={(j, producto, presentacion) => {
            const n = nuevos[j];
            if (!n) return;
            setNuevos((ns) => ns.filter((_, i) => i !== j));
            setLineas((ls) => [...ls, aLineaExistente(n, producto, presentacion)]);
          }}
          validados={nuevosValidados}
          mostrarErrores={mostrarErrores}
          lineaConError={lineaConError}
          desfase={lineas.length}
          etiquetaPrecio="Precio de venta c/u"
        />
      </Tarjeta>

      <div className="sticky bottom-0 -mx-4 flex flex-col gap-2 border-t border-gray-200 bg-gray-50 p-4">
        {totales && (
          <dl className="grid grid-cols-2 gap-x-4 text-sm tabular-nums">
            <dt className="text-gray-600">Subtotal</dt>
            <dd className="text-right">{formatearDinero(totales.subtotal)}</dd>
            {Number(totales.descuento) > 0 && (
              <>
                <dt className="text-gray-600">Descuento</dt>
                <dd className="text-right">−{formatearDinero(totales.descuento)}</dd>
              </>
            )}
            <dt className="text-gray-600">IVA</dt>
            <dd className="text-right">{formatearDinero(totales.iva)}</dd>
            <dt className="font-semibold">Total</dt>
            <dd className="text-right font-semibold">{formatearDinero(totales.total)}</dd>
          </dl>
        )}
        {todoEnviable && <AvisoError error={errorCalculo} />}
        {errorCabecera && <Aviso>{errorCabecera}</Aviso>}
        <AvisoError error={registrar.error} />
        <Boton onClick={confirmar} disabled={registrar.isPending}>
          {registrar.isPending ? 'Registrando…' : 'Registrar compra'}
        </Boton>
      </div>
    </>
  );
}
