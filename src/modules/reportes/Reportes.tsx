import { useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { esquemaValorizado } from '@/modules/inventario/api';
import { llamar } from '@/lib/datos';
import { generarCsv, descargarArchivo } from '@/shared/csv';
import { rangoMes, aTexto, nombrarMes, type Rango } from '@/shared/fechas';
import { formatearCantidad, formatearDinero, formatearPorcentaje } from '@/shared/formato';
import { AvisoError, Boton, Campo, Cargando, Encabezado, Tarjeta } from '@/shared/ui';
import {
  pedirExportacion,
  useAcumuladoRimpe,
  useReporteMargen,
  useReporteVentas,
  type Exportacion,
} from './api';

const MEDIOS: Record<string, string> = {
  EFECTIVO: 'Efectivo',
  TRANSFERENCIA: 'Transferencia',
  TARJETA: 'Tarjeta',
  FIADO: 'Fiado',
};
const MESES = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];

/** Reportes del Dueño (HU-05) y exportación para el contador. */
export function Reportes() {
  const [rango, setRango] = useState<Rango>(() => rangoMes(new Date()));
  const [desde, setDesde] = useState(rango.desde);
  const [hasta, setHasta] = useState(rango.hasta);

  const elegir = (r: Rango) => {
    setRango(r);
    setDesde(r.desde);
    setHasta(r.hasta);
  };

  return (
    <>
      <Encabezado titulo="Reportes" />
      <Tarjeta className="mb-4">
        <div className="flex flex-wrap items-end gap-2">
          <Boton variante="secundario" onClick={() => elegir({ desde: aTexto(new Date()), hasta: aTexto(new Date()) })}>
            Hoy
          </Boton>
          <Boton variante="secundario" onClick={() => elegir(rangoMes(new Date()))}>
            Este mes
          </Boton>
          <Boton variante="secundario" onClick={() => elegir(rangoMes(new Date(), -1))}>
            Mes anterior
          </Boton>
          <div className="w-40">
            <Campo etiqueta="Desde" type="date" value={desde} onChange={(e) => setDesde(e.target.value)} />
          </div>
          <div className="w-40">
            <Campo etiqueta="Hasta" type="date" value={hasta} onChange={(e) => setHasta(e.target.value)} />
          </div>
          <Boton onClick={() => setRango({ desde, hasta })} disabled={!desde || !hasta}>
            Ver
          </Boton>
        </div>
      </Tarjeta>

      <ResumenVentas rango={rango} />
      <MargenPorProducto rango={rango} />
      <AcumuladoRimpe anio={Number(rango.hasta.slice(0, 4))} />
      <Exportar rango={rango} />
    </>
  );
}

function Cifra({ titulo, valor, nota }: { titulo: string; valor: string; nota?: string }) {
  return (
    <div className="rounded-lg bg-gray-50 p-3">
      <p className="text-sm text-gray-600">{titulo}</p>
      <p className="text-xl font-semibold tabular-nums">{valor}</p>
      {nota && <p className="text-xs text-gray-500">{nota}</p>}
    </div>
  );
}

