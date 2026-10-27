import { describe, expect, it } from 'vitest';
import { enlace, leerRuta, type Ruta } from './ruta';
import { nuevaClave } from './uuid';

const ID = 'f4ebe992-933c-4c1a-b528-3251f5e9ffb7';

describe('leerRuta', () => {
  it('lleva al listado de productos por defecto', () => {
    expect(leerRuta('')).toEqual({ nombre: 'productos' });
    expect(leerRuta('#/')).toEqual({ nombre: 'productos' });
  });

  it('lee cada pantalla y vuelve a construir su enlace', () => {
    const rutas: Ruta[] = [
      { nombre: 'productos' },
      { nombre: 'producto-nuevo' },
      { nombre: 'producto', id: ID },
      { nombre: 'ajuste', id: ID },
      { nombre: 'kardex', id: ID },
      { nombre: 'conteo' },
      { nombre: 'compras' },
      { nombre: 'compra-nueva' },
      { nombre: 'compra', id: ID },
      { nombre: 'proveedores' },
    ];
    for (const ruta of rutas) expect(leerRuta(enlace(ruta))).toEqual(ruta);
  });

  it('no acepta ids que no son uuid ni rutas desconocidas', () => {
    expect(leerRuta('#/productos/123')).toEqual({ nombre: 'no-encontrada' });
    expect(leerRuta(`#/productos/${ID}/borrar`)).toEqual({ nombre: 'no-encontrada' });
    expect(leerRuta('#/ventas')).toEqual({ nombre: 'no-encontrada' });
    expect(leerRuta('#/compras/abc')).toEqual({ nombre: 'no-encontrada' });
    expect(leerRuta(`#/compras/${ID}/editar`)).toEqual({ nombre: 'no-encontrada' });
  });
});

describe('nuevaClave', () => {
  const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

  it('genera un uuid v4 aunque no exista randomUUID (http en la red local)', () => {
    const sinRandomUUID = { getRandomValues: crypto.getRandomValues.bind(crypto) };
    const a = nuevaClave(sinRandomUUID);
    const b = nuevaClave(sinRandomUUID);
    expect(a).toMatch(UUID_V4);
    expect(a).not.toBe(b);
  });

  it('usa randomUUID cuando existe', () => {
    expect(nuevaClave()).toMatch(UUID_V4);
  });
});
