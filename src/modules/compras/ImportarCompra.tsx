import { useEffect, useMemo, useState, type ChangeEvent } from 'react';
import { Check, PackagePlus, PackageSearch, Upload } from 'lucide-react';
import { unidadCorta, useMedidas, useProductos } from '@/modules/catalogo/api';
import { ElegirProducto } from '@/modules/catalogo/ElegirProducto';
import { leerDecimal } from '@/shared/decimal';
import { formatearCantidad, formatearDinero } from '@/shared/formato';
import { enlace, navegar } from '@/shared/ruta';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Casilla, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import { leerXml } from '@/shared/xml';
import { LineaUtilidad, ResumenUtilidad, TotalCompra } from './UtilidadCompra';
import {
  useEstimarUtilidad,
  useLeerFactura,
  useRegistrarCompraXml,
  type FacturaProveedor,
  type LineaFactura,
  type LineaRevisada,
} from './api';

/** Espera a que se deje de escribir para no consultar en cada tecla. */
function useDemorado<T>(valor: T): T {
  const clave = JSON.stringify(valor);
  const [demorado, setDemorado] = useState(valor);
  useEffect(() => {
    const espera = setTimeout(() => setDemorado(JSON.parse(clave) as T), 500);
    return () => clearTimeout(espera);
  }, [clave]);
  return demorado;
}

// Kilos por cada medida de peso. Con otras medidas, «Cada una trae» va en esa medida.
const KILOS: Record<string, number> = { KG: 1, LB: 0.453592 };
const TEXTO_PESO: Record<string, string> = { KG: 'kg', LB: 'lb' };

/** Unidades base que trae cada bulto: 5 lb en un producto por kilo = 2,26796. */
function convertir(trae: number, medidaTrae: string, base: string): number {
  const de = KILOS[medidaTrae];
  const a = KILOS[base];
  return de && a ? trae * (de / a) : trae;
}

interface Revision {
  modo: 'existente' | 'nuevo';
  productoId: string;
  productoNombre: string;
  unidadBase: string;
  medidaTrae: string;
  nombre: string;
  precio: string;
  controlaStock: boolean;
  recibida: string;
  factor: string;
}

const inicial = (l: LineaFactura): Revision => ({
  modo: l.producto_id ? 'existente' : 'nuevo',
  productoId: l.producto_id ?? '',
  productoNombre: l.producto ?? '',
  unidadBase: l.unidad_base ?? 'UND',
  medidaTrae: l.unidad_base ?? 'UND',
  nombre: l.descripcion,
  precio: '',
  controlaStock: true,
  recibida: String(Number(l.cantidad)),
  factor: l.factor ? String(Number(l.factor)) : '1',
});

/** Registrar una compra desde el XML de la factura del proveedor (D-054). */
export function ImportarCompra() {
  const leer = useLeerFactura();
  const [xml, setXml] = useState('');
  const [nombre, setNombre] = useState('');
  const [errorArchivo, setErrorArchivo] = useState<string | null>(null);

  const subir = async (evento: ChangeEvent<HTMLInputElement>) => {
    const archivo = evento.target.files?.[0];
    if (!archivo) return;
    setNombre(archivo.name);
    setErrorArchivo(null);
    let texto: string;
    try {
      texto = await leerXml(archivo);
    } catch (e) {
      setErrorArchivo(e instanceof Error ? e.message : 'No se pudo leer el archivo');
      return;
    } finally {
      evento.target.value = '';
    }
    setXml(texto);
    leer.mutate(texto);
  };

  return (
    <>
      <Encabezado titulo="Compra desde factura" volver={enlace({ nombre: 'compras' })} />
      {!leer.data && (
        <Tarjeta className="mb-4">
          <p className="mb-3 text-sm text-gray-600">
            Sube el XML de la factura de tu proveedor. Antes de guardar podrás revisar cada producto y corregir lo que de
            verdad llegó.
          </p>
          <label className="inline-flex min-h-11 cursor-pointer items-center gap-2 rounded-lg bg-emerald-700 px-4 font-medium text-white hover:bg-emerald-800">
            <Upload className="size-5" aria-hidden />
            {leer.isPending ? 'Leyendo…' : 'Subir XML'}
            <input type="file" accept=".xml,text/xml,application/xml,application/octet-stream,*/*" className="sr-only" onChange={subir} disabled={leer.isPending} />
          </label>
          {nombre && <p className="mt-2 text-sm text-gray-600">Archivo: {nombre}</p>}
          <div className="mt-3">
            {errorArchivo && <Aviso>{errorArchivo}</Aviso>}
            <AvisoError error={leer.error} />
          </div>
        </Tarjeta>
      )}
      {leer.data && <Revisar xml={xml} factura={leer.data} alCancelar={() => leer.reset()} />}
    </>
  );
}

