import { UNIDADES, useProducto } from '@/modules/catalogo/api';
import { useContexto } from '@/modules/sesion/sesion';
import { formatearCantidad, formatearCosto } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { AvisoError, Cargando, Encabezado, Tarjeta } from '@/shared/ui';
import { TIPOS_MOVIMIENTO, useKardex } from './api';

const fecha = new Intl.DateTimeFormat('es-EC', { day: '2-digit', month: 'short', year: 'numeric', timeZone: 'UTC' });

export function Kardex({ id }: { id: string }) {
  const contexto = useContexto();
  const producto = useProducto(id);
  const kardex = useKardex(id);
  const volver = enlace({ nombre: 'producto', id });

  if (!contexto.ve_costos) {
    return (
      <>
        <Encabezado titulo="Kardex" volver={volver} />
        <Tarjeta>El kardex muestra costos y solo lo ve el Dueño.</Tarjeta>
      </>
    );
  }

  const unidad = producto.data ? UNIDADES[producto.data.unidad_base] : '';

  return (
    <>
      <Encabezado titulo={`Kardex: ${producto.data?.nombre ?? ''}`} volver={volver} />
      {kardex.isPending && <Cargando />}
      <AvisoError error={kardex.error} />
      {kardex.isSuccess && kardex.data.length === 0 && <Tarjeta>Este producto todavía no tiene movimientos.</Tarjeta>}

      <ol className="flex flex-col gap-2">
        {kardex.data?.map((m) => {
          const entra = !m.cantidad.startsWith('-');
          return (
            <li key={m.id} className="rounded-xl border border-gray-200 bg-white p-3">
              <div className="flex items-baseline justify-between gap-2">
                <p className="font-medium">{TIPOS_MOVIMIENTO[m.tipo]}</p>
                <p className="text-sm text-gray-500">{fecha.format(new Date(`${m.fecha}T00:00:00Z`))}</p>
              </div>
              {m.motivo && <p className="text-sm text-gray-600">{m.motivo}</p>}
              <dl className="mt-2 grid grid-cols-2 gap-x-4 text-sm tabular-nums sm:grid-cols-4">
                <div>
                  <dt className="text-gray-500">Cantidad</dt>
                  <dd className={entra ? 'text-green-800' : 'text-red-800'}>
                    {entra ? '+' : '−'}
                    {formatearCantidad(m.cantidad.replace('-', ''))} {unidad}
                  </dd>
                </div>
                <div>
                  <dt className="text-gray-500">Costo unitario</dt>
                  <dd>{formatearCosto(m.costo_unitario)}</dd>
                </div>
                <div>
                  <dt className="text-gray-500">Saldo</dt>
                  <dd>
                    {formatearCantidad(m.saldo_cantidad)} {unidad}
                  </dd>
                </div>
                <div>
                  <dt className="text-gray-500">Valor del saldo</dt>
                  <dd>{formatearCosto(m.saldo_valor)}</dd>
                </div>
              </dl>
            </li>
          );
        })}
      </ol>
    </>
  );
}
