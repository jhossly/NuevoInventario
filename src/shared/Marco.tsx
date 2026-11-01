import { useEffect, useState, type ReactNode } from 'react';
import {
  ChartColumn,
  ClipboardCheck,
  FileText,
  HandCoins,
  LogOut,
  Menu,
  Package,
  Percent,
  ReceiptText,
  Ruler,
  ShoppingCart,
  Store,
  Truck,
  Users,
  Wallet,
  Warehouse,
  X,
} from 'lucide-react';
import { cerrarSesion, type Contexto } from '@/modules/sesion/sesion';
import { enlace, type Ruta } from '@/shared/ruta';
import type { Icono } from '@/shared/ui';

interface Seccion {
  titulo: string;
  icono: Icono;
  ruta: Ruta;
  incluye: Ruta['nombre'][];
  soloDueno?: boolean;
}

/** Agrupado por lo que la persona quiere hacer, no por cómo está hecho el sistema. */
const GRUPOS: { titulo: string; secciones: Seccion[] }[] = [
  {
    titulo: 'Día a día',
    secciones: [
      { titulo: 'Vender', icono: ShoppingCart, ruta: { nombre: 'vender' }, incluye: ['vender'] },
      { titulo: 'Caja', icono: Wallet, ruta: { nombre: 'caja' }, incluye: ['caja'] },
      { titulo: 'Fiado', icono: HandCoins, ruta: { nombre: 'fiado' }, incluye: ['fiado'] },
      { titulo: 'Ventas', icono: ReceiptText, ruta: { nombre: 'ventas' }, incluye: ['ventas', 'venta'] },
      { titulo: 'Clientes', icono: Users, ruta: { nombre: 'clientes' }, incluye: ['clientes'] },
    ],
  },
  {
    titulo: 'Mercadería',
    secciones: [
      {
        titulo: 'Productos',
        icono: Package,
        ruta: { nombre: 'productos' },
        incluye: ['productos', 'producto-nuevo', 'producto', 'ajuste', 'kardex'],
      },
      { titulo: 'Conteo', icono: ClipboardCheck, ruta: { nombre: 'conteo' }, incluye: ['conteo'], soloDueno: true },
      { titulo: 'Medidas', icono: Ruler, ruta: { nombre: 'medidas' }, incluye: ['medidas'], soloDueno: true },
      {
        titulo: 'Compras',
        icono: Truck,
        ruta: { nombre: 'compras' },
        incluye: ['compras', 'compra-nueva', 'compra'],
        soloDueno: true,
      },
      { titulo: 'Proveedores', icono: Warehouse, ruta: { nombre: 'proveedores' }, incluye: ['proveedores'], soloDueno: true },
    ],
  },
  {
    titulo: 'Negocio',
    secciones: [
      { titulo: 'Facturas SRI', icono: FileText, ruta: { nombre: 'comprobantes' }, incluye: ['comprobantes'], soloDueno: true },
      { titulo: 'Reportes', icono: ChartColumn, ruta: { nombre: 'reportes' }, incluye: ['reportes'], soloDueno: true },
      { titulo: 'IVA de ventas', icono: Percent, ruta: { nombre: 'iva-ventas' }, incluye: ['iva-ventas'], soloDueno: true },
      { titulo: 'Mi negocio', icono: Store, ruta: { nombre: 'mi-negocio' }, incluye: ['mi-negocio'], soloDueno: true },
    ],
  },
];

/** Lo que más se usa queda siempre a la mano en el celular. */
const BARRA_INFERIOR: Ruta['nombre'][] = ['vender', 'caja', 'productos', 'ventas'];

const todas = GRUPOS.flatMap((g) => g.secciones);

function Identidad({ contexto }: { contexto: Contexto }) {
  return (
    <a href={enlace({ nombre: 'vender' })} className="flex min-w-0 items-center gap-3">
      {contexto.logo ? (
        <img src={contexto.logo} alt="" className="size-10 shrink-0 rounded-lg bg-white object-contain" />
      ) : (
        <span className="flex size-10 shrink-0 items-center justify-center rounded-lg bg-emerald-700 text-white">
          <Store className="size-6" aria-hidden />
        </span>
      )}
      <span className="truncate font-bold">{contexto.nombre}</span>
    </a>
  );
}