/** «Saco 10 kg» o «Caja 12»; sin nombre si es la presentación base. */
function nombreBulto(l: Revision, trae: string): string | undefined {
  const texto = TEXTO_PESO[l.medidaTrae];
  if (Number(trae) === 1 && l.medidaTrae === l.unidadBase) return undefined;
  const cantidad = trae.replace('.', ',');
  return texto ? `Saco ${cantidad} ${texto}` : `Caja ${cantidad}`;
}

function Revisar({ xml, factura, alCancelar }: { xml: string; factura: FacturaProveedor; alCancelar: () => void }) {
  const productos = useProductos();
  const medidas = useMedidas();
  const registrar = useRegistrarCompraXml();
  const unaVez = useUnSoloEnvio();
  const [clave] = useState(nuevaClave);
  const [lineas, setLineas] = useState(() => factura.lineas.map(inicial));
  const [error, setError] = useState<string | null>(null);

  const opciones = useMemo(
    () =>
      (productos.data ?? [])
        .filter((p) => p.activo)
        .map((p) => ({ id: p.id, texto: p.nombre, unidad: p.unidad_base }))
        .sort((a, b) => a.texto.localeCompare(b.texto)),
    [productos.data],
  );

  const cambiar = (i: number, cambios: Partial<Revision>) =>
    setLineas((ls) => ls.map((l, j) => (j === i ? { ...l, ...cambios } : l)));

  const nuevos = lineas.filter((l) => l.modo === 'nuevo' && Number(l.recibida.replace(',', '.')) > 0).length;

  // Lo revisado, listo para la base; o el motivo por el que aún no lo está.
  const armar = (): { salida: LineaRevisada[] } | { error: string } => {
    const salida: LineaRevisada[] = [];
    for (const [i, l] of lineas.entries()) {
      const factura_l = factura.lineas[i];
      if (!factura_l) continue;
      const nombreLinea = factura_l.descripcion;
      const recibida = leerDecimal(l.recibida, { decimales: 3 });
      const unidades = leerDecimal(l.factor, { decimales: 3, permitirCero: false });
      if (!recibida.ok) return { error: `${nombreLinea}: ${recibida.mensaje}` };
      if (!unidades.ok) return { error: `${nombreLinea}: ${unidades.mensaje}` };
      if (Number(recibida.valor) === 0) {
        salida.push({ orden: factura_l.orden, cantidad_recibida: '0' });
        continue;
      }
      // 6 decimales: es lo que guarda el factor de una presentación.
      const factor = convertir(Number(unidades.valor), l.medidaTrae, l.unidadBase).toFixed(6);
      if (Number(factor) <= 0) return { error: `${nombreLinea}: revisa cuánto trae cada una` };
      const presentacion = nombreBulto(l, unidades.valor);
      if (l.modo === 'existente') {
        if (!l.productoId) return { error: `${nombreLinea}: elige el producto` };
        salida.push({ orden: factura_l.orden, cantidad_recibida: recibida.valor, factor, presentacion, producto_id: l.productoId });
        continue;
      }
      if (l.nombre.trim() === '') return { error: `${nombreLinea}: escribe el nombre` };
      const precio = l.precio.trim() ? leerDecimal(l.precio, { decimales: 2 }) : null;
      if (precio && !precio.ok) return { error: `${nombreLinea}: ${precio.mensaje}` };
      salida.push({
        orden: factura_l.orden,
        cantidad_recibida: recibida.valor,
        factor,
        presentacion,
        nuevo: {
          nombre: l.nombre.trim(),
          unidad_base: l.unidadBase,
          precio_venta: precio?.ok ? precio.valor : '',
          controla_stock: l.controlaStock,
        },
      });
    }
    return { salida };
  };

  const armadas = armar();
  const paraEstimar = useDemorado('salida' in armadas ? armadas.salida : null);
  const estimacion = useEstimarUtilidad(xml, paraEstimar);

  const guardar = () => {
    setError(null);
    if ('error' in armadas) return setError(armadas.error);
    const salida = armadas.salida;
    unaVez((terminar) =>
      registrar.mutate(
        { xml, lineas: salida, clave },
        { onSuccess: (r) => navegar({ nombre: 'compra', id: r.compra_id }), onSettled: terminar },
      ),
    );
  };

  return (
    <>
      <Tarjeta className="mb-4">
        <p className="font-semibold">{factura.razon_social}</p>
        <p className="text-sm text-gray-600">
          Factura {factura.numero} · {factura.fecha} · {factura.lineas.length} líneas
        </p>
        <p className="mt-1 text-xl font-bold tabular-nums">{formatearDinero(factura.total)}</p>
        {!factura.proveedor_id && <p className="text-sm text-emerald-800">Proveedor nuevo: se guardará con esta compra.</p>}
      </Tarjeta>

      <ol className="mb-4 flex flex-col gap-3">
        {lineas.map((l, i) => {
          const x = factura.lineas[i];
          if (!x) return null;
          const recibida = Number(l.recibida.replace(',', '.'));
          const factor = Number(l.factor.replace(',', '.'));
          const entran = recibida * convertir(factor, l.medidaTrae, l.unidadBase);
          const esPeso = Boolean(KILOS[l.unidadBase]);
          const lineaUtilidad = estimacion.data?.lineas.find((u) => u.orden === x.orden);
          return (
            <li key={x.orden} className="rounded-xl border border-gray-200 bg-white p-3">
              <p className="font-medium">{x.descripcion}</p>
              <p className="text-sm text-gray-600">
                Facturado: {formatearCantidad(x.cantidad)} × {formatearDinero(x.precio_unitario)} · IVA{' '}
                {formatearDinero(x.iva)}
                {Number(x.otros_impuestos) > 0 && ` · otros impuestos ${formatearDinero(x.otros_impuestos)}`}
              </p>
              {Number(x.base) === 0 && <p className="text-sm font-medium text-amber-800">Bonificación: entra a costo $0</p>}

              <div className="mt-2 flex flex-wrap gap-2" role="radiogroup" aria-label="Producto">
                <Boton
                  variante={l.modo === 'existente' ? 'primario' : 'secundario'}
                  icono={PackageSearch}
                  onClick={() => cambiar(i, { modo: 'existente' })}
                >
                  Ya existe
                </Boton>
                <Boton
                  variante={l.modo === 'nuevo' ? 'primario' : 'secundario'}
                  icono={PackagePlus}
                  onClick={() => cambiar(i, { modo: 'nuevo' })}
                >
                  Es nuevo
                </Boton>
              </div>

              <div className="mt-3">
                {l.modo === 'existente' ? (
                  <>
                    {l.productoNombre && <p className="mb-2 flex items-center gap-1 text-green-800"><Check className="size-4" aria-hidden />{l.productoNombre}</p>}
                    <ElegirProducto
                      opciones={opciones}
                      alElegir={(id) =>
                        {
                          const elegido = opciones.find((o) => o.id === id);
                          cambiar(i, {
                            productoId: id,
                            productoNombre: elegido?.texto ?? '',
                            unidadBase: elegido?.unidad ?? 'UND',
                            medidaTrae: elegido?.unidad ?? 'UND',
                          });
                        }
                      }
                    />
                  </>
                ) : (
                  <div className="flex flex-col gap-3">
                    <div className="grid gap-3 sm:grid-cols-2">
                      <Campo etiqueta="Nombre del producto" value={l.nombre} onChange={(e) => cambiar(i, { nombre: e.target.value })} />
                      <Selector
                        etiqueta="Se cuenta en"
                        value={l.unidadBase}
                        onChange={(e) => cambiar(i, { unidadBase: e.target.value, medidaTrae: e.target.value })}
                      >
                        {medidas.data?.map((m) => (
                          <option key={m.codigo} value={m.codigo}>
                            {m.nombre}
                          </option>
                        ))}
                      </Selector>
                      <Campo
                        etiqueta={`Precio de venta por ${medidas.data?.find((m) => m.codigo === l.unidadBase)?.nombre.toLowerCase() ?? 'unidad'}`}
                        ayuda="Puedes ponerlo después"
                        inputMode="decimal"
                        value={l.precio}
                        onChange={(e) => cambiar(i, { precio: e.target.value })}
                      />
                    </div>
                    <Casilla
                      etiqueta="Controla stock"
                      checked={l.controlaStock}
                      onChange={(e) => cambiar(i, { controlaStock: e.target.checked })}
                    />
                  </div>
                )}
              </div>

              <div className="mt-3 grid grid-cols-2 gap-3">
                <Campo
                  etiqueta="Cantidad que llegó"
                  ayuda="0 si no llegó"
                  inputMode="decimal"
                  value={l.recibida}
                  onChange={(e) => cambiar(i, { recibida: e.target.value })}
                />
                <div className="flex items-end gap-2">
                  <div className="min-w-0 flex-1">
                    <Campo
                      etiqueta="Cada una trae"
                      ayuda={esPeso ? 'Saco de 10 kg = 10' : 'Caja de 12 = 12'}
                      inputMode="decimal"
                      value={l.factor}
                      onChange={(e) => cambiar(i, { factor: e.target.value })}
                    />
                  </div>
                  {esPeso && (
                    <div className="w-20 pb-6">
                      <Selector
                        etiqueta="En"
                        value={l.medidaTrae}
                        onChange={(e) => cambiar(i, { medidaTrae: e.target.value })}
                      >
                        <option value="KG">kg</option>
                        <option value="LB">lb</option>
                      </Selector>
                    </div>
                  )}
                </div>
              </div>
              {recibida > 0 && factor > 0 && (
                <p className="mt-2 text-sm font-medium">
                  Entran {formatearCantidad(entran.toFixed(3))} {unidadCorta(l.unidadBase)} al stock
                </p>
              )}
              {lineaUtilidad && <LineaUtilidad linea={lineaUtilidad} />}
              {recibida !== Number(x.cantidad) && (
                <p className="text-sm text-amber-800">No coincide con la factura ({formatearCantidad(x.cantidad)})</p>
              )}
            </li>
          );
        })}
      </ol>

      {estimacion.data?.compra && <TotalCompra compra={estimacion.data.compra} />}
      {estimacion.data && <ResumenUtilidad utilidad={estimacion.data} className="mb-4" />}

      {error && (
        <div className="mb-3">
          <Aviso>{error}</Aviso>
        </div>
      )}
      <div className="mb-3">
        <AvisoError error={registrar.error} />
      </div>
      <div className="flex flex-wrap gap-2">
        <Boton icono={Check} disabled={registrar.isPending} onClick={guardar}>
          {registrar.isPending ? 'Guardando…' : nuevos > 0 ? `Guardar compra y ${nuevos} producto${nuevos === 1 ? '' : 's'}` : 'Guardar compra'}
        </Boton>
        <Boton variante="secundario" onClick={alCancelar}>
          Cancelar
        </Boton>
      </div>
    </>
  );
}
