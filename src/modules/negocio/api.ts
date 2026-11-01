import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { consultar, llamar } from '@/lib/datos';
import { decimal, uuid } from '@/shared/esquemas';

export const esquemaNegocio = z.object({
  id: uuid,
  ruc: z.string(),
  razon_social: z.string(),
  nombre_comercial: z.string().nullable(),
  direccion: z.string().nullable(),
  telefono: z.string().nullable(),
  logo: z.string().nullable(),
  precios_incluyen_iva: z.boolean(),
  iva_compras_es_costo: z.boolean(),
  vendedor_ve_costos: z.boolean(),
  descuento_max_vendedor: decimal,
  monto_max_consumidor_final: decimal,
  monto_max_sin_comprobante: decimal,
  limite_ingresos_rimpe: decimal,
});
export type Negocio = z.infer<typeof esquemaNegocio>;

const COLUMNAS = [
  'id',
  'ruc',
  'razon_social',
  'nombre_comercial',
  'direccion',
  'telefono',
  'logo',
  'precios_incluyen_iva',
  'iva_compras_es_costo',
  'vendedor_ve_costos',
  'descuento_max_vendedor:descuento_max_vendedor::text',
  'monto_max_consumidor_final:monto_max_consumidor_final::text',
  'monto_max_sin_comprobante:monto_max_sin_comprobante::text',
  'limite_ingresos_rimpe:limite_ingresos_rimpe::text',
].join(',');

export function useNegocio() {
  return useQuery({
    queryKey: ['mi-negocio'],
    queryFn: async () => {
      const filas = await consultar(supabase.from('empresas').select(COLUMNAS).limit(1), z.array(esquemaNegocio));
      const negocio = filas[0];
      if (!negocio) throw new Error('No se encontró la bodega');
      return negocio;
    },
  });
}

export type DatosNegocio = Partial<Omit<Negocio, 'id' | 'ruc'>>;

export function useGuardarNegocio() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (datos: DatosNegocio) => llamar('guardar_mi_negocio', { p_datos: datos }, z.object({ id: uuid })),
    // Nombre, logo, IVA y límites se usan en toda la app.
    onSuccess: () => queryClient.invalidateQueries(),
  });
}

const LADO_LOGO = 256;
const LARGO_MAXIMO = 200_000;

/**
 * Reduce la imagen en el navegador y la devuelve como data URL. Lo guardado
 * es un archivo nuevo dibujado en un canvas, no el que subió la persona.
 */
export async function reducirLogo(archivo: File): Promise<string> {
  const imagen = await createImageBitmap(archivo);
  const escala = Math.min(1, LADO_LOGO / Math.max(imagen.width, imagen.height));
  const lienzo = document.createElement('canvas');
  lienzo.width = Math.max(1, Math.round(imagen.width * escala));
  lienzo.height = Math.max(1, Math.round(imagen.height * escala));
  const dibujo = lienzo.getContext('2d');
  if (!dibujo) throw new Error('Este navegador no puede procesar la imagen');
  dibujo.drawImage(imagen, 0, 0, lienzo.width, lienzo.height);
  imagen.close();
  const resultado = lienzo.toDataURL('image/webp', 0.85);
  if (resultado.length > LARGO_MAXIMO) throw new Error('La imagen es demasiado pesada');
  return resultado;
}
