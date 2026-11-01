import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { consultar, llamar } from '@/lib/datos';
import { uuid } from '@/shared/esquemas';

export const ESTADOS_FACTURA = {
  PENDIENTE: 'Sin enviar al SRI',
  RECIBIDA: 'El SRI la está revisando',
  DEVUELTA: 'Devuelta por el SRI',
  NO_AUTORIZADA: 'No autorizada por el SRI',
  AUTORIZADA: 'Autorizada por el SRI',
} as const;

const esquemaMensaje = z.object({
  identificador: z.string().optional(),
  mensaje: z.string().optional(),
  informacionAdicional: z.string().nullish(),
});

export const esquemaFactura = z.object({
  id: uuid,
  venta_id: uuid,
  ambiente: z.string(),
  numero: z.string(),
  clave_acceso: z.string(),
  estado: z.enum(['PENDIENTE', 'RECIBIDA', 'DEVUELTA', 'NO_AUTORIZADA', 'AUTORIZADA']),
  xml: z.string(),
  xml_firmado: z.string().nullable(),
  numero_autorizacion: z.string().nullable(),
  fecha_autorizacion: z.string().nullable(),
  mensajes: z.array(esquemaMensaje),
});
export type Factura = z.infer<typeof esquemaFactura>;

const COLUMNAS =
  'id,venta_id,ambiente,numero,clave_acceso,estado,xml,xml_firmado,numero_autorizacion,fecha_autorizacion,mensajes';

const clave = (ventaId: string) => ['factura', ventaId] as const;

/** La factura más reciente de la venta; null si todavía no se emitió. */
export function useFacturaDeVenta(ventaId: string) {
  return useQuery({
    queryKey: clave(ventaId),
    queryFn: async () => {
      const filas = await consultar(
        supabase
          .from('facturas_electronicas')
          .select(COLUMNAS)
          .eq('venta_id', ventaId)
          .order('creado_en', { ascending: false })
          .limit(1),
        z.array(esquemaFactura),
      );
      return filas[0] ?? null;
    },
  });
}

const esquemaEmision = z.union([
  z.object({ ok: z.literal(true), data: z.object({ estado: z.string() }).passthrough() }),
  z.object({ ok: z.literal(false), error: z.object({ codigo: z.string(), mensaje: z.string().nullish() }) }),
]);

async function emitir(ventaId: string): Promise<string> {
  const { data, error } = await supabase.functions.invoke('facturar', { body: { venta_id: ventaId } });
  if (error) throw new Error('No se pudo conectar con el servicio de facturación. La venta está guardada.');
  const r = esquemaEmision.parse(data);
  if (!r.ok) throw new Error(r.error.mensaje ?? 'No se pudo emitir la factura');
  return r.data.estado;
}

export function useEmitirFactura() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: emitir,
    // También tras un error: la base pudo guardar el estado antes de fallar.
    onSettled: (_r, _e, ventaId) => queryClient.invalidateQueries({ queryKey: clave(ventaId) }),
  });
}

// -----------------------------------------------------------------------------
// Configuración (solo Dueño)
// -----------------------------------------------------------------------------
export const esquemaConfiguracion = z.object({
  facturacion_activa: z.boolean(),
  ambiente_sri: z.enum(['1', '2']),
  establecimiento: z.string(),
  punto_emision: z.string(),
  obligado_contabilidad: z.boolean(),
  leyenda_rimpe: z.string().nullable(),
});
export type Configuracion = z.infer<typeof esquemaConfiguracion>;

export function useConfiguracionFacturacion() {
  return useQuery({
    queryKey: ['facturacion-config'],
    queryFn: async () => {
      const filas = await consultar(
        supabase
          .from('empresas')
          .select('facturacion_activa,ambiente_sri,establecimiento,punto_emision,obligado_contabilidad,leyenda_rimpe')
          .limit(1),
        z.array(esquemaConfiguracion),
      );
      const config = filas[0];
      if (!config) throw new Error('No se encontró la bodega');
      const secuencias = await consultar(
        supabase
          .from('secuencias_factura')
          .select('ultimo')
          .eq('ambiente', config.ambiente_sri)
          .eq('estab', config.establecimiento)
          .eq('pto_emi', config.punto_emision),
        z.array(z.object({ ultimo: z.number() })),
      );
      return { ...config, ultimo: secuencias[0]?.ultimo ?? 0 };
    },
  });
}

export function useGuardarFacturacion() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (datos: Partial<Configuracion> & { ultimo_secuencial?: number }) =>
      llamar('guardar_facturacion', { p_datos: datos }, z.object({ id: uuid })),
    onSuccess: () => queryClient.invalidateQueries(),
  });
}
