import { useState } from 'react';
import { Calculator, ShoppingBag } from 'lucide-react';
import { useProductos } from '@/modules/catalogo/api';
import { useBorrador, useBorradorAjeno } from '@/shared/borrador';
import { leerDecimal } from '@/shared/decimal';
import { formatearCantidad, formatearCosto, formatearDinero, formatearPorcentaje } from '@/shared/formato';
import { enlace, navegar } from '@/shared/ruta';
import { ErrorDeNegocio } from '@/shared/rpc';
import { Aviso, AvisoError, Boton, Campo, Cargando, Encabezado, Tarjeta } from '@/shared/ui';
import { formatearFecha, useSimularCompra, type Simulacion } from './api';
import { EditorCompra, OPCIONES_INICIALES, prepararItems, type ItemCompra, type OpcionesCompra } from './LineasCompra';
import { BORRADOR_ITEMS_COMPRA, BORRADOR_OPCIONES_COMPRA } from './NuevaCompra';
import { ResumenUtilidad, TotalCompra } from './UtilidadCompra';

type Detalle = Simulacion['detalle'][number];

/** La cuenta de una línea, completa: unidades × precio = venta, menos el costo. */
function CuentaLinea({ detalle }: { detalle: Detalle }) {
  if (detalle.venta_total === null || detalle.precio_unidad === null) {
    return (
      <p className="text-sm text-gray-600">
        Entran {formatearCantidad(detalle.unidades)} a {formatearCosto(detalle.costo_unidad)} c/u · costo{' '}
        {formatearDinero(detalle.costo_total)}.{' '}
        {detalle.nuevo ? 'Escribe a cuánto venderías cada uno para ver lo que ganas.' : 'Sin precio de venta.'}
      </p>
    );
  }
  const ganancia = Number(detalle.venta_total) - Number(detalle.costo_total);
  const bruto = Number(detalle.unidades) * Number(detalle.precio_unidad);
  // Si el precio incluye IVA, a la bodega le queda la venta sin IVA.
  const conIvaDentro = bruto - Number(detalle.venta_total) > 0.01;
  return (
    <p className={`text-sm ${ganancia < 0 ? 'font-medium text-red-700' : 'text-gray-700'}`}>
      {formatearCantidad(detalle.unidades)} × {formatearCosto(detalle.precio_unidad)} ={' '}
      <strong>venta {formatearDinero(detalle.venta_total)}</strong>
      {conIvaDentro && ' sin IVA'} · costo {formatearDinero(detalle.costo_total)} ·{' '}
      <strong>
        {ganancia < 0 ? 'pierdes' : 'ganas'} {formatearDinero(Math.abs(ganancia).toFixed(2))}
      </strong>
      {Number(detalle.venta_total) > 0 && ` (${formatearPorcentaje((ganancia / Number(detalle.venta_total)).toFixed(4))})`}
    </p>
  );
}

/** Comparación con la última compra y precio para el margen pedido. */
function Consejos({ detalle, margen }: { detalle: Detalle; margen: string }) {
  const diferencia = detalle.costo_anterior === null ? 0 : Number(detalle.costo_unidad) - Number(detalle.costo_anterior);
  return (
    <div className="mt-0.5 flex flex-col gap-0.5 text-sm text-gray-600">
      {detalle.nuevo ? (
        <p>Cada unidad te costaría {formatearCosto(detalle.costo_unidad)}.</p>
      ) : detalle.costo_anterior === null ? (
        <p>Primera compra de este producto: no hay con qué comparar.</p>
      ) : (
        <p className={diferencia > 0.00005 ? 'text-amber-800' : undefined}>
          La última vez costó {formatearCosto(detalle.costo_anterior)}
          {detalle.fecha_anterior && ` (${formatearFecha(detalle.fecha_anterior)}`}
          {detalle.proveedor_anterior && `, ${detalle.proveedor_anterior}`}
          {detalle.fecha_anterior && ')'}
          {Math.abs(diferencia) < 0.00005
            ? ': igual que ahora.'
            : `: ahora ${formatearCosto(Math.abs(diferencia).toFixed(4))} más ${diferencia > 0 ? 'caro' : 'barato'}.`}
        </p>
      )}
      {detalle.precio_sugerido !== null && detalle.presentacion_venta && (
        <p>
          Para ganar {margen} %: vende {detalle.nuevo ? 'cada unidad' : `«${detalle.presentacion_venta}»`} a{' '}
          {formatearDinero(detalle.precio_sugerido)}
          {detalle.nuevo
            ? '.'
            : detalle.precio_actual !== null
              ? ` (hoy ${formatearDinero(detalle.precio_actual)}).`
              : ' (todavía no tiene precio).'}
        </p>
      )}
    </div>
  );
}

