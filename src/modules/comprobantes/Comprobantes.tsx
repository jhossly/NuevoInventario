import { useMemo, useState, type ChangeEvent } from 'react';
import { FormProducto } from '@/modules/catalogo/FormProducto';
import { useProductos } from '@/modules/catalogo/api';
import { ElegirProducto } from '@/modules/catalogo/ElegirProducto';
import { useContexto } from '@/modules/sesion/sesion';
import { formatearMomento } from '@/modules/ventas/api';
import { formatearCantidad, formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { ErrorDeNegocio } from '@/shared/rpc';
import { FilePlus2, Layers, Link2, PackagePlus, Trash2, Upload } from 'lucide-react';
import { Aviso, AvisoError, Boton, Cargando, Casilla, Encabezado, Tarjeta } from '@/shared/ui';
import {
  presentacionBaseDe,
  useAsociarLinea,
  useCandidatos,
  useComprobantes,
  useCrearEnLote,
  useCrearVenta,
  useDescartar,
  useImportar,
  useVincular,
  type Comprobante,
  type LineaComprobante,
} from './api';

/**
 * Datos que trae una línea de la factura para el formulario de producto. El
 * precio del XML es sin IVA; si los precios de la bodega lo incluyen, se
 * sugiere con IVA (es solo una sugerencia que el Dueño revisa).
 */
function sugerencia(l: LineaComprobante, preciosIncluyenIva: boolean) {
  const tarifa = Number(l.tarifa_iva);
  const codigoIva = ({ 0: '0', 5: '5', 15: '4' } as Record<number, string>)[tarifa];
  const precio = Number(l.precio_unitario) * (preciosIncluyenIva ? 1 + tarifa / 100 : 1);
  return {
    nombre: l.descripcion,
    codigoIva,
    codigoPrincipal: l.codigo && l.codigo.length <= 25 ? l.codigo : undefined,
    precio: precio.toFixed(2).replace('.', ','),
  };
}

const lineasSinProducto = (n: number) => (n === 1 ? '1 línea sin producto' : `${n} líneas sin producto`);

interface Resultado {
  archivo: string;
  texto: string;
  ok: boolean;
}

/**
 * Facturas emitidas en el portal del SRI (D-012): subir los XML autorizados,
 * asociar sus líneas a productos y, por cada una, vincularla a la venta que ya
 * se registró a mano o crear la venta desde el XML.
 */
export function Comprobantes() {
  const comprobantes = useComprobantes();
  const importar = useImportar();
  const [resultados, setResultados] = useState<Resultado[]>([]);
  const [importando, setImportando] = useState(false);
  const [abierto, setAbierto] = useState<string | null>(null);
  const [mensajeLote, setMensajeLote] = useState<string | null>(null);

  const subir = async (evento: ChangeEvent<HTMLInputElement>) => {
    const archivos = Array.from(evento.target.files ?? []);
    evento.target.value = '';
    if (archivos.length === 0) return;
    setImportando(true);
    const salida: Resultado[] = [];
    // Uno por uno: cada archivo es su propia transacción y su propio resultado.
    for (const archivo of archivos) {
      try {
        const r = await importar.mutateAsync(await archivo.text());
        salida.push({
          archivo: archivo.name,
          ok: true,
          texto: r.repetido
            ? 'ya estaba importada'
            : `factura ${r.numero ?? ''} por ${formatearDinero(r.total ?? '0')}${
                r.sin_asociar ? ` · ${lineasSinProducto(r.sin_asociar)}` : ''
              }`,
        });
      } catch (e) {
        salida.push({ archivo: archivo.name, ok: false, texto: e instanceof ErrorDeNegocio ? e.message : 'no se pudo leer' });
      }
    }
    setResultados(salida);
    setImportando(false);
  };

  const pendientes = (comprobantes.data ?? []).filter((c) => !c.venta_id);
  const listos = (comprobantes.data ?? []).filter((c) => c.venta_id);
  const lineasFaltantes = pendientes.flatMap((c) => c.comprobante_lineas.filter((l) => !l.presentacion_id).map((l) => l.id));

  return (
    <>
      <Encabezado titulo="Facturas del SRI" volver={enlace({ nombre: 'ventas' })} />
      <Tarjeta className="mb-4">
        <p className="mb-3 text-sm text-gray-600">
          Descarga del portal del SRI los XML de las facturas que emitiste y súbelos aquí. Cada factura se une a la venta que
          ya registraste en «Vender» o, si no la registraste, crea la venta y descuenta el stock.
        </p>
        <label className="inline-flex min-h-11 cursor-pointer items-center rounded-lg bg-emerald-700 px-4 font-medium text-white hover:bg-emerald-800">
          <Upload className="mr-2 size-5" aria-hidden />
          {importando ? 'Importando…' : 'Subir archivos XML'}
          <input type="file" accept=".xml,text/xml,application/xml" multiple className="sr-only" onChange={subir} disabled={importando} />
        </label>
        {resultados.length > 0 && (
          <ul className="mt-3 text-sm">
            {resultados.map((r, i) => (
              <li key={i} className={r.ok ? 'text-green-800' : 'text-red-700'}>
                {r.ok ? '✓' : '✗'} {r.archivo}: {r.texto}
              </li>
            ))}
          </ul>
        )}
      </Tarjeta>

      {comprobantes.isPending && <Cargando />}
      <AvisoError error={comprobantes.error} />

      {mensajeLote && (
        <div className="mb-4">
          <Aviso tipo="exito">{mensajeLote}</Aviso>
        </div>
      )}
      {lineasFaltantes.length > 0 && <CrearTodos lineas={lineasFaltantes} alCrear={setMensajeLote} />}

      {pendientes.length > 0 && <h2 className="mb-2 font-semibold">Por resolver ({pendientes.length})</h2>}
      <ul className="mb-6 flex flex-col gap-2">
        {pendientes.map((c) => (
          <Fila
            key={c.id}
            comprobante={c}
            abierto={abierto === c.id}
            alAlternar={() => setAbierto(abierto === c.id ? null : c.id)}
            alCrear={setMensajeLote}
          />
        ))}
      </ul>

      {listos.length > 0 && <h2 className="mb-2 font-semibold">Con venta</h2>}
      <ul className="flex flex-col gap-2">
        {listos.map((c) => (
          <li key={c.id} className="flex items-center gap-3 rounded-xl border border-gray-200 bg-white p-3 text-sm">
            <span className="flex-1">
              {c.fecha_emision} · {c.numero} · {c.razon_social_comprador ?? 'Consumidor final'}
            </span>
            <span className="tabular-nums">{formatearDinero(c.total)}</span>
            <a href={enlace({ nombre: 'venta', id: c.venta_id ?? '' })} className="underline">
              {c.vinculo === 'CREADA' ? 'venta creada' : 'vinculada'}
            </a>
          </li>
        ))}
      </ul>
      {comprobantes.isSuccess && comprobantes.data.length === 0 && <Tarjeta>Todavía no has subido facturas.</Tarjeta>}
    </>
  );
}

const productosEnTexto = (n: number) => (n === 1 ? '1 producto' : `${n} productos`);

/** Crea los productos de todas las líneas que faltan, en una sola operación. */
function BotonLote({ lineas, texto, alCrear }: { lineas: string[]; texto: string; alCrear: (mensaje: string) => void }) {
  const crear = useCrearEnLote();
  const [sinStock, setSinStock] = useState(false);
  return (
    <div className="flex flex-col gap-2">
      <Casilla
        etiqueta="Son servicios o recargas: no controlar stock"
        checked={sinStock}
        onChange={(e) => setSinStock(e.target.checked)}
      />
      <Boton
        icono={Layers}
        disabled={crear.isPending || lineas.length === 0}
        onClick={() => {
          // Con mutateAsync: al no quedar líneas este botón se desmonta y el
          // onSuccess de mutate ya no se llamaría. El error lo muestra crear.error.
          crear.mutateAsync({ lineas, controlaStock: !sinStock }).then(
            (r) => alCrear(`${productosEnTexto(r.creados)} nuevos${r.existentes > 0 ? `, ${r.existentes} ya existían` : ''}.`),
            () => undefined,
          );
        }}
      >
        {crear.isPending ? 'Creando…' : texto}
      </Boton>
      <AvisoError error={crear.error} />
    </div>
  );
}

function CrearTodos({ lineas, alCrear }: { lineas: string[]; alCrear: (mensaje: string) => void }) {
  return (
    <Tarjeta className="mb-4">
      <h2 className="mb-1 font-semibold">Faltan productos</h2>
      <p className="mb-3 text-sm text-gray-600">
        {lineasSinProducto(lineas.length)}. Se crean con el nombre, código, precio y tarifa de la factura; las líneas con el
        mismo código o nombre de un producto que ya existe se unen a ese producto.
      </p>
      <BotonLote lineas={lineas} texto={`Crear todos (${lineas.length})`} alCrear={alCrear} />
    </Tarjeta>
  );
}

function Fila({
  comprobante: c,
  abierto,
  alAlternar,
  alCrear,
}: {
  comprobante: Comprobante;
  abierto: boolean;
  alAlternar: () => void;
  alCrear: (mensaje: string) => void;
}) {
  const sinProducto = c.comprobante_lineas.filter((l) => !l.presentacion_id).length;
  return (
    <li className="rounded-xl border border-gray-200 bg-white">
      <button type="button" onClick={alAlternar} aria-expanded={abierto} className="flex w-full items-center gap-3 p-3 text-left">
        <div className="min-w-0 flex-1">
          <p className="truncate font-medium">
            {c.numero} · {c.razon_social_comprador ?? 'Consumidor final'}
          </p>
          <p className="text-sm text-gray-500">
            {c.fecha_emision} · {sinProducto > 0 ? lineasSinProducto(sinProducto) : 'lista para resolver'}
          </p>
        </div>
        <span className="font-semibold tabular-nums">{formatearDinero(c.total)}</span>
      </button>
      {abierto && <Detalle comprobante={c} sinProducto={sinProducto} alCrear={alCrear} />}
    </li>
  );
}

function Detalle({
  comprobante: c,
  sinProducto,
  alCrear,
}: {
  comprobante: Comprobante;
  sinProducto: number;
  alCrear: (mensaje: string) => void;
}) {
  const productos = useProductos();
  const asociar = useAsociarLinea();
  const candidatos = useCandidatos(c.id, true);
  const vincular = useVincular();
  const crear = useCrearVenta();
  const descartar = useDescartar();
  const contexto = useContexto();
  // Línea cuyo formulario de producto nuevo está abierto.
  const [creando, setCreando] = useState<string | null>(null);
  const [errorNuevo, setErrorNuevo] = useState(false);

  const asociarNuevo = async (lineaId: string, productoId: string) => {
    setErrorNuevo(false);
    try {
      const presentacionId = await presentacionBaseDe(productoId);
      await asociar.mutateAsync({ lineaId, presentacionId });
      setCreando(null);
    } catch {
      setErrorNuevo(true);
    }
  };

  const opciones = useMemo(
    () =>
      (productos.data ?? [])
        .filter((p) => p.activo)
        .flatMap((p) =>
          p.presentaciones
            .filter((r) => r.activo)
            .map((r) => ({ id: r.id, texto: Number(r.factor) === 1 ? p.nombre : `${p.nombre} — ${r.nombre}` })),
        )
        .sort((a, b) => a.texto.localeCompare(b.texto)),
    [productos.data],
  );

  const error = asociar.error ?? vincular.error ?? crear.error ?? descartar.error;

  return (
    <div className="border-t border-gray-100 p-3">
      <ol className="mb-3 flex flex-col gap-2 text-sm">
        {c.comprobante_lineas.map((l) => (
          <li key={l.id} className="flex flex-wrap items-end gap-2">
            <p className="min-w-0 flex-1">
              {formatearCantidad(l.cantidad)} × {l.descripcion}
              <span className="block text-gray-500">
                código {l.codigo ?? '—'} · {formatearDinero(l.base)} + IVA {formatearDinero(l.iva)}
              </span>
            </p>
            {l.presentacion_id ? (
              <span className="text-green-800">
                → {l.presentaciones?.productos.nombre}
                {l.presentaciones && l.presentaciones.nombre !== 'Unidad' && l.presentaciones.nombre !== 'Kilo'
                  ? ` — ${l.presentaciones.nombre}`
                  : ''}
              </span>
            ) : (
              <div className="flex items-end gap-2">
                <div className="w-64">
                  <ElegirProducto
                    opciones={opciones}
                    disabled={asociar.isPending}
                    alElegir={(id) => asociar.mutate({ lineaId: l.id, presentacionId: id })}
                  />
                </div>
                <Boton variante="secundario" icono={PackagePlus} onClick={() => setCreando(creando === l.id ? null : l.id)}>
                  {creando === l.id ? 'Cancelar' : 'Crear producto'}
                </Boton>
              </div>
            )}
            {creando === l.id && !l.presentacion_id && (
              <div className="w-full rounded-xl border border-gray-200 bg-gray-50 p-3">
                <h4 className="mb-2 font-semibold">Nuevo producto desde la factura</h4>
                <p className="mb-3 text-gray-600">
                  Revisa los datos que trae la factura. Al crearlo, esta línea y las próximas con el código{' '}
                  {l.codigo ?? '—'} quedan asociadas.
                </p>
                <FormProducto
                  inicial={sugerencia(l, contexto.precios_incluyen_iva)}
                  alCrear={(productoId) => asociarNuevo(l.id, productoId)}
                />
                {errorNuevo && (
                  <p className="mt-2 text-red-700">
                    El producto se creó, pero no se pudo asociar: elígelo en «¿Qué producto es?».
                  </p>
                )}
              </div>
            )}
          </li>
        ))}
      </ol>

      {sinProducto > 1 && (
        <div className="mb-4 rounded-lg bg-gray-50 p-3">
          <BotonLote
            lineas={c.comprobante_lineas.filter((l) => !l.presentacion_id).map((l) => l.id)}
            texto={`Crear los ${sinProducto} productos de esta factura`}
            alCrear={alCrear}
          />
        </div>
      )}

      <h3 className="mb-1 text-sm font-semibold">¿Ya registraste esta venta en «Vender»?</h3>
      {candidatos.isPending && <Cargando />}
      {candidatos.data?.length === 0 && (
        <p className="mb-3 text-sm text-gray-600">No hay ventas de ese día por {formatearDinero(c.total)} sin factura.</p>
      )}
      <ul className="mb-3 flex flex-col gap-1 text-sm">
        {candidatos.data?.map((v) => (
          <li key={v.venta_id} className="flex items-center gap-2">
            <span className="flex-1">
              {formatearMomento(v.creado_en)} · {v.cliente} · {formatearDinero(v.total)}
              {v.tipo_comprobante !== 'FACTURA' && <span className="text-amber-700"> (registrada como nota de venta)</span>}
            </span>
            <Boton
              variante="secundario"
              icono={Link2}
              disabled={vincular.isPending}
              onClick={() => vincular.mutate({ comprobanteId: c.id, ventaId: v.venta_id })}
            >
              Es esta venta
            </Boton>
          </li>
        ))}
      </ul>

      <div className="flex flex-wrap gap-2">
        <Boton icono={FilePlus2} disabled={sinProducto > 0 || crear.isPending} onClick={() => crear.mutate(c.id)}>
          {crear.isPending ? 'Creando…' : 'No la registré: crear la venta'}
        </Boton>
        <Boton
          variante="secundario"
          icono={Trash2}
          disabled={descartar.isPending}
          onClick={() => window.confirm(`¿Descartar la factura ${c.numero}? Se puede volver a subir.`) && descartar.mutate(c.id)}
        >
          Descartar
        </Boton>
      </div>
      {sinProducto > 0 && <p className="mt-2 text-sm text-gray-600">Para crear la venta, primero elige el producto de cada línea.</p>}
      <div className="mt-2">{error ? <AvisoError error={error} /> : null}</div>
      {candidatos.data && candidatos.data.length > 0 && (
        <div className="mt-2">
          <Aviso tipo="info">Si la venta ya está registrada, vincúlala: crearla otra vez descontaría el stock dos veces.</Aviso>
        </div>
      )}
    </div>
  );
}
