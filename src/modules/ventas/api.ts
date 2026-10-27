import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { consultar, llamar } from '@/lib/datos';
import { decimal, uuid } from '@/shared/esquemas';
import { claves as clavesCatalogo } from '@/modules/catalogo/api';

// -----------------------------------------------------------------------------
// Esquemas
// -----------------------------------------------------------------------------
export const COMPROBANTES = {
  NOTA_VENTA: 'Nota de venta',
  FACTURA: 'Factura',
  NINGUNO_PERMITIDO: 'Sin comprobante',
} as const;
export type TipoComprobante = keyof typeof COMPROBANTES;

export const MEDIOS = { EFECTIVO: 'Efectivo', TRANSFERENCIA: 'Transferencia', TARJETA: 'Tarjeta', FIADO: 'Fiado' } as const;
export type Medio = keyof typeof MEDIOS;

export const esquemaCliente = z.object({
  id: uuid,
  tipo_identificacion: z.enum(['RUC', 'CEDULA', 'PASAPORTE']).nullable(),
  identificacion: z.string().nullable(),
  nombre: z.string(),
  telefono: z.string().nullable(),
  correo: z.string().nullable(),
  direccion: z.string().nullable(),
  fiado_permitido: z.boolean(),
  limite_fiado: decimal,
  activo: z.boolean(),
});

export const esquemaCalculoVenta = z.object({
  lineas: z.array(
    z.object({
      orden: z.number(),
      nombre: z.string(),
      precio_unitario: decimal,
      subtotal: decimal,
      descuento: decimal,
      iva: decimal,
      total: decimal,
    }),
  ),
  subtotal: decimal,
  descuento: decimal,
  iva: decimal,
  total: decimal,
});

const esquemaResumenVenta = z.object({
  id: uuid,
  fecha: z.string(),
  creado_en: z.string(),
  tipo_comprobante: z.enum(['NOTA_VENTA', 'FACTURA', 'NINGUNO_PERMITIDO']),
  total: decimal,
  estado: z.enum(['CONFIRMADA', 'ANULADA']),
  solicitud_anulacion: z.string().nullable(),
  clientes: z.object({ nombre: z.string() }).nullable(),
});

const esquemaLineaVenta = z.object({
  id: uuid,
  orden: z.number(),
  cantidad: decimal,
  precio_unitario: decimal,
  tarifa_iva: decimal,
  subtotal: decimal,
  descuento: decimal,
  iva: decimal,
  total: decimal,
  presentaciones: z.object({ nombre: z.string(), factor: decimal }),
  productos: z.object({ nombre: z.string() }),
});

export const esquemaVenta = esquemaResumenVenta.extend({
  cliente_id: uuid.nullable(),
  subtotal: decimal,
  descuento: decimal,
  iva: decimal,
  motivo_anulacion: z.string().nullable(),
  venta_detalles: z.array(esquemaLineaVenta),
  venta_pagos: z.array(z.object({ medio: z.string(), monto: decimal })),
});

export const esquemaDevolucion = z.object({
  id: uuid,
  fecha: z.string(),
  motivo: z.string(),
  total: decimal,
  devolucion_detalles: z.array(z.object({ venta_detalle_id: uuid, cantidad: decimal })),
});

export const esquemaCostos = z.object({
  costo_total: decimal,
  utilidad: decimal,
  lineas: z.array(z.object({ orden: z.number(), costo_unitario: decimal, costo_total: decimal })),
});

export type Cliente = z.infer<typeof esquemaCliente>;
export type CalculoVenta = z.infer<typeof esquemaCalculoVenta>;
export type ResumenVenta = z.infer<typeof esquemaResumenVenta>;
export type Venta = z.infer<typeof esquemaVenta>;
export type Devolucion = z.infer<typeof esquemaDevolucion>;

export interface LineaVenta {
  presentacion_id: string;
  cantidad: string;
  descuento: string;
}

