import { useState } from 'react';
import { Calculator, PackagePlus, ShoppingBag } from 'lucide-react';
import { useProductos } from '@/modules/catalogo/api';
import { useBorrador, useBorradorAjeno } from '@/shared/borrador';
import { leerDecimal } from '@/shared/decimal';
import { formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace, navegar } from '@/shared/ruta';
import { ErrorDeNegocio } from '@/shared/rpc';
import { Aviso, AvisoError, Boton, Campo, Cargando, Encabezado, Tarjeta } from '@/shared/ui';
import { formatearFecha, useSimularCompra, type Simulacion } from './api';
import {
  aLineaExistente,
  EditorLineas,
  EditorNuevos,
  lineasParaEnviar,
  validarNuevo,
  type LineaEnPantalla,
  type NuevoEnPantalla,
} from './LineasCompra';
import { BORRADOR_LINEAS_COMPRA, BORRADOR_NUEVOS_COMPRA } from './NuevaCompra';
import { LineaUtilidad, ResumenUtilidad, TotalCompra } from './UtilidadCompra';

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
 * antes de decidir. No registra nada; si conviene, pasa a «Nueva compra», con
 * los productos que aún no existen, que se crean al registrarla (D-066, D-067).
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

  const pasarACompra = () => {
    setMostrarErrores(true);
    if (!paraEnviar) return;
    const pendientes =
      (ajeno.leer<LineaEnPantalla[]>(BORRADOR_LINEAS_COMPRA) ?? []).length +
      (ajeno.leer<NuevoEnPantalla[]>(BORRADOR_NUEVOS_COMPRA) ?? []).length;
    if (
      pendientes > 0 &&
      !window.confirm('Ya tienes una compra a medio escribir en «Nueva compra». ¿Reemplazar sus productos por estos?')
    ) {
      return;
    }
    ajeno.escribir(BORRADOR_LINEAS_COMPRA, lineas);
    ajeno.escribir(BORRADOR_NUEVOS_COMPRA, nuevos);
    borrarLineas();
    borrarNuevos();
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
          Escribe el nombre: si ya lo tienes aparece para elegirlo; si no, queda como nuevo y se crea cuando registres
          la compra. Pon cuántas unidades trae el bulto, cuánto cuesta el bulto sin IVA y, si ya lo sabes, a cuánto
          venderías cada unidad.
        </p>
        <EditorNuevos
          productos={productos.data ?? []}
          nuevos={nuevos}
          setNuevos={setNuevos}
          alElegirExistente={(j, producto, presentacion) => {
            const n = nuevos[j];
            if (!n) return;
            setNuevos((ns) => ns.filter((_, i) => i !== j));
            setLineas((ls) => [...ls, aLineaExistente(n, producto, presentacion)]);
          }}
          validados={nuevosValidados}
          mostrarErrores={mostrarErrores}
          lineaConError={lineaConError}
          desfase={lineas.length}
          etiquetaPrecio="Venderías c/u a"
          debajo={(_, j) => {
            const linea = datos?.lineas[lineas.length + j];
            const detalle = datos?.detalle[lineas.length + j];
            if (!linea || !detalle) return null;
            return (
              <div className="mt-2">
                {linea.utilidad === null ? (
                  <p className="text-sm text-gray-600">Escribe a cuánto lo venderías para ver lo que ganas.</p>
                ) : (
                  <LineaUtilidad linea={linea} />
                )}
                <Consejos detalle={detalle} margen={margen} nuevo />
              </div>
            );
          }}
        />
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
