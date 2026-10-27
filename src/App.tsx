import { FichaProducto } from '@/modules/catalogo/FichaProducto';
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

function Marco({ contexto, correo }: { contexto: Contexto; correo: string }) {
  const ruta = useRuta();
  return (
    <div className="min-h-dvh">
      <nav className="sticky top-0 z-10 border-b border-gray-200 bg-white">
        <div className="mx-auto flex max-w-3xl items-center gap-3 px-4 py-2">
          <a href={enlace({ nombre: 'productos' })} className="flex-1 truncate font-semibold">
            {contexto.nombre}
          </a>
          <span className="hidden text-sm text-gray-500 sm:inline">
            {correo} · {contexto.rol === 'DUENO' ? 'Dueño' : 'Vendedor'}
          </span>
          <Boton variante="secundario" onClick={() => void cerrarSesion()}>
            Salir
          </Boton>
        </div>
      </nav>
      <main className="mx-auto max-w-3xl p-4">
        <Pantalla ruta={ruta} esDueno={contexto.rol === 'DUENO'} />
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
    case 'no-encontrada':
      return (
        <Tarjeta>
          Esta página no existe. <a href={enlace({ nombre: 'productos' })} className="underline">Ir a productos</a>
        </Tarjeta>
      );
  }
}
