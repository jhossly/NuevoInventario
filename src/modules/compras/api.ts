import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { consultar, llamar } from '@/lib/datos';
import { decimal, uuid } from '@/shared/esquemas';
import { claves as clavesCatalogo } from '@/modules/catalogo/api';

// -----------------------------------------------------------------------------
// Esquemas
// -----------------------------------------------------------------------------
export const TIPOS_IDENTIFICACION = { RUC: 'RUC', CEDULA: 'Cédula', PASAPORTE: 'Pasaporte' } as const;
export type TipoIdentificacion = keyof typeof TIPOS_IDENTIFICACION;

export const esquemaProveedor = z.object({
  id: uuid,
  tipo_identificacion: z.enum(['RUC', 'CEDULA', 'PASAPORTE']),
  identificacion: z.string(),
  nombre: z.string(),
  telefono: z.string().nullable(),
  activo: z.boolean(),
});

const esquemaResumenCompra = z.object({
  id: uuid,
  fecha: z.string(),
  numero_documento: z.string().nullable(),
  con_respaldo: z.boolean(),
  total: decimal,
  estado: z.enum(['CONFIRMADA', 'ANULADA']),
  proveedores: z.object({ nombre: z.string() }).nullable(),
});

const esquemaDetalle = z.object({
  orden: z.number(),
  cantidad: decimal,
  costo_unitario: decimal,
  descuento: decimal,
  tarifa_iva: decimal,
  subtotal: decimal,
  iva: decimal,
  cantidad_base: decimal,
  costo_unitario_base: decimal,
  presentaciones: z.object({ nombre: z.string() }),
  productos: z.object({ nombre: z.string(), unidad_base: z.enum(['UND', 'KG']) }),
});

export const esquemaCompra = esquemaResumenCompra.extend({
  subtotal: decimal,
  descuento: decimal,
  iva: decimal,
  iva_es_costo: z.boolean(),
  motivo_anulacion: z.string().nullable(),
  compra_detalles: z.array(esquemaDetalle),
});

export const esquemaCalculo = z.object({
  lineas: z.array(
    z.object({
      orden: z.number(),
      subtotal: decimal,
      descuento: decimal,
      iva: decimal,
      cantidad_base: decimal,
      costo_unitario_base: decimal,
    }),
  ),
  subtotal: decimal,
  descuento: decimal,
  iva: decimal,
  total: decimal,
});

export type Proveedor = z.infer<typeof esquemaProveedor>;
export type ResumenCompra = z.infer<typeof esquemaResumenCompra>;
export type Compra = z.infer<typeof esquemaCompra>;
export type Calculo = z.infer<typeof esquemaCalculo>;

/** Línea tal como la envía la interfaz: números como texto ya validado. */
export interface LineaCompra {
  presentacion_id: string;
  cantidad: string;
  costo_unitario: string;
  descuento: string;
}

// -----------------------------------------------------------------------------
// Consultas
// -----------------------------------------------------------------------------
export const claves = {
  proveedores: ['proveedores'] as const,
  compras: ['compras'] as const,
  compra: (id: string) => ['compras', id] as const,
  calculo: (lineas: LineaCompra[]) => ['compras', 'calculo', lineas] as const,
};

export function useProveedores() {
  return useQuery({
    queryKey: claves.proveedores,
    queryFn: () =>
      consultar(
        supabase.from('proveedores').select('id,tipo_identificacion,identificacion,nombre,telefono,activo').order('nombre'),
        z.array(esquemaProveedor),
      ),
  });
}

export function useCompras() {
  return useQuery({
    queryKey: claves.compras,
    queryFn: () =>
      consultar(
        supabase
          .from('compras')
          .select('id,fecha,numero_documento,con_respaldo,total:total::text,estado,proveedores(nombre)')
          .order('fecha', { ascending: false })
          .order('creado_en', { ascending: false })
          .limit(200),
        z.array(esquemaResumenCompra),
      ),
  });
}

