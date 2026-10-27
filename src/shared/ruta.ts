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
  | { nombre: 'no-encontrada' };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function leerRuta(hash: string): Ruta {
  const partes = hash.replace(/^#\/?/, '').split('/').filter(Boolean);
  const [primera, segunda, tercera, ...resto] = partes;

  if (resto.length > 0) return { nombre: 'no-encontrada' };
  if (primera === undefined) return { nombre: 'productos' };
  if (primera === 'conteo' && segunda === undefined) return { nombre: 'conteo' };
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