function Lista({ esDueno, ruta, alElegir }: { esDueno: boolean; ruta: Ruta; alElegir?: () => void }) {
  return (
    <>
      {GRUPOS.map((grupo) => {
        const visibles = grupo.secciones.filter((s) => esDueno || !s.soloDueno);
        if (visibles.length === 0) return null;
        return (
          <div key={grupo.titulo} className="mb-4">
            <p className="mb-1 px-3 text-xs font-semibold uppercase tracking-wide text-gray-500">{grupo.titulo}</p>
            {visibles.map((s) => (
              <a
                key={s.titulo}
                href={enlace(s.ruta)}
                onClick={alElegir}
                aria-current={s.incluye.includes(ruta.nombre) ? 'page' : undefined}
                className="flex min-h-11 items-center gap-3 rounded-lg px-3 text-gray-700 hover:bg-gray-100 aria-[current=page]:bg-emerald-50 aria-[current=page]:font-semibold aria-[current=page]:text-emerald-800"
              >
                <s.icono className="size-5 shrink-0" aria-hidden />
                {s.titulo}
              </a>
            ))}
          </div>
        );
      })}
    </>
  );
}

function Salir({ correo, contexto }: { correo: string; contexto: Contexto }) {
  return (
    <div className="border-t border-gray-200 pt-3">
      <p className="truncate px-3 text-sm text-gray-500">{correo}</p>
      <p className="mb-1 px-3 text-sm text-gray-500">{contexto.rol === 'DUENO' ? 'Dueño' : 'Vendedor'}</p>
      <button
        type="button"
        onClick={() => void cerrarSesion()}
        className="flex min-h-11 w-full items-center gap-3 rounded-lg px-3 text-gray-700 hover:bg-gray-100"
      >
        <LogOut className="size-5" aria-hidden />
        Salir
      </button>
    </div>
  );
}

/**
 * Panel lateral en la computadora; en el celular, barra inferior con lo más
 * usado y «Más» para el resto.
 */
export function Marco({
  contexto,
  correo,
  ruta,
  children,
}: {
  contexto: Contexto;
  correo: string;
  ruta: Ruta;
  children: ReactNode;
}) {
  const esDueno = contexto.rol === 'DUENO';
  const [abierto, setAbierto] = useState(false);

  useEffect(() => {
    setAbierto(false);
  }, [ruta]);

  return (
    <div className="min-h-dvh md:pl-64 print:pl-0">
      <aside className="fixed inset-y-0 left-0 hidden w-64 flex-col border-r border-gray-200 bg-white p-3 md:flex print:hidden">
        <div className="mb-4 px-1 py-1">
          <Identidad contexto={contexto} />
        </div>
        <nav className="min-h-0 flex-1 overflow-y-auto" aria-label="Menú principal">
          <Lista esDueno={esDueno} ruta={ruta} />
        </nav>
        <Salir correo={correo} contexto={contexto} />
      </aside>

      <header className="sticky top-0 z-10 border-b border-gray-200 bg-white px-4 py-2 md:hidden print:hidden">
        <Identidad contexto={contexto} />
      </header>

      <main className="mx-auto max-w-5xl p-4 pb-24 md:pb-4 print:p-0">{children}</main>

      <nav
        className="fixed inset-x-0 bottom-0 z-10 grid grid-cols-5 border-t border-gray-200 bg-white md:hidden print:hidden"
        aria-label="Menú rápido"
      >
        {BARRA_INFERIOR.map((nombre) => {
          const s = todas.find((x) => x.ruta.nombre === nombre);
          if (!s) return null;
          return (
            <a
              key={nombre}
              href={enlace(s.ruta)}
              aria-current={s.incluye.includes(ruta.nombre) ? 'page' : undefined}
              className="flex min-h-14 flex-col items-center justify-center gap-0.5 text-xs text-gray-600 aria-[current=page]:font-semibold aria-[current=page]:text-emerald-800"
            >
              <s.icono className="size-6" aria-hidden />
              {s.titulo}
            </a>
          );
        })}
        <button
          type="button"
          onClick={() => setAbierto(true)}
          className="flex min-h-14 flex-col items-center justify-center gap-0.5 text-xs text-gray-600"
        >
          <Menu className="size-6" aria-hidden />
          Más
        </button>
      </nav>

      {abierto && (
        <div className="fixed inset-0 z-20 md:hidden">
          <button
            type="button"
            aria-label="Cerrar menú"
            className="absolute inset-0 bg-black/40"
            onClick={() => setAbierto(false)}
          />
          <div className="absolute inset-y-0 right-0 flex w-72 max-w-[85%] flex-col bg-white p-3">
            <div className="mb-3 flex items-center justify-between gap-2">
              <span className="px-3 font-bold">Menú</span>
              <button
                type="button"
                aria-label="Cerrar menú"
                className="rounded-lg p-2 text-gray-600 hover:bg-gray-100"
                onClick={() => setAbierto(false)}
              >
                <X className="size-6" aria-hidden />
              </button>
            </div>
            <nav className="min-h-0 flex-1 overflow-y-auto" aria-label="Menú completo">
              <Lista esDueno={esDueno} ruta={ruta} alElegir={() => setAbierto(false)} />
            </nav>
            <Salir correo={correo} contexto={contexto} />
          </div>
        </div>
      )}
    </div>
  );
}
