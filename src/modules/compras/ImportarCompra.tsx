import { useMemo, useState, type ChangeEvent } from 'react';
import { Check, PackagePlus, PackageSearch, Upload } from 'lucide-react';
import { useProductos } from '@/modules/catalogo/api';
import { ElegirProducto } from '@/modules/catalogo/ElegirProducto';
import { leerDecimal } from '@/shared/decimal';
import { formatearCantidad, formatearDinero } from '@/shared/formato';
import { enlace, navegar } from '@/shared/ruta';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Casilla, Encabezado, Tarjeta } from '@/shared/ui';
import { useLeerFactura, useRegistrarCompraXml, type FacturaProveedor, type LineaFactura, type LineaRevisada } from './api';

interface Revision {
  modo: 'existente' | 'nuevo';
  productoId: string;
  productoNombre: string;
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

  const subir = async (evento: ChangeEvent<HTMLInputElement>) => {
    const archivo = evento.target.files?.[0];
    evento.target.value = '';
    if (!archivo) return;
    const texto = await archivo.text();
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
            <input type="file" accept=".xml,text/xml,application/xml" className="sr-only" onChange={subir} disabled={leer.isPending} />
          </label>
          <div className="mt-3">
            <AvisoError error={leer.error} />
          </div>
        </Tarjeta>
      )}
      {leer.data && <Revisar xml={xml} factura={leer.data} alCancelar={() => leer.reset()} />}
    </>
  );
}

function Revisar({ xml, factura, alCancelar }: { xml: string; factura: FacturaProveedor; alCancelar: () => void }) {
  const productos = useProductos();
  const registrar = useRegistrarCompraXml();
  const unaVez = useUnSoloEnvio();
  const [clave] = useState(nuevaClave);
  const [lineas, setLineas] = useState(() => factura.lineas.map(inicial));
  const [error, setError] = useState<string | null>(null);

  const opciones = useMemo(
    () =>
      (productos.data ?? [])
        .filter((p) => p.activo)
        .map((p) => ({ id: p.id, texto: p.nombre }))
        .sort((a, b) => a.texto.localeCompare(b.texto)),
    [productos.data],
  );

  const cambiar = (i: number, cambios: Partial<Revision>) =>
    setLineas((ls) => ls.map((l, j) => (j === i ? { ...l, ...cambios } : l)));

  const nuevos = lineas.filter((l) => l.modo === 'nuevo' && Number(l.recibida.replace(',', '.')) > 0).length;

  const guardar = () => {
    setError(null);
    const salida: LineaRevisada[] = [];
    for (const [i, l] of lineas.entries()) {
      const factura_l = factura.lineas[i];
      if (!factura_l) continue;
      const nombreLinea = factura_l.descripcion;
      const recibida = leerDecimal(l.recibida, { decimales: 3 });
      const unidades = leerDecimal(l.factor, { decimales: 3, permitirCero: false });
      if (!recibida.ok) return setError(`${nombreLinea}: ${recibida.mensaje}`);
      if (!unidades.ok) return setError(`${nombreLinea}: ${unidades.mensaje}`);
      if (Number(recibida.valor) === 0) {
        salida.push({ orden: factura_l.orden, cantidad_recibida: '0' });
        continue;
      }
      if (l.modo === 'existente') {
        if (!l.productoId) return setError(`${nombreLinea}: elige el producto`);
        salida.push({ orden: factura_l.orden, cantidad_recibida: recibida.valor, factor: unidades.valor, producto_id: l.productoId });
        continue;
      }
      if (l.nombre.trim() === '') return setError(`${nombreLinea}: escribe el nombre`);
      const precio = l.precio.trim() ? leerDecimal(l.precio, { decimales: 2 }) : null;
      if (precio && !precio.ok) return setError(`${nombreLinea}: ${precio.mensaje}`);
      salida.push({
        orden: factura_l.orden,
        cantidad_recibida: recibida.valor,
        factor: unidades.valor,
        nuevo: { nombre: l.nombre.trim(), precio_venta: precio?.ok ? precio.valor : '', controla_stock: l.controlaStock },
      });
    }
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
          const entran = recibida * factor;
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
                        cambiar(i, { productoId: id, productoNombre: opciones.find((o) => o.id === id)?.texto ?? '' })
                      }
                    />
                  </>
                ) : (
                  <div className="flex flex-col gap-3">
                    <div className="grid gap-3 sm:grid-cols-2">
                      <Campo etiqueta="Nombre del producto" value={l.nombre} onChange={(e) => cambiar(i, { nombre: e.target.value })} />
                      <Campo
                        etiqueta="Precio de venta por unidad"
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
                <Campo
                  etiqueta="Unidades por cada una"
                  ayuda="Caja de 12 = 12"
                  inputMode="decimal"
                  value={l.factor}
                  onChange={(e) => cambiar(i, { factor: e.target.value })}
                />
              </div>
              {recibida > 0 && factor > 0 && (
                <p className="mt-2 text-sm font-medium">Entran {formatearCantidad(String(entran))} unidades al stock</p>
              )}
              {recibida !== Number(x.cantidad) && (
                <p className="text-sm text-amber-800">No coincide con la factura ({formatearCantidad(x.cantidad)})</p>
              )}
            </li>
          );
        })}
      </ol>

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
