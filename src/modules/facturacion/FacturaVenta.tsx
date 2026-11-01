import { FileCheck2, FileText, RefreshCw, Send } from 'lucide-react';
import { useContexto } from '@/modules/sesion/sesion';
import { enlace } from '@/shared/ruta';
import { Aviso, AvisoError, Boton, Cargando, EnlaceBoton, Tarjeta } from '@/shared/ui';
import { ESTADOS_FACTURA, useEmitirFactura, useFacturaDeVenta } from './api';

/** Estado de la factura electrónica de una venta y su envío al SRI. */
export function FacturaVenta({ ventaId, anulada }: { ventaId: string; anulada: boolean }) {
  const contexto = useContexto();
  const factura = useFacturaDeVenta(ventaId);
  const emitir = useEmitirFactura();
  const f = factura.data;

  if (factura.isPending) return <Cargando />;
  if (!f && (!contexto.facturacion_activa || anulada)) return null;

  const texto = !f ? 'Enviar factura al SRI' : f.estado === 'RECIBIDA' ? 'Consultar otra vez' : 'Volver a enviar';

  return (
    <Tarjeta className="mb-4">
      <h2 className="mb-2 flex items-center gap-2 font-semibold">
        <FileCheck2 className="size-5 text-emerald-700" aria-hidden />
        Factura electrónica
      </h2>
      <AvisoError error={factura.error} />
      {f && (
        <dl className="mb-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
          <dt className="text-gray-500">Número</dt>
          <dd>{f.numero}</dd>
          <dt className="text-gray-500">Estado</dt>
          <dd className={f.estado === 'AUTORIZADA' ? 'font-semibold text-green-800' : 'font-semibold'}>
            {ESTADOS_FACTURA[f.estado]}
          </dd>
          <dt className="text-gray-500">Ambiente</dt>
          <dd>{f.ambiente === '1' ? 'Pruebas: no tiene valor tributario' : 'Producción'}</dd>
        </dl>
      )}

      {f && f.mensajes.length > 0 && f.estado !== 'AUTORIZADA' && (
        <ul className="mb-3 flex flex-col gap-1 text-sm text-red-800">
          {f.mensajes.map((m, i) => (
            <li key={i}>
              {m.identificador && `${m.identificador}: `}
              {m.mensaje}
              {m.informacionAdicional && ` (${m.informacionAdicional})`}
            </li>
          ))}
        </ul>
      )}

      <AvisoError error={emitir.error} />
      <div className="mt-2 flex flex-wrap gap-2">
        {f?.estado === 'AUTORIZADA' ? (
          <EnlaceBoton href={enlace({ nombre: 'factura', id: ventaId })} icono={FileText} variante="primario">
            Ver factura
          </EnlaceBoton>
        ) : (
          !anulada && (
            <Boton
              icono={f ? RefreshCw : Send}
              disabled={emitir.isPending}
              onClick={() => emitir.mutate(ventaId)}
            >
              {emitir.isPending ? 'Enviando al SRI…' : texto}
            </Boton>
          )
        )}
      </div>
      {f?.estado === 'AUTORIZADA' && (
        <div className="mt-3">
          <Aviso tipo="info">Para anular esta factura ante el SRI hay que hacerlo también en su portal.</Aviso>
        </div>
      )}
    </Tarjeta>
  );
}
