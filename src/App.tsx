import { FichaProducto } from '@/modules/catalogo/FichaProducto';
import { DetalleCompra } from '@/modules/compras/DetalleCompra';
import { ListaCompras } from '@/modules/compras/ListaCompras';
import { NuevaCompra } from '@/modules/compras/NuevaCompra';
import { Proveedores } from '@/modules/compras/Proveedores';
import { Caja } from '@/modules/caja/Caja';
import { Fiado } from '@/modules/caja/Fiado';
import { Reportes } from '@/modules/reportes/Reportes';
import { Clientes } from '@/modules/ventas/Clientes';
import { DetalleVenta } from '@/modules/ventas/DetalleVenta';
import { ListaVentas } from '@/modules/ventas/ListaVentas';
import { PuntoVenta } from '@/modules/ventas/PuntoVenta';
import { FormProducto } from '@/modules/catalogo/FormProducto';
import { ListaProductos } from '@/modules/catalogo/ListaProductos';
import { Conteo } from '@/modules/inventario/Conteo';
import { PantallaAjuste } from '@/modules/inventario/FormAjuste';
import { Kardex } from '@/modules/inventario/Kardex';
import { PantallaIngreso } from '@/modules/sesion/PantallaIngreso';
import { cerrarSesion, useSesion, type Contexto } from '@/modules/sesion/sesion';
import { enlace, useRuta, type Ruta } from '@/shared/ruta';
import { Aviso, Boton, Cargando, Encabezado, Tarjeta } from '@/shared/ui';

export function App() {
  const sesion = useSesion();

  switch (sesion.estado) {
    case 'cargando':
      return <Cargando />;
    case 'sin-sesion':
      return <PantallaIngreso />;
    case 'sin-empresa':
      return (
        <main className="mx-auto max-w-md p-4">
          <Aviso>
            La cuenta {sesion.correo} no tiene acceso a ninguna bodega, o fue desactivada. Pide al Dueño que te invite.
          </Aviso>
          <Boton variante="secundario" className="mt-4" onClick={() => void cerrarSesion()}>
            Salir
          </Boton>
        </main>
      );
    case 'error':
      return (
        <main className="mx-auto max-w-md p-4">
          <Aviso>No se pudo cargar tu cuenta: {sesion.mensaje}</Aviso>
          <Boton variante="secundario" className="mt-4" onClick={() => window.location.reload()}>
            Reintentar
          </Boton>
        </main>
      );
    case 'lista':
      return <Marco contexto={sesion.contexto} correo={sesion.correo} />;
  }
}

const SECCIONES: { titulo: string; ruta: Ruta; incluye: Ruta['nombre'][]; soloDueno?: boolean }[] = [
  { titulo: 'Vender', ruta: { nombre: 'vender' }, incluye: ['vender'] },
  { titulo: 'Ventas', ruta: { nombre: 'ventas' }, incluye: ['ventas', 'venta', 'clientes'] },
  { titulo: 'Caja', ruta: { nombre: 'caja' }, incluye: ['caja'] },
  { titulo: 'Fiado', ruta: { nombre: 'fiado' }, incluye: ['fiado'] },
  {
    titulo: 'Productos',
    ruta: { nombre: 'productos' },
    incluye: ['productos', 'producto-nuevo', 'producto', 'ajuste', 'kardex', 'conteo'],
  },
  {
    titulo: 'Compras',
    ruta: { nombre: 'compras' },
    incluye: ['compras', 'compra-nueva', 'compra', 'proveedores'],
    soloDueno: true,
  },
  { titulo: 'Reportes', ruta: { nombre: 'reportes' }, incluye: ['reportes'], soloDueno: true },
];

function Marco({ contexto, correo }: { contexto: Contexto; correo: string }) {
  const ruta = useRuta();
  const esDueno = contexto.rol === 'DUENO';
  return (
    <div className="min-h-dvh">
      <nav className="sticky top-0 z-10 border-b border-gray-200 bg-white">
        <div className="mx-auto flex max-w-5xl items-center gap-2 px-4 py-2">
          <a href={enlace({ nombre: 'vender' })} className="hidden max-w-40 shrink-0 truncate font-semibold sm:block">
            {contexto.nombre}
          </a>
          {/* En el celular las secciones no caben: se desplazan de lado. */}
          <div className="flex min-w-0 flex-1 gap-1 overflow-x-auto">
            {SECCIONES.filter((s) => esDueno || !s.soloDueno).map((s) => (
              <a
                key={s.titulo}
                href={enlace(s.ruta)}
                aria-current={s.incluye.includes(ruta.nombre) ? 'page' : undefined}
                className="whitespace-nowrap rounded-lg px-2 py-2 text-sm text-gray-600 hover:bg-gray-100 aria-[current=page]:font-semibold aria-[current=page]:text-gray-900"
              >
                {s.titulo}
              </a>
            ))}
          </div>
          <span className="hidden shrink-0 text-sm text-gray-500 lg:inline">
            {correo} · {contexto.rol === 'DUENO' ? 'Dueño' : 'Vendedor'}
          </span>
          <Boton variante="secundario" onClick={() => void cerrarSesion()}>
            Salir
          </Boton>
        </div>
      </nav>
      <main className="mx-auto max-w-5xl p-4">
        <Pantalla ruta={ruta} esDueno={esDueno} />
      </main>
    </div>
  );
}

function Pantalla({ ruta, esDueno }: { ruta: Ruta; esDueno: boolean }) {
  // La base rechaza igual cualquier escritura del Vendedor; esto solo evita
  // mostrarle formularios que no puede usar.
  const soloDueno = (contenido: JSX.Element) =>
    esDueno ? contenido : <Tarjeta>Esta pantalla es solo para el Dueño.</Tarjeta>;

  switch (ruta.nombre) {
    case 'productos':
      return <ListaProductos />;
    case 'producto-nuevo':
      return soloDueno(
        <>
          <Encabezado titulo="Nuevo producto" volver={enlace({ nombre: 'productos' })} />
          <Tarjeta>
            <FormProducto />
          </Tarjeta>
        </>,
      );
    case 'producto':
      return <FichaProducto id={ruta.id} />;
    case 'ajuste':
      return soloDueno(<PantallaAjuste id={ruta.id} />);
    case 'kardex':
      return <Kardex id={ruta.id} />;
    case 'conteo':
      return soloDueno(<Conteo />);
    case 'compras':
      return soloDueno(<ListaCompras />);
    case 'compra-nueva':
      return soloDueno(<NuevaCompra />);
    case 'compra':
      return soloDueno(<DetalleCompra id={ruta.id} />);
    case 'proveedores':
      return soloDueno(<Proveedores />);
    case 'vender':
      return <PuntoVenta />;
    case 'ventas':
      return <ListaVentas />;
    case 'venta':
      return <DetalleVenta id={ruta.id} />;
    case 'clientes':
      return <Clientes />;
    case 'caja':
      return <Caja />;
    case 'fiado':
      return <Fiado />;
    case 'reportes':
      return soloDueno(<Reportes />);
    case 'no-encontrada':
      return (
        <Tarjeta>
          Esta página no existe. <a href={enlace({ nombre: 'productos' })} className="underline">Ir a productos</a>
        </Tarjeta>
      );
  }
}
