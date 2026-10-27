import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { consultar, llamar } from '@/lib/datos';
import { decimal, uuid } from '@/shared/esquemas';

// -----------------------------------------------------------------------------
// Esquemas de lo que devuelve la base
// -----------------------------------------------------------------------------
export const esquemaPresentacion = z.object({
  id: uuid,
  nombre: z.string(),
  factor: decimal,
  precio_venta: decimal.nullable(),
  codigo_barras: z.string().nullable(),
  se_vende: z.boolean(),
  se_compra: z.boolean(),
  activo: z.boolean(),
});

export const esquemaProducto = z.object({
  id: uuid,
  nombre: z.string(),
  unidad_base: z.enum(['UND', 'KG']),
  tarifa_iva: decimal,
  stock_minimo: decimal,
  activo: z.boolean(),
  categoria_id: uuid.nullable(),
  categorias: z.object({ nombre: z.string() }).nullable(),
  presentaciones: z.array(esquemaPresentacion),
  // existencias solo expone `cantidad` al navegador (D-020).
  existencias: z.array(z.object({ cantidad: decimal })),
});

export const esquemaCategoria = z.object({ id: uuid, nombre: z.string() });

export type Presentacion = z.infer<typeof esquemaPresentacion>;
export type Producto = z.infer<typeof esquemaProducto>;
export type Categoria = z.infer<typeof esquemaCategoria>;

const esquemaId = z.object({ id: uuid });

// Los numeric se piden como texto (D-019). existencias se pide por columna:
// `select *` fallaría por el permiso por columna.
const COLUMNAS_PRODUCTO = [
  'id',
  'nombre',
  'unidad_base',
  'tarifa_iva:tarifa_iva::text',
  'stock_minimo:stock_minimo::text',
  'activo',
  'categoria_id',
  'categorias(nombre)',
  'presentaciones(id,nombre,factor:factor::text,precio_venta:precio_venta::text,codigo_barras,se_vende,se_compra,activo)',
  'existencias(cantidad:cantidad::text)',
].join(',');

// -----------------------------------------------------------------------------
// Ayudas de lectura
// -----------------------------------------------------------------------------
export const UNIDADES = { UND: 'unidades', KG: 'kg' } as const;

export function stockDe(producto: Producto): string {
  return producto.existencias[0]?.cantidad ?? '0';
}

/** La presentación base es la de factor 1 creada con el producto. */
export function presentacionBase(producto: Producto): Presentacion | undefined {
  return producto.presentaciones.find((p) => Number(p.factor) === 1) ?? producto.presentaciones[0];
}

export function bajoStock(producto: Producto): boolean {
  const minimo = Number(producto.stock_minimo);
  return producto.activo && minimo > 0 && Number(stockDe(producto)) <= minimo;
}

/** Orden estable: la base primero, luego por factor. */
export function presentacionesOrdenadas(producto: Producto): Presentacion[] {
  return [...producto.presentaciones].sort((a, b) => Number(a.factor) - Number(b.factor) || a.nombre.localeCompare(b.nombre));
}

// -----------------------------------------------------------------------------
// Consultas
// -----------------------------------------------------------------------------
export const claves = {
  productos: ['productos'] as const,
  categorias: ['categorias'] as const,
};

export function useProductos() {
  return useQuery({
    queryKey: claves.productos,
    queryFn: () =>
      consultar(supabase.from('productos').select(COLUMNAS_PRODUCTO).order('nombre'), z.array(esquemaProducto)),
  });
}

/** Un producto sale de la misma lista: el catálogo de una bodega es pequeño. */
export function useProducto(id: string) {
  const productos = useProductos();
  return { ...productos, data: productos.data?.find((p) => p.id === id) };
}

export function useCategorias() {
  return useQuery({
    queryKey: claves.categorias,
    queryFn: () => consultar(supabase.from('categorias').select('id,nombre').order('nombre'), z.array(esquemaCategoria)),
  });
}

// -----------------------------------------------------------------------------
// Escrituras (solo por funciones)
// -----------------------------------------------------------------------------
export interface DatosProducto {
  nombre?: string;
  categoria_id?: string | null;
  unidad_base?: 'UND' | 'KG';
  tarifa_iva?: string;
  stock_minimo?: string;
  activo?: boolean;
  precio_venta?: string | null;
  codigo_barras?: string | null;
}

export interface DatosPresentacion {
  producto_id?: string;
  nombre?: string;
  factor?: string;
  precio_venta?: string | null;
  codigo_barras?: string | null;
  se_vende?: boolean;
  se_compra?: boolean;
  activo?: boolean;
}

function useInvalidarCatalogo() {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: claves.productos }),
      queryClient.invalidateQueries({ queryKey: ['inventario'] }),
    ]);
}

export function useGuardarProducto() {
  const invalidar = useInvalidarCatalogo();
  return useMutation({
    mutationFn: ({ id, datos }: { id: string | null; datos: DatosProducto }) =>
      llamar('guardar_producto', { p_id: id, p_datos: datos }, esquemaId),
    onSuccess: invalidar,
  });
}

export function useGuardarPresentacion() {
  const invalidar = useInvalidarCatalogo();
  return useMutation({
    mutationFn: ({ id, datos }: { id: string | null; datos: DatosPresentacion }) =>
      llamar('guardar_presentacion', { p_id: id, p_datos: datos }, esquemaId),
    onSuccess: invalidar,
  });
}

export function useGuardarCategoria() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (nombre: string) => llamar('guardar_categoria', { p_id: null, p_nombre: nombre }, esquemaId),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: claves.categorias }),
  });
}
