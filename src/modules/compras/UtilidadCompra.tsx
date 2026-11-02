import { Receipt, TrendingUp } from 'lucide-react';
import { formatearCantidad, formatearCosto, formatearDinero, formatearPorcentaje } from '@/shared/formato';
import { Tarjeta } from '@/shared/ui';
import type { Utilidad, UtilidadLinea } from './api';

/** Una línea en palabras: lo que cuesta, a cuánto se vende y lo que queda. */
export function LineaUtilidad({ linea }: { linea: UtilidadLinea }) {
  if (linea.utilidad === null) {
    return <p className="text-sm text-amber-800">Sin precio de venta: no se puede calcular la utilidad.</p>;
  }
  const perdida = linea.utilidad.startsWith('-');
  return (
    <p className={`text-sm ${perdida ? 'font-medium text-red-700' : 'text-gray-700'}`}>
      Cuesta {formatearCosto(linea.costo_unidad)} · se vende a {formatearCosto(linea.venta_unidad ?? '0')} sin IVA ·{' '}
      {perdida ? 'pierdes' : 'ganas'} {formatearDinero(linea.utilidad.replace('-', ''))}
      {linea.margen && ` (${formatearPorcentaje(linea.margen)})`}
    </p>
  );
}

/** Lo que se va a pagar, con lo que de verdad llegó. */
export function TotalCompra({ compra }: { compra: NonNullable<Utilidad['compra']> }) {
  // Hasta 5 centavos es redondeo del SRI (D-056), no algo que faltó.
  const distinto = Math.abs(Number(compra.total) - Number(compra.total_factura)) > 0.05;
  return (
    <Tarjeta className="mb-4">
      <h2 className="mb-2 flex items-center gap-2 font-semibold">
        <Receipt className="size-5 text-emerald-700" aria-hidden />
        Total de esta compra
      </h2>
      <dl className="grid grid-cols-[1fr_auto] gap-x-6 gap-y-1 text-sm tabular-nums">
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
        {Number(compra.otros) > 0 && (
          <>
            <dt className="text-gray-600">ICE y otros impuestos</dt>
            <dd className="text-right">{formatearDinero(compra.otros)}</dd>
          </>
        )}
        <dt className="text-base font-bold">Total</dt>
        <dd className="text-right text-2xl font-bold">{formatearDinero(compra.total)}</dd>
      </dl>
      {distinto && (
        <p className="mt-2 text-sm text-amber-800">
          La factura dice {formatearDinero(compra.total_factura)}: la diferencia es por lo que no llegó.
        </p>
      )}
    </Tarjeta>
  );
}

/** El resumen de la compra: lo que quedaría si se vende todo a los precios de hoy. */
export function ResumenUtilidad({ utilidad, className = '' }: { utilidad: Utilidad; className?: string }) {
  const perdida = utilidad.utilidad.startsWith('-');
  return (
    <Tarjeta className={className}>
      <h2 className="mb-1 flex items-center gap-2 font-semibold">
        <TrendingUp className="size-5 text-emerald-700" aria-hidden />
        Utilidad de esta compra
      </h2>
      <p className={`text-2xl font-bold tabular-nums ${perdida ? 'text-red-700' : 'text-emerald-800'}`}>
        {formatearDinero(utilidad.utilidad)}
        {utilidad.margen && <span className="ml-2 text-base font-medium">{formatearPorcentaje(utilidad.margen)} de margen</span>}
      </p>
      <p className="text-sm text-gray-600">
        Si vendes todo a los precios de hoy: venta {formatearDinero(utilidad.venta)} sin IVA, costo{' '}
        {formatearDinero(utilidad.costo)}.
      </p>
      {utilidad.sin_precio > 0 && (
        <p className="mt-1 text-sm text-amber-800">
          {utilidad.sin_precio === 1 ? '1 producto no tiene' : `${utilidad.sin_precio} productos no tienen`} precio de venta: no
          se cuenta{utilidad.sin_precio === 1 ? '' : 'n'} aquí.
        </p>
      )}
      <p className="mt-1 text-xs text-gray-500">
        Es una estimación con {formatearCantidad(String(utilidad.lineas.length))}{' '}
        {utilidad.lineas.length === 1 ? 'línea' : 'líneas'}: usa el precio de venta por unidad de cada producto.
      </p>
    </Tarjeta>
  );
}