// -----------------------------------------------------------------------------
// Consultas
// -----------------------------------------------------------------------------
export const claves = {
  clientes: ['clientes'] as const,
  ventas: ['ventas'] as const,
  venta: (id: string) => ['ventas', id] as const,
  devoluciones: (id: string) => ['ventas', id, 'devoluciones'] as const,
  costos: (id: string) => ['ventas', id, 'costos'] as const,
  calculo: (lineas: LineaVenta[]) => ['ventas', 'calculo', lineas] as const,
};

export function useClientes() {
  return useQuery({
    queryKey: claves.clientes,
    queryFn: () =>
      consultar(
        supabase
          .from('clientes')
          .select('id,tipo_identificacion,identificacion,nombre,telefono,correo,direccion,fiado_permitido,limite_fiado:limite_fiado::text,activo')
          .order('nombre'),
        z.array(esquemaCliente),
      ),
  });
}

export function useVentas() {
  return useQuery({
    queryKey: claves.ventas,
    queryFn: () =>
      consultar(
        supabase
          .from('ventas')
          .select('id,fecha,creado_en,tipo_comprobante,total:total::text,estado,solicitud_anulacion,clientes(nombre)')
          .order('creado_en', { ascending: false })
          .limit(200),
        z.array(esquemaResumenVenta),
      ),
  });
}

// Solo columnas sin costos: el Vendedor no tiene permiso sobre las de costo (D-015).
const COLUMNAS_VENTA = [
  'id,fecha,creado_en,tipo_comprobante,estado,solicitud_anulacion,motivo_anulacion,cliente_id',
  'subtotal:subtotal::text,descuento:descuento::text,iva:iva::text,total:total::text',
  'clientes(nombre)',
  'venta_detalles(id,orden,cantidad:cantidad::text,precio_unitario:precio_unitario::text,' +
    'tarifa_iva:tarifa_iva::text,subtotal:subtotal::text,descuento:descuento::text,iva:iva::text,' +
    'total:total::text,presentaciones(nombre,factor:factor::text),productos(nombre))',
  'venta_pagos(medio,monto:monto::text)',
].join(',');

export function useVenta(id: string) {
  return useQuery({
    queryKey: claves.venta(id),
    queryFn: async () => {
      const filas = await consultar(
        supabase.from('ventas').select(COLUMNAS_VENTA).eq('id', id).limit(1),
        z.array(esquemaVenta),
      );
      const venta = filas[0];
      if (venta) venta.venta_detalles.sort((a, b) => a.orden - b.orden);
      return venta ?? null;
    },
  });
}

/** Solo el Dueño ve devoluciones (la RLS devuelve vacío al Vendedor). */
export function useDevoluciones(ventaId: string, habilitado: boolean) {
  return useQuery({
    queryKey: claves.devoluciones(ventaId),
    queryFn: () =>
      consultar(
        supabase
          .from('devoluciones')
          .select('id,fecha,motivo,total:total::text,devolucion_detalles(venta_detalle_id,cantidad:cantidad::text)')
          .eq('venta_id', ventaId)
          .order('creado_en'),
        z.array(esquemaDevolucion),
      ),
    enabled: habilitado,
  });
}

export function useCostosVenta(ventaId: string, habilitado: boolean) {
  return useQuery({
    queryKey: claves.costos(ventaId),
    queryFn: () => llamar('costos_venta', { p_venta_id: ventaId }, esquemaCostos),
    enabled: habilitado,
  });
}

/** Totales calculados por la base (D-011); solo con todas las líneas válidas. */
export function useCalculoVenta(lineas: LineaVenta[] | null) {
  return useQuery({
    queryKey: claves.calculo(lineas ?? []),
    queryFn: () => llamar('calcular_venta', { p_lineas: lineas }, esquemaCalculoVenta),
    enabled: lineas !== null && lineas.length > 0,
    placeholderData: (anterior) => anterior,
    retry: false,
  });
}

