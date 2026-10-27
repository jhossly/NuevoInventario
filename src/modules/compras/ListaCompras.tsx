import { formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { AvisoError, Cargando, EnlaceBoton, Encabezado, Tarjeta } from '@/shared/ui';
import { formatearFecha, useCompras } from './api';

export function ListaCompras() {
  const compras = useCompras();

  return (
    <>
      <Encabezado
        titulo="Compras"
        acciones={
          <>
            <EnlaceBoton href={enlace({ nombre: 'proveedores' })}>Proveedores</EnlaceBoton>
            <EnlaceBoton href={enlace({ nombre: 'compra-nueva' })} variante="primario">
              Nueva
            </EnlaceBoton>
          </>
        }
      />
      {compras.isPending && <Cargando />}
      <AvisoError error={compras.error} />
      {compras.isSuccess && compras.data.length === 0 && <Tarjeta>Todavía no hay compras registradas.</Tarjeta>}

      <ul className="flex flex-col gap-2">
        {compras.data?.map((c) => (
          <li key={c.id}>
            <a
              href={enlace({ nombre: 'compra', id: c.id })}
              className={`flex items-center gap-3 rounded-xl border border-gray-200 bg-white p-3 hover:border-gray-400 ${
                c.estado === 'ANULADA' ? 'opacity-60' : ''
              }`}
            >
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">{c.proveedores?.nombre ?? 'Sin proveedor'}</p>
                <p className="truncate text-sm text-gray-500">
                  {formatearFecha(c.fecha)}
                  {c.numero_documento && ` · ${c.numero_documento}`}
                </p>
              </div>
              <div className="text-right">
                <p className={`font-semibold tabular-nums ${c.estado === 'ANULADA' ? 'line-through' : ''}`}>
                  {formatearDinero(c.total)}
                </p>
                {c.estado === 'ANULADA' ? (
                  <p className="text-xs text-red-700">anulada</p>
                ) : (
                  !c.con_respaldo && <p className="text-xs text-amber-700">sin respaldo</p>
                )}
              </div>
            </a>
          </li>
        ))}
      </ul>
    </>
  );
}
