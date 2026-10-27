import { useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { llamar } from '@/lib/datos';
import { decimal, uuid } from '@/shared/esquemas';
import type { Rango } from '@/shared/fechas';

export const esquemaReporteVentas = z.object({
  totales: z.object({
    ventas: z.number(),
    anuladas: z.number(),
    base: decimal,
    iva: decimal,
    total: decimal,
    costo: decimal,
    utilidad: decimal,
    margen: decimal.nullable(),
  }),
  por_dia: z.array(z.object({ fecha: z.string(), total: decimal, base: decimal })),
  por_medio: z.record(z.string(), decimal),
  devoluciones: decimal,
});

export const esquemaMargen = z.object({
  productos: z.array(
    z.object({
      producto_id: uuid,
      nombre: z.string(),
      unidad_base: z.enum(['UND', 'KG']),
      cantidad: decimal,
      ventas: decimal,
      costo: decimal,
      utilidad: decimal,
      margen: decimal.nullable(),
      recargo: decimal.nullable(),
    }),
  ),
});

export const esquemaRimpe = z.object({
  anio: z.number(),
  limite: decimal,
  acumulado: decimal,
  porcentaje: decimal,
  disponible: decimal,
  por_mes: z.array(z.object({ mes: z.number(), base: decimal })),
});

const documento = {
  fecha: z.string(),
  base_0: decimal,
  base_gravada: decimal,
  iva: decimal,
  total: decimal,
};

export const esquemaExportacion = z.object({
  ventas: z.array(
    z.object({ ...documento, venta: z.string(), comprobante: z.string(), cliente: z.string(), identificacion: z.string(), estado: z.string() }),
  ),
  devoluciones: z.array(z.object({ ...documento, venta: z.string(), motivo: z.string(), reintegro: z.string() })),
  compras: z.array(
    z.object({
      ...documento,
      proveedor: z.string(),
      identificacion: z.string(),
      documento: z.string(),
      respaldo: z.string(),
      estado: z.string(),
    }),
  ),
  resumen: z.record(z.string(), decimal),
});

export type ReporteVentas = z.infer<typeof esquemaReporteVentas>;
export type Margen = z.infer<typeof esquemaMargen>['productos'][number];
export type Rimpe = z.infer<typeof esquemaRimpe>;
export type Exportacion = z.infer<typeof esquemaExportacion>;

const periodo = (r: Rango) => ({ p_desde: r.desde, p_hasta: r.hasta });

export function useReporteVentas(rango: Rango) {
  return useQuery({
    queryKey: ['reportes', 'ventas', rango],
    queryFn: () => llamar('reporte_ventas', periodo(rango), esquemaReporteVentas),
  });
}

export function useReporteMargen(rango: Rango) {
  return useQuery({
    queryKey: ['reportes', 'margen', rango],
    queryFn: async () => (await llamar('reporte_margen', periodo(rango), esquemaMargen)).productos,
  });
}

export function useAcumuladoRimpe(anio: number) {
  return useQuery({
    queryKey: ['reportes', 'rimpe', anio],
    queryFn: () => llamar('acumulado_rimpe', { p_anio: anio }, esquemaRimpe),
  });
}

/** Se pide al pulsar «Exportar», no al abrir la pantalla. */
export function pedirExportacion(rango: Rango): Promise<Exportacion> {
  return llamar('exportacion_contador', periodo(rango), esquemaExportacion);
}
