import { useState } from 'react';
import { useContexto } from '@/modules/sesion/sesion';
import { formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { AvisoError, Cargando, Casilla, EnlaceBoton, Encabezado, Tarjeta } from '@/shared/ui';
import { COMPROBANTES, formatearMomento, useVentas } from './api';

export function ListaVentas() {
  const esDueno = useContexto().rol === 'DUENO';
  const ventas = useVentas();
  const [soloSolicitudes, setSoloSolicitudes] = useState(false);

  const visibles = (ventas.data ?? []).filter(
    (v) => !soloSolicitudes || (v.estado === 'CONFIRMADA' && v.solicitud_anulacion !== null),
  );
  const solicitudes = (ventas.data ?? []).filter((v) => v.estado === 'CONFIRMADA' && v.solicitud_anulacion !== null).length;

  return (
    <>
      <Encabezado
        titulo={esDueno ? 'Ventas' : 'Mis ventas'}
        acciones={
          <>
            {esDueno && <EnlaceBoton href={enlace({ nombre: 'comprobantes' })}>Facturas SRI</EnlaceBoton>}
            <EnlaceBoton href={enlace({ nombre: 'clientes' })}>Clientes</EnlaceBoton>
            <EnlaceBoton href={enlace({ nombre: 'vender' })} variante="primario">
              Vender
            </EnlaceBoton>
          </>
        }
      />
      {esDueno && solicitudes > 0 && (
        <Casilla
          etiqueta={`Solo anulaciones pedidas (${solicitudes})`}
          checked={soloSolicitudes}
          onChange={(e) => setSoloSolicitudes(e.target.checked)}
        />
      )}
      {ventas.isPending && <Cargando />}
      <AvisoError error={ventas.error} />
      {ventas.isSuccess && visibles.length === 0 && <Tarjeta>No hay ventas para mostrar.</Tarjeta>}

      <ul className="mt-2 flex flex-col gap-2">
        {visibles.map((v) => (
          <li key={v.id}>
            <a
              href={enlace({ nombre: 'venta', id: v.id })}
              className={`flex items-center gap-3 rounded-xl border border-gray-200 bg-white p-3 hover:border-gray-400 ${
                v.estado === 'ANULADA' ? 'opacity-60' : ''
              }`}
            >
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">{v.clientes?.nombre ?? 'Consumidor final'}</p>
                <p className="truncate text-sm text-gray-500">
                  {formatearMomento(v.creado_en)} · {COMPROBANTES[v.tipo_comprobante]}
                </p>
              </div>
              <div className="text-right">
                <p className={`font-semibold tabular-nums ${v.estado === 'ANULADA' ? 'line-through' : ''}`}>
                  {formatearDinero(v.total)}
                </p>
                {v.estado === 'ANULADA' ? (
                  <p className="text-xs text-red-700">anulada</p>
                ) : (
                  v.solicitud_anulacion && <p className="text-xs text-amber-700">piden anular</p>
                )}
              </div>
            </a>
          </li>
        ))}
      </ul>
    </>
  );
}
