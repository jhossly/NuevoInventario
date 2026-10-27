import { useMemo, useState } from 'react';
import { useContexto } from '@/modules/sesion/sesion';
import { useValorizado } from '@/modules/inventario/api';
import { formatearCantidad, formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { AvisoError, Cargando, Casilla, EnlaceBoton, Encabezado, Tarjeta } from '@/shared/ui';
import { UNIDADES, bajoStock, presentacionBase, stockDe, useProductos } from './api';

/** Compara sin tildes ni mayúsculas: "azucar" encuentra "Azúcar". */
function normalizar(texto: string): string {
  return texto.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
}

export function ListaProductos() {
  const contexto = useContexto();
  const esDueno = contexto.rol === 'DUENO';
  const productos = useProductos();
  const valorizado = useValorizado(contexto.ve_costos);

  const [busqueda, setBusqueda] = useState('');
  const [soloBajos, setSoloBajos] = useState(false);
  const [verInactivos, setVerInactivos] = useState(false);

  const costos = useMemo(
    () => new Map(valorizado.data?.productos.map((p) => [p.producto_id, p]) ?? []),
    [valorizado.data],
  );

  const visibles = useMemo(() => {
    const texto = normalizar(busqueda.trim());
    return (productos.data ?? []).filter(
      (p) =>
        (verInactivos || p.activo) &&
        (!soloBajos || bajoStock(p)) &&
        (texto === '' ||
          normalizar(p.nombre).includes(texto) ||
          [p.codigo_principal, p.codigo_auxiliar].some((c) => c !== null && normalizar(c) === texto) ||
          p.presentaciones.some((r) => r.codigo_barras === busqueda.trim())),
    );
  }, [productos.data, busqueda, soloBajos, verInactivos]);

  const cuantosBajos = (productos.data ?? []).filter(bajoStock).length;

  return (
    <>
      <Encabezado
        titulo="Productos"
        acciones={
          esDueno && (
            <>
              <EnlaceBoton href={enlace({ nombre: 'conteo' })}>Conteo</EnlaceBoton>
              <EnlaceBoton href={enlace({ nombre: 'producto-nuevo' })} variante="primario">
                Nuevo
              </EnlaceBoton>
            </>
          )
        }
      />

      {contexto.ve_costos && valorizado.data && (
        <p className="mb-3 text-sm text-gray-600">
          Inventario valorizado: <strong className="text-gray-900">{formatearCosto(valorizado.data.valor_total)}</strong>
        </p>
      )}

      <div className="mb-4 flex flex-col gap-2">
        <input
          type="search"
          inputMode="search"
          placeholder="Buscar por nombre o código de barras"
          aria-label="Buscar producto"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
          className="min-h-11 rounded-lg border border-gray-300 bg-white px-3 text-base"
        />
        <div className="flex flex-wrap gap-x-6">
          <Casilla
            etiqueta={`Solo bajo stock (${cuantosBajos})`}
            checked={soloBajos}
            onChange={(e) => setSoloBajos(e.target.checked)}
          />
          {esDueno && (
            <Casilla etiqueta="Ver inactivos" checked={verInactivos} onChange={(e) => setVerInactivos(e.target.checked)} />
          )}
        </div>
      </div>

      {productos.isPending && <Cargando />}
      <AvisoError error={productos.error} />

      {productos.isSuccess && visibles.length === 0 && (
        <Tarjeta>
          <p className="text-gray-600">
            {productos.data.length === 0
              ? esDueno
                ? 'Todavía no hay productos. Crea el primero con «Nuevo».'
                : 'Todavía no hay productos.'
              : 'Ningún producto coincide con la búsqueda.'}
          </p>
        </Tarjeta>
      )}

      <ul className="flex flex-col gap-2">
        {visibles.map((p) => {
          const base = presentacionBase(p);
          const costo = costos.get(p.id);
          const bajo = bajoStock(p);
          return (
            <li key={p.id}>
              <a
                href={enlace({ nombre: 'producto', id: p.id })}
                className={`flex items-center gap-3 rounded-xl border bg-white p-3 hover:border-gray-400 ${
                  p.activo ? 'border-gray-200' : 'border-dashed border-gray-300 opacity-60'
                }`}
              >
                <div className="min-w-0 flex-1">
                  <p className="truncate font-medium">{p.nombre}</p>
                  <p className="truncate text-sm text-gray-500">
                    {[p.categorias?.nombre, base?.precio_venta ? formatearDinero(base.precio_venta) : 'Sin precio']
                      .filter(Boolean)
                      .join(' · ')}
                    {costo?.costo_promedio && ` · costo ${formatearCosto(costo.costo_promedio)}`}
                  </p>
                </div>
                {p.controla_stock ? (
                  <div className="text-right">
                    <p className={`font-semibold tabular-nums ${bajo ? 'text-red-700' : ''}`}>
                      {formatearCantidad(stockDe(p))}
                    </p>
                    <p className="text-xs text-gray-500">{bajo ? 'bajo stock' : UNIDADES[p.unidad_base]}</p>
                  </div>
                ) : (
                  <p className="text-right text-xs text-gray-500">sin stock</p>
                )}
              </a>
            </li>
          );
        })}
      </ul>
    </>
  );
}
