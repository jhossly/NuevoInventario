import { FichaProducto } from '@/modules/catalogo/FichaProducto';
import { DetalleCompra } from '@/modules/compras/DetalleCompra';
import { ListaCompras } from '@/modules/compras/ListaCompras';
import { NuevaCompra } from '@/modules/compras/NuevaCompra';
import { Proveedores } from '@/modules/compras/Proveedores';
import { Caja } from '@/modules/caja/Caja';
import { Fiado } from '@/modules/caja/Fiado';
import { Reportes } from '@/modules/reportes/Reportes';
import { Comprobantes } from '@/modules/comprobantes/Comprobantes';
import { Clientes } from '@/modules/ventas/Clientes';
import { DetalleVenta } from '@/modules/ventas/DetalleVenta';
import { ListaVentas } from '@/modules/ventas/ListaVentas';
import { PuntoVenta } from '@/modules/ventas/PuntoVenta';
import { IvaVentas } from '@/modules/ventas/IvaVentas';
import { MiNegocio } from '@/modules/negocio/MiNegocio';
import { Medidas } from '@/modules/catalogo/Medidas';
import { FormProducto } from '@/modules/catalogo/FormProducto';
import { ListaProductos } from '@/modules/catalogo/ListaProductos';
import { Conteo } from '@/modules/inventario/Conteo';
import { PantallaAjuste } from '@/modules/inventario/FormAjuste';
import { Kardex } from '@/modules/inventario/Kardex';
import { PantallaIngreso } from '@/modules/sesion/PantallaIngreso';
import { cerrarSesion, useSesion } from '@/modules/sesion/sesion';
import { enlace, useRuta, type Ruta } from '@/shared/ruta';
import { Marco } from '@/shared/Marco';
import { Aviso, Boton, Cargando, Encabezado, Tarjeta } from '@/shared/ui';

export function App() {
  const sesion = useSesion();
  const ruta = useRuta();

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
      return (
        <Marco contexto={sesion.contexto} correo={sesion.correo} ruta={ruta}>
          <Pantalla ruta={ruta} esDueno={sesion.contexto.rol === 'DUENO'} />
        </Marco>
      );
  }
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
    case 'comprobantes':
      return soloDueno(<Comprobantes />);
    case 'iva-ventas':
      return soloDueno(<IvaVentas />);
    case 'mi-negocio':
      return soloDueno(<MiNegocio />);
    case 'medidas':
      return soloDueno(<Medidas />);
    case 'no-encontrada':
      return (
        <Tarjeta>
          Esta página no existe. <a href={enlace({ nombre: 'productos' })} className="underline">Ir a productos</a>
        </Tarjeta>
      );
  }
}