/**
 * «¿Cuánto gano?» (D-065): armar una compra para ver su costo y su utilidad
 * antes de decidir. No registra nada; si conviene, pasa a «Nueva compra», donde
 * los productos que aún no existen se crean al registrar (D-066 a D-068).
 */
export function CuantoGano() {
  const productos = useProductos();
  const ajeno = useBorradorAjeno();
  const [items, setItems, borrarItems] = useBorrador<ItemCompra[]>('simular:items', []);
  const [opciones, setOpciones, borrarOpciones] = useBorrador<OpcionesCompra>('simular:opciones', OPCIONES_INICIALES);
  const [margen, setMargen] = useBorrador('simular:margen', '20');
  const [mostrarErrores, setMostrarErrores] = useState(false);

  const { validados, lineas } = prepararItems(items, opciones);
  const margenLeido = leerDecimal(margen, { decimales: 2 });
  const margenValido = margenLeido.ok && Number(margenLeido.valor) < 90;
  const simulacion = useSimularCompra(lineas, margenValido ? String(Number(margenLeido.valor) / 100) : null);
  const datos = lineas ? simulacion.data : undefined;

  const lineaConError =
    simulacion.error instanceof ErrorDeNegocio
      ? Number((simulacion.error.detalle as { linea?: number } | null)?.linea ?? 0) - 1
      : -1;

  const pasarACompra = () => {
    setMostrarErrores(true);
    if (!lineas) return;
    const pendientes = (ajeno.leer<ItemCompra[]>(BORRADOR_ITEMS_COMPRA) ?? []).length;
    if (
      pendientes > 0 &&
      !window.confirm('Ya tienes una compra a medio escribir en «Nueva compra». ¿Reemplazar sus productos por estos?')
    ) {
      return;
    }
    ajeno.escribir(BORRADOR_ITEMS_COMPRA, items);
    ajeno.escribir(BORRADOR_OPCIONES_COMPRA, opciones);
    borrarItems();
    borrarOpciones();
    navegar({ nombre: 'compra-nueva' });
  };

  if (productos.isPending) return <Cargando />;
  const nuevos = items.filter((it) => !it.productoId).length;

  return (
    <>
      <Encabezado titulo="¿Cuánto gano?" volver={enlace({ nombre: 'compras' })} />
      <Aviso tipo="info">
        Arma la compra que estás pensando hacer para ver cuánto pagarías y cuánto ganarías. No se registra nada ni
        cambia el stock.
      </Aviso>

      <Tarjeta className="my-4">
        <div className="flex items-end gap-3">
          <div className="w-40">
            <Campo
              etiqueta="Margen que quieres (%)"
              inputMode="decimal"
              value={margen}
              onChange={(e) => setMargen(e.target.value)}
              error={margenValido ? undefined : 'Entre 0 y 89'}
            />
          </div>
          <p className="pb-3 text-sm text-gray-500">Para sugerirte el precio de venta de cada producto.</p>
        </div>
      </Tarjeta>

      <Tarjeta className="mb-4">
        <h2 className="mb-3 flex items-center gap-2 font-semibold">
          <Calculator className="size-5 text-emerald-700" aria-hidden />
          Productos
        </h2>
        <EditorCompra
          productos={productos.data ?? []}
          items={items}
          setItems={setItems}
          opciones={opciones}
          setOpciones={setOpciones}
          validados={validados}
          mostrarErrores={mostrarErrores}
          lineaConError={lineaConError}
          totalCalculado={datos?.compra.total}
          etiquetaPrecio="Venderías c/u a"
          debajo={(_, i) => {
            const d = datos?.detalle[i];
            if (!d) return null;
            return (
              <div className="mt-2">
                <CuentaLinea detalle={d} />
                <Consejos detalle={d} margen={margen} />
              </div>
            );
          }}
        />
      </Tarjeta>

      {lineas && <AvisoError error={simulacion.error} />}
      {datos && (
        <>
          <TotalCompra compra={datos.compra} />
          <ResumenUtilidad utilidad={datos} className="mb-4" />
        </>
      )}

      {items.length > 0 && (
        <div className="flex flex-col gap-2">
          {nuevos > 0 && (
            <p className="text-sm text-gray-600">
              Al registrar la compra, los productos nuevos se crean solos y quedan en «Productos» marcados «por
              completar» para que les pongas código, categoría y foto.
            </p>
          )}
          <div className="flex flex-wrap gap-2">
            <Boton onClick={pasarACompra} icono={ShoppingBag}>
              Registrar esta compra
            </Boton>
            <Boton
              variante="secundario"
              onClick={() => {
                borrarItems();
                setMostrarErrores(false);
              }}
            >
              Empezar de nuevo
            </Boton>
          </div>
        </div>
      )}
    </>
  );
}
