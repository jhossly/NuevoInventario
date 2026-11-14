import { useState } from 'react';
import { Calculator, PackagePlus, ShoppingBag } from 'lucide-react';
import { useProductos } from '@/modules/catalogo/api';
import { useBorrador, useBorradorAjeno } from '@/shared/borrador';
import { leerDecimal } from '@/shared/decimal';
import { formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace, navegar } from '@/shared/ruta';
import { ErrorDeNegocio } from '@/shared/rpc';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Cargando, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import { formatearFecha, useSimularCompra, type Simulacion } from './api';
import { EditorLineas, lineasParaEnviar, type LineaEnPantalla } from './LineasCompra';
import { BORRADOR_LINEAS_COMPRA } from './NuevaCompra';
import { LineaUtilidad, ResumenUtilidad, TotalCompra } from './UtilidadCompra';

/** Un producto que todavía no está en el catálogo (D-066). */
interface NuevoEnPantalla {
  local: string;
  nombre: string;
  /** Unidades que trae cada bulto. */
  factor: string;
  cantidad: string;
  costo: string;
  tarifa: string;
  /** Precio por unidad al que se piensa vender; puede quedar vacío. */
  precio: string;
}

type ErroresNuevo = Partial<Record<'nombre' | 'factor' | 'cantidad' | 'costo' | 'precio', string>>;

function validarNuevo(n: NuevoEnPantalla): { errores: ErroresNuevo; linea: object | null } {
  const errores: ErroresNuevo = {};
  const factor = leerDecimal(n.factor, { decimales: 3, permitirCero: false });
  const cantidad = leerDecimal(n.cantidad, { decimales: 3, permitirCero: false });
  const costo = leerDecimal(n.costo, { decimales: 6 });
  const precio = n.precio.trim() === '' ? ({ ok: true, valor: '' } as const) : leerDecimal(n.precio, { decimales: 4 });
  if (n.nombre.trim() === '') errores.nombre = 'Escribe el nombre';
  if (!factor.ok) errores.factor = factor.mensaje;
  if (!cantidad.ok) errores.cantidad = cantidad.mensaje;
  if (!costo.ok) errores.costo = costo.mensaje;
  if (!precio.ok) errores.precio = precio.mensaje;
  if (Object.keys(errores).length > 0 || !factor.ok || !cantidad.ok || !costo.ok || !precio.ok) {
    return { errores, linea: null };
  }
  return {
    errores,
    linea: {
      nuevo: { nombre: n.nombre.trim(), factor: factor.valor, precio_venta: precio.valor },
      cantidad: cantidad.valor,
      costo_unitario: costo.valor,
      tarifa_iva: n.tarifa,
    },
  };
}

