import { useEffect, useState } from 'react';

/**
 * Rutas de la app con `#hash`: no necesita configurar el servidor y no suma
 * dependencias. Cada pantalla nueva se agrega aquí.
 */
export type Ruta =
  | { nombre: 'productos' }
  | { nombre: 'producto-nuevo' }
  | { nombre: 'producto'; id: string }
  | { nombre: 'ajuste'; id: string }
  | { nombre: 'kardex'; id: string }
  | { nombre: 'conteo' }
  | { nombre: 'compras' }
  | { nombre: 'compra-nueva' }
  | { nombre: 'compra'; id: string }
  | { nombre: 'proveedores' }
  | { nombre: 'vender' }
  | { nombre: 'ventas' }
  | { nombre: 'venta'; id: string }
  | { nombre: 'clientes' }
  | { nombre: 'no-encontrada' };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function leerRuta(hash: string): Ruta {
  const partes = hash.replace(/^#\/?/, '').split('/').filter(Boolean);
  const [primera, segunda, tercera, ...resto] = partes;

  if (resto.length > 0) return { nombre: 'no-encontrada' };
  // Inicio: el punto de venta, lo que más se usa (HU-02).
  if (primera === undefined) return { nombre: 'vender' };
  if (primera === 'conteo' && segunda === undefined) return { nombre: 'conteo' };
  if (primera === 'proveedores' && segunda === undefined) return { nombre: 'proveedores' };
  if (primera === 'vender' && segunda === undefined) return { nombre: 'vender' };
  if (primera === 'clientes' && segunda === undefined) return { nombre: 'clientes' };
  if (primera === 'ventas') {
    if (tercera !== undefined) return { nombre: 'no-encontrada' };
    if (segunda === undefined) return { nombre: 'ventas' };
    return UUID.test(segunda) ? { nombre: 'venta', id: segunda } : { nombre: 'no-encontrada' };
  }
  if (primera === 'compras') {
    if (tercera !== undefined) return { nombre: 'no-encontrada' };
    if (segunda === undefined) return { nombre: 'compras' };
    if (segunda === 'nueva') return { nombre: 'compra-nueva' };
    return UUID.test(segunda) ? { nombre: 'compra', id: segunda } : { nombre: 'no-encontrada' };
  }
  if (primera !== 'productos') return { nombre: 'no-encontrada' };
  if (segunda === undefined) return { nombre: 'productos' };
  if (segunda === 'nuevo' && tercera === undefined) return { nombre: 'producto-nuevo' };
  if (!UUID.test(segunda)) return { nombre: 'no-encontrada' };
  if (tercera === undefined) return { nombre: 'producto', id: segunda };
  if (tercera === 'ajuste') return { nombre: 'ajuste', id: segunda };
  if (tercera === 'kardex') return { nombre: 'kardex', id: segunda };
  return { nombre: 'no-encontrada' };
}

export function enlace(ruta: Ruta): string {
  switch (ruta.nombre) {
    case 'productos':
    case 'no-encontrada':
      return '#/productos';
    case 'producto-nuevo':
      return '#/productos/nuevo';
    case 'producto':
      return `#/productos/${ruta.id}`;
    case 'ajuste':
      return `#/productos/${ruta.id}/ajuste`;
    case 'kardex':
      return `#/productos/${ruta.id}/kardex`;
    case 'conteo':
      return '#/conteo';
    case 'compras':
      return '#/compras';
    case 'compra-nueva':
      return '#/compras/nueva';
    case 'compra':
      return `#/compras/${ruta.id}`;
    case 'proveedores':
      return '#/proveedores';
    case 'vender':
      return '#/vender';
    case 'ventas':
      return '#/ventas';
    case 'venta':
      return `#/ventas/${ruta.id}`;
    case 'clientes':
      return '#/clientes';
  }
}

export function navegar(ruta: Ruta): void {
  window.location.hash = enlace(ruta);
}

export function useRuta(): Ruta {
  const [ruta, setRuta] = useState(() => leerRuta(window.location.hash));

  useEffect(() => {
    const alCambiar = () => {
      setRuta(leerRuta(window.location.hash));
      window.scrollTo(0, 0);
    };
    window.addEventListener('hashchange', alCambiar);
    return () => window.removeEventListener('hashchange', alCambiar);
  }, []);

  return ruta;
}
