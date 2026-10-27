import { useState } from 'react';
import { useContexto } from '@/modules/sesion/sesion';
import { leerDecimal } from '@/shared/decimal';
import { formatearCantidad, formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Cargando, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import {
  COMPROBANTES,
  MEDIOS,
  formatearMomento,
  useAnularVenta,
  useCostosVenta,
  useDevoluciones,
  useRegistrarDevolucion,
  useSolicitarAnulacion,
  useVenta,
  type Devolucion,
  type Venta,
} from './api';

export function DetalleVenta({ id }: { id: string }) {
  const venta = useVenta(id);
  const volver = enlace({ nombre: 'ventas' });

  if (venta.isPending) return <Cargando />;
  if (venta.error) return <AvisoError error={venta.error} />;
  if (!venta.data) {
    return (
      <>
        <Encabezado titulo="Venta" volver={volver} />
        <Tarjeta>La venta no existe o no la puedes ver.</Tarjeta>
      </>
    );
  }
  return <Detalle venta={venta.data} volver={volver} />;
}

function Detalle({ venta, volver }: { venta: Venta; volver: string }) {
  const contexto = useContexto();
  const esDueno = contexto.rol === 'DUENO';
  const anulada = venta.estado === 'ANULADA';
  const costos = useCostosVenta(venta.id, contexto.ve_costos);
  const devoluciones = useDevoluciones(venta.id, esDueno);
  const [accion, setAccion] = useState<'anular' | 'devolver' | 'solicitar' | null>(null);

  const devuelto = (lineaId: string) =>
    (devoluciones.data ?? [])
      .flatMap((d) => d.devolucion_detalles)
      .filter((d) => d.venta_detalle_id === lineaId)
      .reduce((s, d) => s + Number(d.cantidad), 0);

  return (
    <>
      <Encabezado titulo={venta.clientes?.nombre ?? 'Consumidor final'} volver={volver} />
      {anulada && <Aviso>Venta anulada: {venta.motivo_anulacion}</Aviso>}
      {!anulada && venta.solicitud_anulacion && (
        <Aviso tipo="info">Se pidió anular esta venta: {venta.solicitud_anulacion}</Aviso>
      )}

      <Tarjeta className="my-4">
        <dl className="grid grid-cols-2 gap-y-1 text-sm">
          <dt className="text-gray-500">Fecha</dt>
          <dd>{formatearMomento(venta.creado_en)}</dd>
          <dt className="text-gray-500">Comprobante</dt>
          <dd>{COMPROBANTES[venta.tipo_comprobante]}</dd>
          <dt className="text-gray-500">Pago</dt>
          <dd>
            {venta.venta_pagos
              .map((p) => `${MEDIOS[p.medio as keyof typeof MEDIOS] ?? p.medio} ${formatearDinero(p.monto)}`)
              .join(' + ') || '—'}
          </dd>
        </dl>
      </Tarjeta>

      <Tarjeta className="mb-4">
        <ol className="divide-y divide-gray-100">
          {venta.venta_detalles.map((d) => {
            const costo = costos.data?.lineas.find((c) => c.orden === d.orden);
            const yaDevuelto = devuelto(d.id);
            return (
              <li key={d.id} className="py-2">
                <div className="flex justify-between gap-2">
                  <p className="font-medium">
                    {d.productos.nombre}
                    {Number(d.presentaciones.factor) !== 1 && ` — ${d.presentaciones.nombre}`}
                  </p>
                  <p className="tabular-nums">{formatearDinero(d.total)}</p>
                </div>
                <p className="text-sm text-gray-500">
                  {formatearCantidad(d.cantidad)} × {formatearDinero(d.precio_unitario)}
                  {Number(d.descuento) > 0 && ` · desc. ${formatearDinero(d.descuento)} sin IVA`}
                  {Number(d.tarifa_iva) > 0 && ` · IVA ${formatearDinero(d.iva)}`}
                  {costo && ` · costo ${formatearCosto(costo.costo_total)}`}
                </p>
                {yaDevuelto > 0 && (
                  <p className="text-sm text-amber-700">Devuelto: {formatearCantidad(yaDevuelto.toFixed(3))}</p>
                )}
              </li>
            );
          })}
        </ol>
        <dl className="mt-3 grid grid-cols-2 gap-x-4 border-t border-gray-200 pt-3 text-sm tabular-nums">
          <dt className="text-gray-600">Subtotal</dt>
          <dd className="text-right">{formatearDinero(venta.subtotal)}</dd>
          {Number(venta.descuento) > 0 && (
            <>
              <dt className="text-gray-600">Descuento</dt>
              <dd className="text-right">−{formatearDinero(venta.descuento)}</dd>
            </>
          )}
          <dt className="text-gray-600">IVA</dt>
          <dd className="text-right">{formatearDinero(venta.iva)}</dd>
          <dt className="font-semibold">Total</dt>
          <dd className={`text-right font-semibold ${anulada ? 'line-through' : ''}`}>{formatearDinero(venta.total)}</dd>
          {costos.data && (
            <>
              <dt className="text-gray-600">Costo</dt>
              <dd className="text-right">{formatearCosto(costos.data.costo_total)}</dd>
              <dt className="text-gray-600">Utilidad (sin IVA)</dt>
              <dd className="text-right">{formatearCosto(costos.data.utilidad)}</dd>
            </>
          )}
        </dl>
      </Tarjeta>

      {esDueno && (devoluciones.data?.length ?? 0) > 0 && (
        <Tarjeta className="mb-4">
          <h2 className="mb-2 font-semibold">Devoluciones</h2>
          <ul className="text-sm">
            {devoluciones.data?.map((d: Devolucion) => (
              <li key={d.id} className="flex justify-between py-1">
                <span>
                  {d.fecha} · {d.motivo}
                </span>
                <span className="tabular-nums">{formatearDinero(d.total)}</span>
              </li>
            ))}
          </ul>
        </Tarjeta>
      )}

      {!anulada && accion === null && (
        <div className="flex flex-wrap gap-2">
          {esDueno ? (
            <>
              <Boton variante="secundario" onClick={() => setAccion('devolver')}>
                Devolución…
              </Boton>
              {(devoluciones.data?.length ?? 0) === 0 && (
                <Boton variante="secundario" onClick={() => setAccion('anular')}>
                  Anular venta…
                </Boton>
              )}
            </>
          ) : (
            !venta.solicitud_anulacion && (
              <Boton variante="secundario" onClick={() => setAccion('solicitar')}>
                Pedir anulación…
              </Boton>
            )
          )}
        </div>
      )}
      {accion === 'anular' && <Anular venta={venta} alTerminar={() => setAccion(null)} />}
      {accion === 'solicitar' && <Solicitar venta={venta} alTerminar={() => setAccion(null)} />}
      {accion === 'devolver' && <Devolver venta={venta} devuelto={devuelto} alTerminar={() => setAccion(null)} />}
    </>
  );
}

function PedirMotivo({
  titulo,
  ayuda,
  boton,
  pendiente,
  error,
  alConfirmar,
  alCancelar,
}: {
  titulo: string;
  ayuda: string;
  boton: string;
  pendiente: boolean;
  error: unknown;
  alConfirmar: (motivo: string) => void;
  alCancelar: () => void;
}) {
  const [motivo, setMotivo] = useState('');
  const [falta, setFalta] = useState(false);
  return (
    <Tarjeta>
      <h2 className="mb-1 font-semibold">{titulo}</h2>
      <p className="mb-3 text-sm text-gray-600">{ayuda}</p>
      <Campo etiqueta="Motivo" value={motivo} onChange={(e) => setMotivo(e.target.value)} error={falta ? 'Escribe el motivo' : null} />
      <div className="mt-3">
        <AvisoError error={error} />
      </div>
      <div className="mt-3 flex gap-2">
        <Boton
          variante="peligro"
          disabled={pendiente}
          onClick={() => {
            setFalta(motivo.trim() === '');
            if (motivo.trim() !== '') alConfirmar(motivo.trim());
          }}
        >
          {pendiente ? 'Guardando…' : boton}
        </Boton>
        <Boton variante="secundario" onClick={alCancelar}>
          Cancelar
        </Boton>
      </div>
    </Tarjeta>
  );
}

function Anular({ venta, alTerminar }: { venta: Venta; alTerminar: () => void }) {
  const anular = useAnularVenta();
  return (
    <PedirMotivo
      titulo="Anular venta"
      ayuda="Todo lo vendido vuelve al inventario al costo con que salió. La venta queda anulada con tu nombre y el motivo."
      boton="Confirmar anulación"
      pendiente={anular.isPending}
      error={anular.error}
      alConfirmar={(motivo) => anular.mutate({ id: venta.id, motivo }, { onSuccess: alTerminar })}
      alCancelar={alTerminar}
    />
  );
}

function Solicitar({ venta, alTerminar }: { venta: Venta; alTerminar: () => void }) {
  const solicitar = useSolicitarAnulacion();
  return (
    <PedirMotivo
      titulo="Pedir anulación"
      ayuda="El Dueño verá tu pedido y decidirá si anula la venta."
      boton="Enviar pedido"
      pendiente={solicitar.isPending}
      error={solicitar.error}
      alConfirmar={(motivo) => solicitar.mutate({ id: venta.id, motivo }, { onSuccess: alTerminar })}
      alCancelar={alTerminar}
    />
  );
}

function Devolver({
  venta,
  devuelto,
  alTerminar,
}: {
  venta: Venta;
  devuelto: (lineaId: string) => number;
  alTerminar: () => void;
}) {
  const registrar = useRegistrarDevolucion();
  const unaVez = useUnSoloEnvio();
  const [cantidades, setCantidades] = useState<Record<string, string>>({});
  const [motivo, setMotivo] = useState('');
  const [forma, setForma] = useState<'EFECTIVO' | 'ABONO_FIADO'>('EFECTIVO');
  const [errores, setErrores] = useState<Record<string, string>>({});
  const [clave] = useState(nuevaClave);

  const enviar = () => {
    const nuevos: Record<string, string> = {};
    const lineas: { venta_detalle_id: string; cantidad: string }[] = [];
    for (const [id, texto] of Object.entries(cantidades)) {
      if (texto.trim() === '') continue;
      const leida = leerDecimal(texto, { decimales: 3, permitirCero: false });
      if (leida.ok) lineas.push({ venta_detalle_id: id, cantidad: leida.valor });
      else nuevos[id] = leida.mensaje;
    }
    if (lineas.length === 0 && Object.keys(nuevos).length === 0) nuevos.general = 'Indica cuánto se devuelve';
    if (motivo.trim() === '') nuevos.motivo = 'Escribe el motivo';
    setErrores(nuevos);
    if (Object.keys(nuevos).length > 0) return;
    unaVez((terminar) =>
      registrar.mutate({ ventaId: venta.id, lineas, motivo: motivo.trim(), forma, clave }, { onSuccess: alTerminar, onSettled: terminar }),
    );
  };

  return (
    <Tarjeta>
      <h2 className="mb-1 font-semibold">Devolución</h2>
      <p className="mb-3 text-sm text-gray-600">
        Lo devuelto vuelve al inventario al costo con que salió. El efectivo sale de la caja abierta.
      </p>
      {venta.cliente_id && (
        <div className="mb-3">
          <Selector etiqueta="Reintegro" value={forma} onChange={(e) => setForma(e.target.value as typeof forma)}>
            <option value="EFECTIVO">En efectivo</option>
            <option value="ABONO_FIADO">Descontar de lo que debe (fiado)</option>
          </Selector>
        </div>
      )}
      <ul className="flex flex-col gap-2">
        {venta.venta_detalles.map((d) => {
          const queda = Number(d.cantidad) - devuelto(d.id);
          if (queda <= 0) return null;
          return (
            <li key={d.id} className="flex items-end gap-3">
              <p className="flex-1 text-sm">
                {d.productos.nombre}
                {Number(d.presentaciones.factor) !== 1 && ` — ${d.presentaciones.nombre}`}
                <span className="block text-gray-500">Se puede devolver hasta {formatearCantidad(queda.toFixed(3))}</span>
              </p>
              <div className="w-24">
                <Campo
                  etiqueta="Devolver"
                  inputMode="decimal"
                  placeholder="0"
                  value={cantidades[d.id] ?? ''}
                  onChange={(e) => setCantidades((c) => ({ ...c, [d.id]: e.target.value }))}
                  error={errores[d.id]}
                />
              </div>
            </li>
          );
        })}
      </ul>
      <div className="mt-3">
        <Campo etiqueta="Motivo" value={motivo} onChange={(e) => setMotivo(e.target.value)} error={errores.motivo} />
      </div>
      <div className="mt-3 flex flex-col gap-2">
        {errores.general && <Aviso>{errores.general}</Aviso>}
        <AvisoError error={registrar.error} />
      </div>
      <div className="mt-3 flex gap-2">
        <Boton onClick={enviar} disabled={registrar.isPending}>
          {registrar.isPending ? 'Guardando…' : 'Registrar devolución'}
        </Boton>
        <Boton variante="secundario" onClick={alTerminar}>
          Cancelar
        </Boton>
      </div>
    </Tarjeta>
  );
}