/** Comparación con la última compra y precio para el margen pedido. */
function Consejos({ detalle, margen, nuevo }: { detalle: Simulacion['detalle'][number]; margen: string; nuevo?: boolean }) {
  const diferencia = detalle.costo_anterior === null ? 0 : Number(detalle.costo_unidad) - Number(detalle.costo_anterior);
  return (
    <div className="mt-1 flex flex-col gap-0.5 text-sm text-gray-600">
      {nuevo ? (
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
          Para ganar {margen} %: vende {nuevo ? 'cada unidad' : `«${detalle.presentacion_venta}»`} a{' '}
          {formatearDinero(detalle.precio_sugerido)}
          {nuevo
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
 * antes de decidir. No registra nada; si conviene, pasa a «Nueva compra». Los
 * productos que aún no existen se describen a mano (D-066).
 */
export function CuantoGano() {
  const productos = useProductos();
  const ajeno = useBorradorAjeno();
  const [lineas, setLineas, borrarLineas] = useBorrador<LineaEnPantalla[]>('simular:lineas', []);
  const [nuevos, setNuevos, borrarNuevos] = useBorrador<NuevoEnPantalla[]>('simular:nuevos', []);
  const [margen, setMargen] = useBorrador('simular:margen', '20');
  const [mostrarErrores, setMostrarErrores] = useState(false);

  const existentes = lineasParaEnviar(lineas);
  const nuevosValidados = nuevos.map(validarNuevo);
  const existentesOk = lineas.length === 0 || existentes.todasValidas;
  const nuevosOk = nuevosValidados.every((v) => v.linea !== null);
  const hayAlgo = lineas.length + nuevos.length > 0;
  const paraEnviar =
    hayAlgo && existentesOk && nuevosOk
      ? [...(existentes.paraEnviar ?? []), ...nuevosValidados.map((v) => v.linea as object)]
      : null;

  const margenLeido = leerDecimal(margen, { decimales: 2 });
  const margenValido = margenLeido.ok && Number(margenLeido.valor) < 90;
  const simulacion = useSimularCompra(paraEnviar, margenValido ? String(Number(margenLeido.valor) / 100) : null);
  const datos = paraEnviar ? simulacion.data : undefined;

  // La base cuenta las líneas desde 1: primero las existentes y luego las nuevas.
  const lineaConError =
    simulacion.error instanceof ErrorDeNegocio
      ? Number((simulacion.error.detalle as { linea?: number } | null)?.linea ?? 0) - 1
      : -1;

  const cambiarNuevo = (indice: number, cambios: Partial<NuevoEnPantalla>) =>
    setNuevos((ns) => ns.map((n, i) => (i === indice ? { ...n, ...cambios } : n)));

  const pasarACompra = () => {
    setMostrarErrores(true);
    if (!existentes.paraEnviar || nuevos.length > 0) return;
    const pendientes = ajeno.leer<LineaEnPantalla[]>(BORRADOR_LINEAS_COMPRA) ?? [];
    if (
      pendientes.length > 0 &&
      !window.confirm('Ya tienes una compra a medio escribir en «Nueva compra». ¿Reemplazar sus productos por estos?')
    ) {
      return;
    }
    ajeno.escribir(BORRADOR_LINEAS_COMPRA, lineas);
    borrarLineas();
    navegar({ nombre: 'compra-nueva' });
  };

  if (productos.isPending) return <Cargando />;

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
        <h2 className="mb-2 flex items-center gap-2 font-semibold">
          <Calculator className="size-5 text-emerald-700" aria-hidden />
          Productos que ya tienes
        </h2>
        <EditorLineas
          productos={productos.data ?? []}
          lineas={lineas}
          setLineas={setLineas}
          validadas={existentes.validadas}
          mostrarErrores={mostrarErrores}
          lineaConError={lineaConError}
          debajo={(_, i) => {
            const linea = datos?.lineas[i];
            const detalle = datos?.detalle[i];
            if (!linea || !detalle) return null;
            return (
              <div className="mt-2">
                <LineaUtilidad linea={linea} />
                <Consejos detalle={detalle} margen={margen} />
              </div>
            );
          }}
        />
      </Tarjeta>

      <Tarjeta className="mb-4">
        <h2 className="mb-1 flex items-center gap-2 font-semibold">
          <PackagePlus className="size-5 text-emerald-700" aria-hidden />
          Productos que aún no tienes
        </h2>
        <p className="mb-3 text-sm text-gray-500">
          Para probar algo nuevo sin crearlo: escribe cuántas unidades trae el bulto, cuánto cuesta el bulto sin IVA y,
          si ya lo sabes, a cuánto venderías cada unidad.
        </p>
        <ol className="flex flex-col gap-3">
          {nuevos.map((n, j) => {
            const errores = mostrarErrores ? (nuevosValidados[j]?.errores ?? {}) : {};
            const k = lineas.length + j;
            const linea = datos?.lineas[k];
            const detalle = datos?.detalle[k];
            return (
              <li
                key={n.local}
                className={`rounded-lg border p-3 ${lineaConError === k ? 'border-red-400 bg-red-50' : 'border-gray-200'}`}
              >
                <div className="mb-2 flex items-end gap-2">
                  <div className="flex-1">
                    <Campo
                      etiqueta="Nombre"
                      placeholder="Ej.: Galletas de coco"
                      value={n.nombre}
                      onChange={(e) => cambiarNuevo(j, { nombre: e.target.value })}
                      error={errores.nombre}
                    />
                  </div>
                  <Boton
                    variante="secundario"
                    aria-label={`Quitar ${n.nombre || 'producto nuevo'}`}
                    onClick={() => setNuevos((ns) => ns.filter((_, i) => i !== j))}
                  >
                    ✕
                  </Boton>
                </div>
                <div className="grid grid-cols-2 gap-2 sm:grid-cols-5">
                  <Campo
                    etiqueta="Unidades por bulto"
                    inputMode="decimal"
                    value={n.factor}
                    onChange={(e) => cambiarNuevo(j, { factor: e.target.value })}
                    error={errores.factor}
                  />
                  <Campo
                    etiqueta="Bultos"
                    inputMode="decimal"
                    value={n.cantidad}
                    onChange={(e) => cambiarNuevo(j, { cantidad: e.target.value })}
                    error={errores.cantidad}
                  />
                  <Campo
                    etiqueta="Costo del bulto"
                    inputMode="decimal"
                    value={n.costo}
                    onChange={(e) => cambiarNuevo(j, { costo: e.target.value })}
                    error={errores.costo}
                  />
                  <Selector
                    etiqueta="IVA de la compra"
                    value={n.tarifa}
                    onChange={(e) => cambiarNuevo(j, { tarifa: e.target.value })}
                  >
                    {['0', '5', '15'].map((t) => (
                      <option key={t} value={t}>
                        {t} %
                      </option>
                    ))}
                  </Selector>
                  <Campo
                    etiqueta="Venderías c/u a"
                    inputMode="decimal"
                    placeholder="Opcional"
                    value={n.precio}
                    onChange={(e) => cambiarNuevo(j, { precio: e.target.value })}
                    error={errores.precio}
                  />
                </div>
                {linea && detalle && (
                  <div className="mt-2">
                    {linea.utilidad === null ? (
                      <p className="text-sm text-gray-600">Escribe a cuánto lo venderías para ver lo que ganas.</p>
                    ) : (
                      <LineaUtilidad linea={linea} />
                    )}
                    <Consejos detalle={detalle} margen={margen} nuevo />
                  </div>
                )}
              </li>
            );
          })}
        </ol>
        <div className="mt-3">
          <Boton
            variante="secundario"
            icono={PackagePlus}
            onClick={() =>
              setNuevos((ns) => [
                ...ns,
                { local: nuevaClave(), nombre: '', factor: '1', cantidad: '', costo: '', tarifa: '0', precio: '' },
              ])
            }
          >
            Agregar producto que aún no tengo
          </Boton>
        </div>
      </Tarjeta>

      {paraEnviar && <AvisoError error={simulacion.error} />}
      {datos && (
        <>
          <TotalCompra compra={datos.compra} />
          <ResumenUtilidad utilidad={datos} className="mb-4" />
        </>
      )}

      {hayAlgo && (
        <div className="flex flex-col gap-2">
          {nuevos.length > 0 && (
            <p className="text-sm text-gray-600">
              Para registrar la compra, los productos nuevos primero se crean en «Productos», o se sube la factura XML
              del proveedor, que los crea sola.
            </p>
          )}
          <div className="flex flex-wrap gap-2">
            {nuevos.length === 0 && (
              <Boton onClick={pasarACompra} icono={ShoppingBag}>
                Registrar esta compra
              </Boton>
            )}
            <Boton
              variante="secundario"
              onClick={() => {
                borrarLineas();
                borrarNuevos();
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
