import { describe, expect, it } from 'vitest';
import { productosDelLibro, type HojaLeida } from './xlsx';

// Como el libro del dueño: título arriba, PRODUCTOS a la izquierda y SALIDAS a
// la derecha en la misma fila de encabezado.
const fritolay: HojaLeida = {
  nombre: 'FRITOLAY ',
  filas: [
    [null, 'VOLVER A MENÙ', null, null, null, null, 'CHITOS FRITOLAY'],
    [],
    [null, 'PRODUCTOS', null, null, null, null, 'SALIDAS'],
    ['CODIGO', 'ARTICULO', 'ENTRADAS', 'SALIDAS', 'STOCK', null, 'CODIGO', 'ARTICULO', 'FECHA', 'CANTIDAD'],
    ['300036732', ' k CHITOS NATURAL 67G', '309', '302', '7', null, '300036732', 'k CHITOS NATURAL 67G', '44924', '2'],
    ['300057107', 'NATUCHIPS PLATANITO\nNATURAL 49 G', '132', '128', '4'],
    ['300050205', 'DORITOS FLAMIN HOT 42 G', '36', '40', '-4'],
    ['3000', 'CHEESE TRIS QUESO 49G', '35', '32', '3'],
    [null, null, '0', '0', '0'],
    [],
  ],
};

describe('productosDelLibro', () => {
  it('toma la tabla de productos y no la de salidas', () => {
    expect(productosDelLibro([fritolay])).toEqual([
      { hoja: 'FRITOLAY', fila: 5, codigo: '300036732', nombre: 'k CHITOS NATURAL 67G', stock: 7 },
      { hoja: 'FRITOLAY', fila: 6, codigo: '300057107', nombre: 'NATUCHIPS PLATANITO NATURAL 49 G', stock: 4 },
      { hoja: 'FRITOLAY', fila: 7, codigo: '300050205', nombre: 'DORITOS FLAMIN HOT 42 G', stock: -4 },
      { hoja: 'FRITOLAY', fila: 8, codigo: '3000', nombre: 'CHEESE TRIS QUESO 49G', stock: 3 },
    ]);
  });

  it('ignora hojas sin tabla de productos, como el menú', () => {
    expect(productosDelLibro([{ nombre: 'MENU', filas: [['PIGGIS', 'FRITOLAY'], ['COCA-COLA']] }])).toEqual([]);
  });

  it('acepta otros nombres de columna y stock vacío', () => {
    expect(
      productosDelLibro([
        { nombre: 'X', filas: [['Código', 'Descripción', 'Existencias'], [null, 'Sal', null], ['77', 'Azúcar', 'abc']] },
      ]),
    ).toEqual([
      { hoja: 'X', fila: 2, codigo: null, nombre: 'Sal', stock: null },
      { hoja: 'X', fila: 3, codigo: '77', nombre: 'Azúcar', stock: null },
    ]);
  });
});