function ResumenVentas({ rango }: { rango: Rango }) {
  const reporte = useReporteVentas(rango);
  const r = reporte.data;
  return (
    <Tarjeta className="mb-4">
      <h2 className="mb-3 font-semibold">Ventas</h2>
      {reporte.isPending && <Cargando />}
      <AvisoError error={reporte.error} />
      {r && (
        <>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            <Cifra titulo="Ventas sin IVA" valor={formatearDinero(r.totales.base)} nota="ya restadas las devoluciones" />
            <Cifra titulo="IVA" valor={formatearDinero(r.totales.iva)} />
            <Cifra titulo="Costo de ventas" valor={formatearDinero(r.totales.costo)} />
            <Cifra
              titulo="Utilidad bruta"
              valor={formatearDinero(r.totales.utilidad)}
              nota={r.totales.margen ? `${formatearPorcentaje(r.totales.margen)} de margen` : undefined}
            />
          </div>
          <p className="mt-3 text-sm text-gray-600">
            {r.totales.ventas} ventas · {r.totales.anuladas} anuladas · devoluciones {formatearDinero(r.devoluciones)}
            {Object.entries(r.por_medio).map(([medio, monto]) => ` · ${MEDIOS[medio] ?? medio} ${formatearDinero(monto)}`)}
          </p>
          {r.por_dia.length > 1 && (
            <table className="mt-3 w-full text-sm tabular-nums">
              <thead>
                <tr className="text-left text-gray-500">
                  <th className="font-normal">Día</th>
                  <th className="text-right font-normal">Sin IVA</th>
                  <th className="text-right font-normal">Total cobrado</th>
                </tr>
              </thead>
              <tbody>
                {r.por_dia.map((d) => (
                  <tr key={d.fecha} className="border-t border-gray-100">
                    <td className="py-1">{d.fecha}</td>
                    <td className="text-right">{formatearDinero(d.base)}</td>
                    <td className="text-right">{formatearDinero(d.total)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </>
      )}
    </Tarjeta>
  );
}

function MargenPorProducto({ rango }: { rango: Rango }) {
  const margen = useReporteMargen(rango);
  return (
    <Tarjeta className="mb-4">
      <h2 className="font-semibold">Margen por producto</h2>
      <p className="mb-3 text-sm text-gray-600">
        <strong>Margen</strong>: cuánto queda de cada dólar vendido (utilidad ÷ venta).{' '}
        <strong>Recargo</strong>: cuánto se subió sobre el costo (utilidad ÷ costo). Sin IVA.
      </p>
      {margen.isPending && <Cargando />}
      <AvisoError error={margen.error} />
      {margen.data?.length === 0 && <p className="text-gray-500">No hay ventas en este período.</p>}
      {(margen.data?.length ?? 0) > 0 && (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[36rem] text-sm tabular-nums">
            <thead>
              <tr className="text-left text-gray-500">
                <th className="font-normal">Producto</th>
                <th className="text-right font-normal">Vendido</th>
                <th className="text-right font-normal">Ventas</th>
                <th className="text-right font-normal">Costo</th>
                <th className="text-right font-normal">Utilidad</th>
                <th className="text-right font-normal">Margen (sobre venta)</th>
                <th className="text-right font-normal">Recargo (sobre costo)</th>
              </tr>
            </thead>
            <tbody>
              {margen.data?.map((p) => (
                <tr key={p.producto_id} className="border-t border-gray-100">
                  <td className="py-1">{p.nombre}</td>
                  <td className="text-right">
                    {formatearCantidad(p.cantidad)} {p.unidad_base === 'KG' ? 'kg' : 'u'}
                  </td>
                  <td className="text-right">{formatearDinero(p.ventas)}</td>
                  <td className="text-right">{formatearDinero(p.costo)}</td>
                  <td className={`text-right ${p.utilidad.startsWith('-') ? 'text-red-700' : ''}`}>{formatearDinero(p.utilidad)}</td>
                  <td className="text-right">{p.margen ? formatearPorcentaje(p.margen) : '—'}</td>
                  <td className="text-right">{p.recargo ? formatearPorcentaje(p.recargo) : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Tarjeta>
  );
}

function AcumuladoRimpe({ anio }: { anio: number }) {
  const rimpe = useAcumuladoRimpe(anio);
  const r = rimpe.data;
  const fraccion = r ? Math.min(Number(r.porcentaje), 1) : 0;
  const alerta = fraccion >= 0.8;
  return (
    <Tarjeta className="mb-4">
      <h2 className="mb-1 font-semibold">Límite RIMPE Negocio Popular {anio}</h2>
      <p className="mb-3 text-sm text-gray-600">Ventas sin IVA del año frente al límite configurado (confirmar el monto con el contador).</p>
      {rimpe.isPending && <Cargando />}
      <AvisoError error={rimpe.error} />
      {r && (
        <>
          <p className="tabular-nums">
            <strong>{formatearDinero(r.acumulado)}</strong> de {formatearDinero(r.limite)} ({formatearPorcentaje(r.porcentaje)}) ·
            quedan {formatearDinero(r.disponible)}
          </p>
          <div
            className="mt-2 h-3 overflow-hidden rounded-full bg-gray-100"
            role="progressbar"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={Math.round(fraccion * 100)}
            aria-label="Avance hacia el límite RIMPE"
          >
            <div className={`h-full ${alerta ? 'bg-red-600' : 'bg-gray-800'}`} style={{ width: `${fraccion * 100}%` }} />
          </div>
          {alerta && <p className="mt-2 text-sm text-red-700">Te acercas al límite: habla con tu contador.</p>}
          <div className="mt-3 grid grid-cols-6 gap-1 text-center text-xs tabular-nums sm:grid-cols-12">
            {r.por_mes.map((m) => (
              <div key={m.mes} className="rounded bg-gray-50 p-1">
                <p className="text-gray-500">{MESES[m.mes - 1]}</p>
                <p>{Number(m.base) === 0 ? '—' : formatearDinero(m.base)}</p>
              </div>
            ))}
          </div>
        </>
      )}
    </Tarjeta>
  );
}

function Exportar({ rango }: { rango: Rango }) {
  const queryClient = useQueryClient();
  const exportar = useMutation({ mutationFn: () => pedirExportacion(rango) });
  const inventario = useMutation({
    mutationFn: () =>
      queryClient.fetchQuery({
        queryKey: ['inventario', 'valorizado'],
        queryFn: () => llamar('inventario_valorizado', {}, esquemaValorizado),
      }),
  });
  const sufijo = `${rango.desde}_${rango.hasta}`;
  const etiqueta = rango.desde.endsWith('-01') ? nombrarMes(rango.desde) : `${rango.desde} a ${rango.hasta}`;

  const archivos = (e: Exportacion) => {
    descargarArchivo(
      `ventas_${sufijo}.csv`,
      generarCsv(e.ventas, [
        { titulo: 'Fecha', valor: (v) => v.fecha },
        { titulo: 'Venta', valor: (v) => v.venta },
        { titulo: 'Comprobante', valor: (v) => v.comprobante },
        { titulo: 'Cliente', valor: (v) => v.cliente },
        { titulo: 'Identificación', valor: (v) => v.identificacion },
        { titulo: 'Base 0%', valor: (v) => v.base_0, decimal: true },
        { titulo: 'Base gravada', valor: (v) => v.base_gravada, decimal: true },
        { titulo: 'IVA', valor: (v) => v.iva, decimal: true },
        { titulo: 'Total', valor: (v) => v.total, decimal: true },
        { titulo: 'Estado', valor: (v) => v.estado },
      ]),
    );
    descargarArchivo(
      `compras_${sufijo}.csv`,
      generarCsv(e.compras, [
        { titulo: 'Fecha', valor: (c) => c.fecha },
        { titulo: 'Proveedor', valor: (c) => c.proveedor },
        { titulo: 'RUC / cédula', valor: (c) => c.identificacion },
        { titulo: 'Documento', valor: (c) => c.documento },
        { titulo: 'Con respaldo', valor: (c) => c.respaldo },
        { titulo: 'Base 0%', valor: (c) => c.base_0, decimal: true },
        { titulo: 'Base gravada', valor: (c) => c.base_gravada, decimal: true },
        { titulo: 'IVA', valor: (c) => c.iva, decimal: true },
        { titulo: 'Total', valor: (c) => c.total, decimal: true },
        { titulo: 'Estado', valor: (c) => c.estado },
      ]),
    );
    descargarArchivo(
      `devoluciones_${sufijo}.csv`,
      generarCsv(e.devoluciones, [
        { titulo: 'Fecha', valor: (d) => d.fecha },
        { titulo: 'Venta', valor: (d) => d.venta },
        { titulo: 'Motivo', valor: (d) => d.motivo },
        { titulo: 'Reintegro', valor: (d) => d.reintegro },
        { titulo: 'Base 0%', valor: (d) => d.base_0, decimal: true },
        { titulo: 'Base gravada', valor: (d) => d.base_gravada, decimal: true },
        { titulo: 'IVA', valor: (d) => d.iva, decimal: true },
        { titulo: 'Total', valor: (d) => d.total, decimal: true },
      ]),
    );
    const r = e.resumen;
    const filas = [
      { concepto: 'Ventas', base_0: r.ventas_base_0, base_gravada: r.ventas_base_gravada, iva: r.ventas_iva },
      { concepto: 'Devoluciones', base_0: r.devoluciones_base_0, base_gravada: r.devoluciones_base_gravada, iva: r.devoluciones_iva },
      { concepto: 'Compras', base_0: r.compras_base_0, base_gravada: r.compras_base_gravada, iva: r.compras_iva },
    ];
    descargarArchivo(
      `resumen_iva_${sufijo}.csv`,
      generarCsv(filas, [
        { titulo: 'Concepto', valor: (f) => f.concepto },
        { titulo: 'Base 0%', valor: (f) => f.base_0, decimal: true },
        { titulo: 'Base gravada', valor: (f) => f.base_gravada, decimal: true },
        { titulo: 'IVA', valor: (f) => f.iva, decimal: true },
      ]),
    );
  };

  return (
    <Tarjeta>
      <h2 className="mb-1 font-semibold">Para el contador</h2>
      <p className="mb-3 text-sm text-gray-600">
        Descarga ventas, compras, devoluciones y el resumen de IVA de {etiqueta} en archivos que se abren con Excel. Los
        documentos anulados se incluyen marcados y no suman en el resumen.
      </p>
      <div className="flex flex-wrap gap-2">
        <Boton disabled={exportar.isPending} onClick={() => exportar.mutate(undefined, { onSuccess: archivos })}>
          {exportar.isPending ? 'Preparando…' : 'Descargar archivos del período'}
        </Boton>
        <Boton
          variante="secundario"
          disabled={inventario.isPending}
          onClick={() =>
            inventario.mutate(undefined, {
              onSuccess: (v) =>
                descargarArchivo(
                  `inventario_${aTexto(new Date())}.csv`,
                  generarCsv(v.productos, [
                    { titulo: 'Producto', valor: (p) => p.nombre },
                    { titulo: 'Unidad', valor: (p) => p.unidad_base },
                    { titulo: 'Cantidad', valor: (p) => p.cantidad, decimal: true },
                    { titulo: 'Costo promedio', valor: (p) => p.costo_promedio, decimal: true },
                    { titulo: 'Valor', valor: (p) => p.valor_total, decimal: true },
                  ]),
                ),
            })
          }
        >
          Inventario valorizado de hoy
        </Boton>
      </div>
      <div className="mt-3">
        <AvisoError error={exportar.error ?? inventario.error} />
      </div>
    </Tarjeta>
  );
}