// -----------------------------------------------------------------------------
// Escrituras
// -----------------------------------------------------------------------------
function useInvalidarTrasVenta() {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: claves.ventas }),
      // Caja y fiado cambian con ventas, anulaciones y devoluciones (Fase 9).
      queryClient.invalidateQueries({ queryKey: ['caja'] }),
      queryClient.invalidateQueries({ queryKey: ['fiado'] }),
      queryClient.invalidateQueries({ queryKey: clavesCatalogo.productos }),
      queryClient.invalidateQueries({ queryKey: ['inventario'] }),
    ]);
}

export interface DatosVenta {
  lineas: LineaVenta[];
  pagos: { medio: Medio; monto: string }[] | null;
  clienteId: string | null;
  tipoComprobante: TipoComprobante;
  /** Se conserva entre reintentos: tocar dos veces «Cobrar» es una sola venta. */
  clave: string;
}

export function useRegistrarVenta() {
  const invalidar = useInvalidarTrasVenta();
  return useMutation({
    mutationFn: (d: DatosVenta) =>
      llamar(
        'registrar_venta',
        {
          p_lineas: d.lineas,
          p_pagos: d.pagos,
          p_cliente_id: d.clienteId,
          p_tipo_comprobante: d.tipoComprobante,
          p_clave_idempotencia: d.clave,
        },
        z.object({ venta_id: uuid, repetido: z.boolean(), total: decimal }),
      ),
    onSuccess: invalidar,
  });
}

export function useSolicitarAnulacion() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, motivo }: { id: string; motivo: string }) =>
      llamar('solicitar_anulacion_venta', { p_venta_id: id, p_motivo: motivo }, z.object({ venta_id: uuid })),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: claves.ventas }),
  });
}

export function useAnularVenta() {
  const invalidar = useInvalidarTrasVenta();
  return useMutation({
    mutationFn: ({ id, motivo }: { id: string; motivo: string }) =>
      llamar('anular_venta', { p_venta_id: id, p_motivo: motivo }, z.object({ venta_id: uuid, repetido: z.boolean() })),
    onSuccess: invalidar,
  });
}

export interface DatosDevolucion {
  ventaId: string;
  lineas: { venta_detalle_id: string; cantidad: string }[];
  motivo: string;
  forma: 'EFECTIVO' | 'ABONO_FIADO';
  clave: string;
}

export function useRegistrarDevolucion() {
  const invalidar = useInvalidarTrasVenta();
  return useMutation({
    mutationFn: (d: DatosDevolucion) =>
      llamar(
        'registrar_devolucion',
        {
          p_venta_id: d.ventaId,
          p_lineas: d.lineas,
          p_motivo: d.motivo,
          p_forma_reintegro: d.forma,
          p_clave_idempotencia: d.clave,
        },
        z.object({ devolucion_id: uuid, repetido: z.boolean(), total: decimal }),
      ),
    onSuccess: invalidar,
  });
}

export interface DatosCliente {
  tipo_identificacion?: 'RUC' | 'CEDULA' | 'PASAPORTE' | null;
  identificacion?: string | null;
  nombre?: string;
  telefono?: string | null;
  correo?: string | null;
  direccion?: string | null;
  activo?: boolean;
  fiado_permitido?: boolean;
  limite_fiado?: string;
}

export function useGuardarCliente() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, datos }: { id: string | null; datos: DatosCliente }) =>
      llamar('guardar_cliente', { p_id: id, p_datos: datos }, z.object({ id: uuid })),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: claves.clientes }),
  });
}

const formatoHora = new Intl.DateTimeFormat('es-EC', {
  day: '2-digit',
  month: 'short',
  hour: '2-digit',
  minute: '2-digit',
  timeZone: 'America/Guayaquil',
});
export function formatearMomento(iso: string): string {
  return formatoHora.format(new Date(iso));
}
