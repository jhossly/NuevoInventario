import { useMemo, useState } from 'react';
import { useContexto } from '@/modules/sesion/sesion';
import { useValorizado } from '@/modules/inventario/api';
import { formatearCantidad, formatearCosto, formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { ClipboardCheck, Plus } from 'lucide-react';
import { AvisoError, Buscador, Cargando, Casilla, EnlaceBoton, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import { FotoProducto } from './FotoProducto';
import {
  bajoStock,
  presentacionBase,
  stockDe,
  unidadCorta,
  useCategorias,
  useProductos,
  useProveedoresDeProductos,
} from './api';

/** Compara sin tildes ni mayúsculas: "azucar" encuentra "Azúcar". */
function normalizar(texto: string): string {
  return texto.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
}

export function ListaProductos() {
  const contexto = useContexto();
  const esDueno = contexto.rol === 'DUENO';
  const productos = useProductos();
  const valorizado = useValorizado(contexto.ve_costos);
  const categorias = useCategorias();
  const proveedores = useProveedoresDeProductos(esDueno);

  const [busqueda, setBusqueda] = useState('');
  const [soloBajos, setSoloBajos] = useState(false);
  const [verInactivos, setVerInactivos] = useState(false);
  const [categoria, setCategoria] = useState('');
  const [proveedor, setProveedor] = useState('');

  const costos = useMemo(
    () => new Map(valorizado.data?.productos.map((p) => [p.producto_id, p]) ?? []),
    [valorizado.data],
  );

  const visibles = useMemo(() => {
    const texto = normalizar(busqueda.trim());
    const delProveedor = proveedor ? new Set(proveedores.data?.find((v) => v.id === proveedor)?.productos) : null;
    return (productos.data ?? []).filter(
      (p) =>
        (verInactivos || p.activo) &&
        (!soloBajos || bajoStock(p)) &&
        (categoria === '' || (categoria === 'ninguna' ? p.categoria_id === null : p.categoria_id === categoria)) &&
        (!delProveedor || delProveedor.has(p.id)) &&
        (texto === '' ||
          normalizar(p.nombre).includes(texto) ||
          [p.codigo_principal, p.codigo_auxiliar].some((c) => c !== null && normalizar(c) === texto) ||
          p.presentaciones.some((r) => r.codigo_barras === busqueda.trim())),
    );
  }, [productos.data, proveedores.data, busqueda, soloBajos, verInactivos, categoria, proveedor]);

  const cuantosBajos = (productos.data ?? []).filter(bajoStock).length;

  return (
    <>
      <Encabezado
        titulo="Productos"
        acciones={
          esDueno && (
            <>
              <EnlaceBoton href={enlace({ nombre: 'conteo' })} icono={ClipboardCheck}>
                Conteo
              </EnlaceBoton>
              <EnlaceBoton href={enlace({ nombre: 'producto-nuevo' })} variante="primario" icono={Plus}>
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
        <Buscador
          etiqueta="Buscar por nombre o código"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
        <div className="grid gap-2 sm:grid-cols-2">
          <Selector etiqueta="Categoría" value={categoria} onChange={(e) => setCategoria(e.target.value)}>
            <option value="">Todas</option>
            <option value="ninguna">Sin categoría</option>
            {categorias.data?.map((c) => (
              <option key={c.id} value={c.id}>
                {c.nombre}
              </option>
            ))}
          </Selector>
          {esDueno && (
            <Selector etiqueta="Proveedor" value={proveedor} onChange={(e) => setProveedor(e.target.value)}>
              <option value="">Todos</option>
              {proveedores.data?.map((v) => (
                <option key={v.id} value={v.id}>
                  {v.nombre}
                </option>
              ))}
            </Selector>
          )}
        </div>
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
              : 'Ningún producto coincide con la búsqueda o los filtros.'}
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
                <FotoProducto imagen={p.imagen} />
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
                    <p className="text-xs text-gray-500">{bajo ? 'bajo stock' : unidadCorta(p.unidad_base)}</p>
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