const COLUMNAS_COMPRA = [
  'id,fecha,numero_documento,con_respaldo,estado,motivo_anulacion,iva_es_costo',
  'subtotal:subtotal::text,descuento:descuento::text,iva:iva::text,total:total::text',
  'proveedores(nombre)',
  'compra_detalles(orden,cantidad:cantidad::text,costo_unitario:costo_unitario::text,' +
    'descuento:descuento::text,tarifa_iva:tarifa_iva::text,subtotal:subtotal::text,iva:iva::text,' +
    'cantidad_base:cantidad_base::text,costo_unitario_base:costo_unitario_base::text,' +
    'presentaciones(nombre),productos(nombre,unidad_base))',
].join(',');

export function useCompra(id: string) {
  return useQuery({
    queryKey: claves.compra(id),
    queryFn: async () => {
      const filas = await consultar(
        supabase.from('compras').select(COLUMNAS_COMPRA).eq('id', id).limit(1),
        z.array(esquemaCompra),
      );
      const compra = filas[0];
      if (compra) compra.compra_detalles.sort((a, b) => a.orden - b.orden);
      return compra ?? null;
    },
  });
}

/**
 * Vista previa con los cálculos de la base (D-011): la interfaz no repite
 * redondeos de IVA ni de costos. Solo se pide cuando todas las líneas son válidas.
 */
export function useCalculoCompra(lineas: LineaCompra[] | null) {
  return useQuery({
    queryKey: claves.calculo(lineas ?? []),
    queryFn: () => llamar('calcular_compra', { p_lineas: lineas }, esquemaCalculo),
    enabled: lineas !== null && lineas.length > 0,
    placeholderData: (anterior) => anterior,
    retry: false,
  });
}

// -----------------------------------------------------------------------------
// Escrituras
// -----------------------------------------------------------------------------
const esquemaId = z.object({ id: uuid });

export interface DatosProveedor {
  tipo_identificacion?: TipoIdentificacion;
  identificacion?: string;
  nombre?: string;
  telefono?: string | null;
  activo?: boolean;
}

export function useGuardarProveedor() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, datos }: { id: string | null; datos: DatosProveedor }) =>
      llamar('guardar_proveedor', { p_id: id, p_datos: datos }, esquemaId),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: claves.proveedores }),
  });
}

function useInvalidarTrasCompra() {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: claves.compras }),
      queryClient.invalidateQueries({ queryKey: clavesCatalogo.productos }),
      queryClient.invalidateQueries({ queryKey: ['inventario'] }),
    ]);
}

export interface DatosCompra {
  proveedorId: string | null;
  conRespaldo: boolean;
  numeroDocumento: string | null;
  fecha: string | null;
  lineas: LineaCompra[];
  /** Se conserva entre reintentos para que no se duplique la compra. */
  clave: string;
}

export function useRegistrarCompra() {
  const invalidar = useInvalidarTrasCompra();
  return useMutation({
    mutationFn: (d: DatosCompra) =>
      llamar(
        'registrar_compra',
        {
          p_proveedor_id: d.proveedorId,
          p_con_respaldo: d.conRespaldo,
          p_numero_documento: d.numeroDocumento,
          p_fecha: d.fecha,
          p_lineas: d.lineas,
          p_clave_idempotencia: d.clave,
        },
        z.object({ compra_id: uuid, repetido: z.boolean(), total: decimal }),
      ),
    onSuccess: invalidar,
  });
}

export function useAnularCompra() {
  const invalidar = useInvalidarTrasCompra();
  return useMutation({
    mutationFn: ({ id, motivo }: { id: string; motivo: string }) =>
      llamar('anular_compra', { p_compra_id: id, p_motivo: motivo }, z.object({ compra_id: uuid, repetido: z.boolean() })),
    onSuccess: invalidar,
  });
}

/** "2026-10-27" → "27 oct 2026" (fechas de negocio, sin hora). */
const formatoFecha = new Intl.DateTimeFormat('es-EC', { day: '2-digit', month: 'short', year: 'numeric', timeZone: 'UTC' });
export function formatearFecha(fecha: string): string {
  return formatoFecha.format(new Date(`${fecha}T00:00:00Z`));
}
