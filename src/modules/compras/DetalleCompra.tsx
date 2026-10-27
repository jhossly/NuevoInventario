import { useState } from 'react';
import { UNIDADES } from '@/modules/catalogo/api';
import { formatearCantidad, formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { Aviso, AvisoError, Boton, Campo, Cargando, Encabezado, Tarjeta } from '@/shared/ui';
import { formatearFecha, useAnularCompra, useCompra, type Compra } from './api';

export function DetalleCompra({ id }: { id: string }) {
  const compra = useCompra(id);
  const volver = enlace({ nombre: 'compras' });

  if (compra.isPending) return <Cargando />;
  if (compra.error) return <AvisoError error={compra.error} />;
  if (!compra.data) {
    return (
      <>
        <Encabezado titulo="Compra" volver={volver} />
        <Tarjeta>La compra no existe o no es de tu empresa.</Tarjeta>
      </>
    );
  }
  return <Detalle compra={compra.data} volver={volver} />;
}

function Detalle({ compra, volver }: { compra: Compra; volver: string }) {
  const anulada = compra.estado === 'ANULADA';

  return (
    <>
      <Encabezado titulo={compra.proveedores?.nombre ?? 'Compra sin proveedor'} volver={volver} />

      {anulada && <Aviso>Compra anulada: {compra.motivo_anulacion}</Aviso>}

      <Tarjeta className="my-4">
        <dl className="grid grid-cols-2 gap-y-1 text-sm">
          <dt className="text-gray-500">Fecha</dt>
          <dd>{formatearFecha(compra.fecha)}</dd>
          <dt className="text-gray-500">Documento</dt>
          <dd>{compra.numero_documento ?? '—'}</dd>
          <dt className="text-gray-500">Respaldo</dt>
          <dd className={compra.con_respaldo ? '' : 'text-amber-700'}>
            {compra.con_respaldo ? 'Con respaldo' : 'Sin respaldo – requiere revisión'}
          </dd>
          <dt className="text-gray-500">IVA en el costo</dt>
          <dd>{compra.iva_es_costo ? 'Sí' : 'No'}</dd>
        </dl>
      </Tarjeta>

      <Tarjeta className="mb-4">
        <h2 className="mb-2 font-semibold">Productos</h2>
        <ol className="divide-y divide-gray-100">
          {compra.compra_detalles.map((d) => {
            const unidad = UNIDADES[d.productos.unidad_base];
            return (
              <li key={d.orden} className="py-2">
                <div className="flex justify-between gap-2">
                  <p className="font-medium">
                    {d.productos.nombre} — {d.presentaciones.nombre}
                  </p>
                  <p className="tabular-nums">{formatearDinero(d.subtotal)}</p>
                </div>
                <p className="text-sm text-gray-500">
                  {formatearCantidad(d.cantidad)} × {formatearCosto(d.costo_unitario)}
                  {Number(d.descuento) > 0 && ` · desc. ${formatearDinero(d.descuento)}`} · IVA {Number(d.tarifa_iva)} %{' '}
                  {formatearDinero(d.iva)}
                </p>
                <p className="text-sm text-gray-500">
                  Entraron {formatearCantidad(d.cantidad_base)} {unidad} a {formatearCosto(d.costo_unitario_base)} c/u
                </p>
              </li>
            );
          })}
        </ol>
        <dl className="mt-3 grid grid-cols-2 gap-x-4 border-t border-gray-200 pt-3 text-sm tabular-nums">
          <dt className="text-gray-600">Subtotal</dt>
          <dd className="text-right">{formatearDinero(compra.subtotal)}</dd>
          {Number(compra.descuento) > 0 && (
            <>
              <dt className="text-gray-600">Descuento</dt>
              <dd className="text-right">−{formatearDinero(compra.descuento)}</dd>
            </>
          )}
          <dt className="text-gray-600">IVA</dt>
          <dd className="text-right">{formatearDinero(compra.iva)}</dd>
          <dt className="font-semibold">Total</dt>
          <dd className={`text-right font-semibold ${anulada ? 'line-through' : ''}`}>{formatearDinero(compra.total)}</dd>
        </dl>
      </Tarjeta>

      {!anulada && <Anular id={compra.id} />}
    </>
  );
}

function Anular({ id }: { id: string }) {
  const anular = useAnularCompra();
  const [abierto, setAbierto] = useState(false);
  const [motivo, setMotivo] = useState('');
  const [error, setError] = useState<string | null>(null);

  if (!abierto) {
    return (
      <Boton variante="secundario" onClick={() => setAbierto(true)}>
        Anular compra…
      </Boton>
    );
  }

  return (
    <Tarjeta>
      <p className="mb-3 text-sm text-gray-600">
        Anular saca del inventario lo que entró con esta compra, al costo promedio actual. Si ya se vendió parte, no se
        puede anular: corrígelo con un ajuste.
      </p>
      <Campo
        etiqueta="Motivo"
        placeholder="Factura equivocada, producto devuelto…"
        value={motivo}
        onChange={(e) => setMotivo(e.target.value)}
        error={error}
      />
      <div className="mt-3">
        <AvisoError error={anular.error} />
      </div>
      <div className="mt-3 flex gap-2">
        <Boton
          variante="peligro"
          disabled={anular.isPending}
          onClick={() => {
            if (motivo.trim() === '') {
              setError('Escribe el motivo');
              return;
            }
            setError(null);
            anular.mutate({ id, motivo: motivo.trim() });
          }}
        >
          {anular.isPending ? 'Anulando…' : 'Confirmar anulación'}
        </Boton>
        <Boton variante="secundario" onClick={() => setAbierto(false)}>
          Cancelar
        </Boton>
      </div>
    </Tarjeta>
  );
}
