import { useEffect, useState, type ReactNode } from 'react';
import {
  Calculator,
  ChartColumn,
  ClipboardCheck,
  FileText,
  HandCoins,
  KeyRound,
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
import { porCompletar, useProductos } from '@/modules/catalogo/api';
import { borrarBorradoresDe } from '@/shared/borrador';
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
        incluye: ['compras', 'compra-nueva', 'compra-factura', 'compra'],
        soloDueno: true,
      },
      {
        titulo: '¿Cuánto gano?',
        icono: Calculator,
        ruta: { nombre: 'compra-simular' },
        incluye: ['compra-simular'],
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

type Avisos = Partial<Record<Ruta['nombre'], number>>;

/** Número pequeño junto a una sección que tiene algo pendiente. */
function Contador({ n }: { n: number }) {
  if (n <= 0) return null;
  return (
    <span className="ml-auto rounded-full bg-amber-500 px-1.5 text-xs font-semibold leading-5 text-white" aria-label={`${n} pendientes`}>
      {n}
    </span>
  );
}

function Lista({
  esDueno,
  ruta,
  avisos,
  alElegir,
}: {
  esDueno: boolean;
  ruta: Ruta;
  avisos: Avisos;
  alElegir?: () => void;
}) {
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
                <Contador n={avisos[s.ruta.nombre] ?? 0} />
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
      <a
        href={enlace({ nombre: 'mi-clave' })}
        className="flex min-h-11 w-full items-center gap-3 rounded-lg px-3 text-gray-700 hover:bg-gray-100"
      >
        <KeyRound className="size-5" aria-hidden />
        Cambiar contraseña
      </a>
      <button
        type="button"
        onClick={() => {
          borrarBorradoresDe(correo);
          void cerrarSesion();
        }}
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
  // Productos creados desde compras que faltan completar (D-067).
  const productos = useProductos();
  const avisos: Avisos = { productos: esDueno ? porCompletar(productos.data).length : 0 };

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
          <Lista esDueno={esDueno} ruta={ruta} avisos={avisos} />
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
              className="relative flex min-h-14 flex-col items-center justify-center gap-0.5 text-xs text-gray-600 aria-[current=page]:font-semibold aria-[current=page]:text-emerald-800"
            >
              {(avisos[s.ruta.nombre] ?? 0) > 0 && (
                <span className="absolute right-3 top-1.5 size-2.5 rounded-full bg-amber-500" aria-label="Tiene pendientes" />
              )}
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
              <Lista esDueno={esDueno} ruta={ruta} avisos={avisos} alElegir={() => setAbierto(false)} />
            </nav>
            <Salir correo={correo} contexto={contexto} />
          </div>
        </div>
      )}
    </div>
  );
}
