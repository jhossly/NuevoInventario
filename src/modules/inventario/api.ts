import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { consultar, llamar } from '@/lib/datos';
import { decimal, uuid } from '@/shared/esquemas';
import { claves as clavesCatalogo } from '@/modules/catalogo/api';

// -----------------------------------------------------------------------------
// Esquemas
// -----------------------------------------------------------------------------
export const esquemaValorizado = z.object({
  productos: z.array(
    z.object({
      producto_id: uuid,
      nombre: z.string(),
      unidad_base: z.string(),
      controla_stock: z.boolean(),
      cantidad: decimal,
      costo_promedio: decimal.nullable(),
      ultimo_costo: decimal.nullable(),
      valor_total: decimal,
    }),
  ),
  valor_total: decimal,
});

export const TIPOS_MOVIMIENTO = {
  APERTURA: 'Apertura',
  COMPRA: 'Compra',
  VENTA: 'Venta',
  DEVOLUCION_VENTA: 'Devolución de venta',
  ANULACION_VENTA: 'Anulación de venta',
  AJUSTE: 'Ajuste',
  MERMA: 'Merma',
  CONTEO: 'Conteo físico',
} as const;

export const esquemaMovimiento = z.object({
  id: uuid,
  fecha: z.string(),
  tipo: z.enum(Object.keys(TIPOS_MOVIMIENTO) as [keyof typeof TIPOS_MOVIMIENTO, ...(keyof typeof TIPOS_MOVIMIENTO)[]]),
  cantidad: decimal,
  costo_unitario: decimal,
  valor: decimal,
  saldo_cantidad: decimal,
  saldo_valor: decimal,
  motivo: z.string().nullable(),
});

export const esquemaAjuste = z.object({
  movimiento_id: uuid,
  repetido: z.boolean(),
  saldo_cantidad: decimal,
  saldo_valor: decimal,
});

export const esquemaBorrador = z.object({
  id: uuid,
  fecha: z.string(),
  nota: z.string().nullable(),
  conteo_detalles: z.array(z.object({ producto_id: uuid, cantidad_contada: decimal })),
});

export type Valorizado = z.infer<typeof esquemaValorizado>;
export type Movimiento = z.infer<typeof esquemaMovimiento>;
export type TipoAjuste = 'APERTURA' | 'AJUSTE' | 'MERMA';

// -----------------------------------------------------------------------------
// Consultas
// -----------------------------------------------------------------------------
export const claves = {
  valorizado: ['inventario', 'valorizado'] as const,
  kardex: (productoId: string) => ['inventario', 'kardex', productoId] as const,
  borrador: ['inventario', 'conteo-borrador'] as const,
};

/** Solo para quien ve costos; para el resto la base responde SIN_PERMISO. */
export function useValorizado(habilitado: boolean) {
  return useQuery({
    queryKey: claves.valorizado,
    queryFn: () => llamar('inventario_valorizado', {}, esquemaValorizado),
    enabled: habilitado,
  });
}

export function useKardex(productoId: string) {
  return useQuery({
    queryKey: claves.kardex(productoId),
    queryFn: () =>
      consultar(
        supabase
          .from('movimientos_inventario')
          .select(
            'id,fecha,tipo,cantidad:cantidad::text,costo_unitario:costo_unitario::text,valor:valor::text,' +
              'saldo_cantidad:saldo_cantidad::text,saldo_valor:saldo_valor::text,motivo',
          )
          .eq('producto_id', productoId)
          .order('secuencia', { ascending: false })
          .limit(200),
        z.array(esquemaMovimiento),
      ),
  });
}

/** El conteo en borrador más reciente, para seguirlo donde quedó. */
export function useConteoBorrador() {
  return useQuery({
    queryKey: claves.borrador,
    queryFn: async () => {
      const filas = await consultar(
        supabase
          .from('conteos')
          .select('id,fecha,nota,conteo_detalles(producto_id,cantidad_contada:cantidad_contada::text)')
          .eq('estado', 'BORRADOR')
          .order('creado_en', { ascending: false })
          .limit(1),
        z.array(esquemaBorrador),
      );
      return filas[0] ?? null;
    },
  });
}

// -----------------------------------------------------------------------------
// Escrituras
// -----------------------------------------------------------------------------
function useInvalidarInventario() {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: clavesCatalogo.productos }),
      queryClient.invalidateQueries({ queryKey: ['inventario'] }),
    ]);
}

export interface DatosAjuste {
  productoId: string;
  tipo: TipoAjuste;
  /** Con signo, en unidad base, como texto. */
  cantidad: string;
  costoUnitario: string | null;
  motivo: string | null;
  /** Se conserva entre reintentos para que no se duplique el ajuste. */
  clave: string;
}

export function useAjustar() {
  const invalidar = useInvalidarInventario();
  return useMutation({
    mutationFn: (d: DatosAjuste) =>
      llamar(
        'ajustar_inventario',
        {
          p_producto_id: d.productoId,
          p_tipo: d.tipo,
          p_cantidad: d.cantidad,
          p_costo_unitario: d.costoUnitario,
          p_motivo: d.motivo,
          p_clave_idempotencia: d.clave,
        },
        esquemaAjuste,
      ),
    onSuccess: invalidar,
  });
}

export interface LineaConteo {
  producto_id: string;
  cantidad_contada: string;
}

export function useGuardarConteo() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (d: { conteoId: string | null; lineas: LineaConteo[]; nota: string | null }) =>
      llamar(
        'guardar_conteo',
        { p_conteo_id: d.conteoId, p_detalles: d.lineas, p_nota: d.nota, p_fecha: null },
        z.object({ conteo_id: uuid, lineas: z.number() }),
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: claves.borrador }),
  });
}

export function useConfirmarConteo() {
  const invalidar = useInvalidarInventario();
  return useMutation({
    mutationFn: (conteoId: string) =>
      llamar(
        'confirmar_conteo',
        { p_conteo_id: conteoId },
        z.object({ conteo_id: uuid, repetido: z.boolean(), movimientos: z.number() }),
      ),
    onSuccess: invalidar,
  });
}
