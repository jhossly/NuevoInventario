import { useState } from 'react';
import { useContexto } from '@/modules/sesion/sesion';
import { useValorizado } from '@/modules/inventario/api';
import { formatearCantidad, formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { AvisoError, Boton, Cargando, EnlaceBoton, Encabezado, Tarjeta } from '@/shared/ui';
import { FormPresentacion } from './FormPresentacion';
import { FormProducto } from './FormProducto';
import { UNIDADES, bajoStock, textoIva, presentacionesOrdenadas, stockDe, useProducto, type Producto } from './api';

export function FichaProducto({ id }: { id: string }) {
  const producto = useProducto(id);

  if (producto.isPending) return <Cargando />;
  if (producto.error) return <AvisoError error={producto.error} />;
  if (!producto.data) {
    return (
      <>
        <Encabezado titulo="Producto" volver={enlace({ nombre: 'productos' })} />
        <Tarjeta>El producto no existe o no es de tu empresa.</Tarjeta>
      </>
    );
  }
  // key: al cambiar de producto se reinician los formularios.
  return <Ficha key={producto.data.id} producto={producto.data} />;
}

function Ficha({ producto }: { producto: Producto }) {
  const contexto = useContexto();
  const esDueno = contexto.rol === 'DUENO';
  const valorizado = useValorizado(contexto.ve_costos);
  const costo = valorizado.data?.productos.find((p) => p.producto_id === producto.id);
  const unidad = UNIDADES[producto.unidad_base];

  return (
    <>
      <Encabezado titulo={producto.nombre} volver={enlace({ nombre: 'productos' })} />

      {!producto.controla_stock ? (
        <Tarjeta className="mb-4">
          <p className="font-medium">No controla stock</p>
          <p className="text-sm text-gray-600">Se vende sin existencias, como una recarga o un servicio.</p>
          {costo && (
            <p className="mt-2 text-sm">
              Costo por unidad:{' '}
              <span className="tabular-nums">{costo.ultimo_costo ? formatearCosto(costo.ultimo_costo) : 'sin costo ($0)'}</span>
            </p>
          )}
        </Tarjeta>
      ) : (
        <Tarjeta className="mb-4">
          <div className="flex flex-wrap items-end justify-between gap-4">
            <div>
              <p className="text-sm text-gray-500">Stock</p>
              <p className={`text-3xl font-semibold tabular-nums ${bajoStock(producto) ? 'text-red-700' : ''}`}>
                {formatearCantidad(stockDe(producto))} <span className="text-base font-normal text-gray-500">{unidad}</span>
              </p>
              {bajoStock(producto) && (
                <p className="text-sm text-red-700">
                  Bajo stock (mínimo {formatearCantidad(producto.stock_minimo)})
                </p>
              )}
            </div>
            {costo && (
              <dl className="grid grid-cols-2 gap-x-4 text-sm">
                <dt className="text-gray-500">Costo promedio</dt>
                <dd className="text-right tabular-nums">{costo.costo_promedio ? formatearCosto(costo.costo_promedio) : '—'}</dd>
                <dt className="text-gray-500">Valor</dt>
                <dd className="text-right tabular-nums">{formatearCosto(costo.valor_total)}</dd>
              </dl>
            )}
          </div>
          {esDueno && (
            <div className="mt-4 flex flex-wrap gap-2">
              <EnlaceBoton href={enlace({ nombre: 'ajuste', id: producto.id })} variante="primario">
                Ajustar stock
              </EnlaceBoton>
              {contexto.ve_costos && <EnlaceBoton href={enlace({ nombre: 'kardex', id: producto.id })}>Kardex</EnlaceBoton>}
            </div>
          )}
          {!esDueno && contexto.ve_costos && (
            <div className="mt-4">
              <EnlaceBoton href={enlace({ nombre: 'kardex', id: producto.id })}>Kardex</EnlaceBoton>
            </div>
          )}
        </Tarjeta>
      )}

      <Presentaciones producto={producto} editable={esDueno} />

      {esDueno ? (
        <Tarjeta className="mt-4">
          <h2 className="mb-3 font-semibold">Datos del producto</h2>
          <FormProducto
            // Se vuelve a montar cuando llega el costo (solo quien ve costos).
            key={costo ? 'con-costo' : 'sin-costo'}
            producto={producto}
            costoServicio={costo ? costo.ultimo_costo : undefined}
          />
        </Tarjeta>
      ) : (
        <Tarjeta className="mt-4">
          <dl className="grid grid-cols-2 gap-y-1 text-sm">
            <dt className="text-gray-500">Categoría</dt>
            <dd>{producto.categorias?.nombre ?? 'Sin categoría'}</dd>
            <dt className="text-gray-500">IVA</dt>
            <dd>{textoIva(producto.codigo_iva)}</dd>
            {producto.codigo_principal && (
              <>
                <dt className="text-gray-500">Código principal</dt>
                <dd>{producto.codigo_principal}</dd>
              </>
            )}
            {producto.codigo_auxiliar && (
              <>
                <dt className="text-gray-500">Código auxiliar</dt>
                <dd>{producto.codigo_auxiliar}</dd>
              </>
            )}
            {producto.informacion_adicional && (
              <>
                <dt className="text-gray-500">Información adicional</dt>
                <dd>{producto.informacion_adicional}</dd>
              </>
            )}
          </dl>
        </Tarjeta>
      )}
    </>
  );
}

function Presentaciones({ producto, editable }: { producto: Producto; editable: boolean }) {
  // null: ningún formulario abierto; 'nueva' o el id de la que se edita.
  const [abierta, setAbierta] = useState<string | null>(null);
  const unidad = producto.unidad_base === 'KG' ? 'kg' : 'u';

  return (
    <Tarjeta>
      <div className="mb-2 flex items-center justify-between">
        <h2 className="font-semibold">Presentaciones</h2>
        {editable && abierta === null && (
          <Boton variante="secundario" onClick={() => setAbierta('nueva')}>
            Agregar
          </Boton>
        )}
      </div>

      {abierta === 'nueva' && <FormPresentacion producto={producto} alTerminar={() => setAbierta(null)} />}

      <ul className="divide-y divide-gray-100">
        {presentacionesOrdenadas(producto).map((p) =>
          abierta === p.id ? (
            <li key={p.id} className="py-2">
              <FormPresentacion producto={producto} presentacion={p} alTerminar={() => setAbierta(null)} />
            </li>
          ) : (
            <li key={p.id} className={`flex items-center gap-3 py-2 ${p.activo ? '' : 'opacity-50'}`}>
              <div className="min-w-0 flex-1">
                <p className="font-medium">
                  {p.nombre}
                  {!p.activo && ' (inactiva)'}
                </p>
                <p className="text-sm text-gray-500">
                  {formatearCantidad(p.factor)} {unidad}
                  {!p.se_vende && ' · no se vende'}
                  {!p.se_compra && ' · no se compra'}
                  {p.codigo_barras && ` · ${p.codigo_barras}`}
                </p>
              </div>
              <p className="tabular-nums">{p.precio_venta ? formatearDinero(p.precio_venta) : '—'}</p>
              {editable && abierta === null && (
                <Boton variante="secundario" onClick={() => setAbierta(p.id)} aria-label={`Editar ${p.nombre}`}>
                  Editar
                </Boton>
              )}
            </li>
          ),
        )}
      </ul>
    </Tarjeta>
  );
}
