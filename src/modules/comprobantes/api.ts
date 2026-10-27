import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { consultar, llamar } from '@/lib/datos';
import { decimal, uuid } from '@/shared/esquemas';

export const esquemaLinea = z.object({
  id: uuid,
  orden: z.number(),
  codigo: z.string().nullable(),
  descripcion: z.string(),
  cantidad: decimal,
  precio_unitario: decimal,
  tarifa_iva: decimal,
  base: decimal,
  iva: decimal,
  presentacion_id: uuid.nullable(),
  presentaciones: z.object({ nombre: z.string(), productos: z.object({ nombre: z.string() }) }).nullable(),
});

export const esquemaComprobante = z.object({
  id: uuid,
  numero: z.string(),
  fecha_emision: z.string(),
  razon_social_comprador: z.string().nullable(),
  identificacion_comprador: z.string().nullable(),
  total: decimal,
  venta_id: uuid.nullable(),
  vinculo: z.enum(['VINCULADA', 'CREADA']).nullable(),
  comprobante_lineas: z.array(esquemaLinea),
});

export const esquemaCandidato = z.object({
  venta_id: uuid,
  creado_en: z.string(),
  total: decimal,
  tipo_comprobante: z.string(),
  cliente: z.string(),
});

export type Comprobante = z.infer<typeof esquemaComprobante>;
export type LineaComprobante = z.infer<typeof esquemaLinea>;
export type Candidato = z.infer<typeof esquemaCandidato>;

const claves = {
  lista: ['comprobantes'] as const,
  candidatos: (id: string) => ['comprobantes', id, 'candidatos'] as const,
};

export function useComprobantes() {
  return useQuery({
    queryKey: claves.lista,
    queryFn: async () => {
      const filas = await consultar(
        supabase
          .from('comprobantes')
          .select(
            'id,numero,fecha_emision,razon_social_comprador,identificacion_comprador,total:total::text,venta_id,vinculo,' +
              'comprobante_lineas(id,orden,codigo,descripcion,cantidad:cantidad::text,precio_unitario:precio_unitario::text,' +
              'tarifa_iva:tarifa_iva::text,base:base::text,iva:iva::text,' +
              'presentacion_id,presentaciones(nombre,productos(nombre)))',
          )
          .order('fecha_emision', { ascending: false })
          .order('numero', { ascending: false })
          .limit(200),
        z.array(esquemaComprobante),
      );
      for (const c of filas) c.comprobante_lineas.sort((a, b) => a.orden - b.orden);
      return filas;
    },
  });
}

export function useCandidatos(comprobanteId: string, habilitado: boolean) {
  return useQuery({
    queryKey: claves.candidatos(comprobanteId),
    queryFn: async () =>
      (await llamar('candidatos_comprobante', { p_comprobante_id: comprobanteId }, z.object({ ventas: z.array(esquemaCandidato) })))
        .ventas,
    enabled: habilitado,
  });
}

function useInvalidar() {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: claves.lista }),
      queryClient.invalidateQueries({ queryKey: ['ventas'] }),
      queryClient.invalidateQueries({ queryKey: ['productos'] }),
      queryClient.invalidateQueries({ queryKey: ['inventario'] }),
    ]);
}

export const esquemaImportacion = z.object({
  comprobante_id: uuid,
  repetido: z.boolean(),
  lineas: z.number().optional(),
  sin_asociar: z.number().optional(),
  numero: z.string().optional(),
  total: decimal.optional(),
});

export function useImportar() {
  const invalidar = useInvalidar();
  return useMutation({
    mutationFn: (xml: string) => llamar('importar_comprobante', { p_xml: xml }, esquemaImportacion),
    onSettled: invalidar,
  });
}

export function useAsociarLinea() {
  const invalidar = useInvalidar();
  return useMutation({
    mutationFn: (d: { lineaId: string; presentacionId: string }) =>
      llamar('asociar_linea_comprobante', { p_linea_id: d.lineaId, p_presentacion_id: d.presentacionId }, z.object({ linea_id: uuid })),
    onSuccess: invalidar,
  });
}

export function useVincular() {
  const invalidar = useInvalidar();
  return useMutation({
    mutationFn: (d: { comprobanteId: string; ventaId: string }) =>
      llamar('vincular_comprobante', { p_comprobante_id: d.comprobanteId, p_venta_id: d.ventaId }, z.object({ comprobante_id: uuid })),
    onSuccess: invalidar,
  });
}

export function useCrearVenta() {
  const invalidar = useInvalidar();
  return useMutation({
    mutationFn: (comprobanteId: string) =>
      llamar('crear_venta_de_comprobante', { p_comprobante_id: comprobanteId }, z.object({ venta_id: uuid, repetido: z.boolean() })),
    onSuccess: invalidar,
  });
}

export function useDescartar() {
  const invalidar = useInvalidar();
  return useMutation({
    mutationFn: (comprobanteId: string) =>
      llamar('descartar_comprobante', { p_comprobante_id: comprobanteId }, z.object({ comprobante_id: uuid })),
    onSuccess: invalidar,
  });
}

/** Presentación base (factor 1) del producto recién creado desde una línea. */
export async function presentacionBaseDe(productoId: string): Promise<string> {
  const filas = await consultar(
    supabase.from('presentaciones').select('id').eq('producto_id', productoId).eq('factor', 1).limit(1),
    z.array(z.object({ id: uuid })),
  );
  const id = filas[0]?.id;
  if (!id) throw new Error('El producto no tiene presentación base');
  return id;
}
