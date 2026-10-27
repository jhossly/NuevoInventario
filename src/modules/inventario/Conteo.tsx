import { useMemo, useState } from 'react';
import { UNIDADES, stockDe, useProductos, type Producto } from '@/modules/catalogo/api';
import { leerDecimal, paraEditar } from '@/shared/decimal';
import { formatearCantidad } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { Aviso, AvisoError, Boton, Cargando, Encabezado } from '@/shared/ui';
import { useConfirmarConteo, useConteoBorrador, useGuardarConteo, type LineaConteo } from './api';

/**
 * Conteo físico en dos pasos (D-022): se va guardando como borrador mientras
 * el Dueño recorre la bodega, y al confirmar el stock queda igual a lo contado.
 * Solo se envían los productos con un número escrito.
 */
const nProductos = (n: number) => (n === 1 ? '1 producto' : `${n} productos`);

export function Conteo() {
  const productos = useProductos();
  const borrador = useConteoBorrador();

  if (productos.isPending || borrador.isPending) return <Cargando />;
  if (productos.error || borrador.error) return <AvisoError error={productos.error ?? borrador.error} />;

  // El borrador solo se usa para arrancar: después el formulario lleva su
  // propio conteoId, y guardar o confirmar no lo reinician.
  return <FormConteo productos={productos.data} borrador={borrador.data} />;
}

function FormConteo({
  productos,
  borrador,
}: {
  productos: Producto[];
  borrador: { id: string; nota: string | null; conteo_detalles: LineaConteo[] } | null;
}) {
  const guardar = useGuardarConteo();
  const confirmar = useConfirmarConteo();

  const [conteoId, setConteoId] = useState<string | null>(borrador?.id ?? null);
  const [nota, setNota] = useState(borrador?.nota ?? '');
  const [contado, setContado] = useState<Record<string, string>>(() =>
    Object.fromEntries((borrador?.conteo_detalles ?? []).map((d) => [d.producto_id, paraEditar(d.cantidad_contada)])),
  );
  const [busqueda, setBusqueda] = useState('');
  const [errores, setErrores] = useState<Record<string, string>>({});
  const [mensaje, setMensaje] = useState<string | null>(null);

  const activos = useMemo(() => productos.filter((p) => p.activo), [productos]);
  const visibles = activos.filter((p) => p.nombre.toLowerCase().includes(busqueda.trim().toLowerCase()));
  const escritos = Object.entries(contado).filter(([, v]) => v.trim() !== '');

  /** Valida lo escrito; devuelve las líneas o null si hay errores. */
  const leerLineas = (): LineaConteo[] | null => {
    const nuevos: Record<string, string> = {};
    const lineas: LineaConteo[] = [];
    for (const [productoId, texto] of escritos) {
      const leido = leerDecimal(texto, { decimales: 3 });
      if (leido.ok) lineas.push({ producto_id: productoId, cantidad_contada: leido.valor });
      else nuevos[productoId] = leido.mensaje;
    }
    setErrores(nuevos);
    if (Object.keys(nuevos).length > 0) return null;
    if (lineas.length === 0) {
      setMensaje(null);
      setErrores({ general: 'Escribe al menos una cantidad contada' });
      return null;
    }
    return lineas;
  };

  const guardarBorrador = async (): Promise<string | null> => {
    const lineas = leerLineas();
    if (!lineas) return null;
    const r = await guardar.mutateAsync({ conteoId, lineas, nota: nota.trim() || null });
    setConteoId(r.conteo_id);
    return r.conteo_id;
  };

  const alGuardar = async () => {
    setMensaje(null);
    try {
      if (await guardarBorrador()) setMensaje('Borrador guardado. Puedes seguir contando después.');
    } catch {
      // El error se muestra desde guardar.error.
    }
  };

  const alConfirmar = async () => {
    setMensaje(null);
    if (!window.confirm(`¿Confirmar el conteo de ${nProductos(escritos.length)}? El stock quedará igual a lo contado.`)) {
      return;
    }
    try {
      const id = await guardarBorrador();
      if (!id) return;
      const r = await confirmar.mutateAsync(id);
      setContado({});
      setNota('');
      setConteoId(null);
      setMensaje(
        r.movimientos === 0
          ? 'Conteo confirmado: todo coincidía con el sistema.'
          : `Conteo confirmado: se corrigió el stock de ${nProductos(r.movimientos)}.`,
      );
    } catch {
      // El error se muestra desde guardar.error o confirmar.error.
    }
  };

  const ocupado = guardar.isPending || confirmar.isPending;

  return (
    <>
      <Encabezado titulo="Conteo físico" volver={enlace({ nombre: 'productos' })} />

      {conteoId && <Aviso tipo="info">Continúas un conteo en borrador.</Aviso>}

      <div className="my-4 flex flex-col gap-2">
        <input
          type="search"
          placeholder="Buscar producto"
          aria-label="Buscar producto"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
          className="min-h-11 rounded-lg border border-gray-300 bg-white px-3 text-base"
        />
        <input
          placeholder="Nota (opcional): conteo de fin de mes…"
          aria-label="Nota del conteo"
          value={nota}
          onChange={(e) => setNota(e.target.value)}
          className="min-h-11 rounded-lg border border-gray-300 bg-white px-3 text-base"
        />
      </div>

      <ul className="flex flex-col gap-2">
        {visibles.map((p) => {
          const texto = contado[p.id] ?? '';
          const leido = texto.trim() === '' ? null : leerDecimal(texto, { decimales: 3 });
          const diferencia = leido?.ok ? Number(leido.valor) - Number(stockDe(p)) : null;
          return (
            <li key={p.id} className="flex items-center gap-3 rounded-xl border border-gray-200 bg-white p-3">
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">{p.nombre}</p>
                <p className="text-sm text-gray-500">
                  Sistema: {formatearCantidad(stockDe(p))} {UNIDADES[p.unidad_base]}
                  {diferencia !== null && diferencia !== 0 && (
                    <span className={diferencia > 0 ? 'text-green-800' : 'text-red-800'}>
                      {' '}
                      · {diferencia > 0 ? '+' : '−'}
                      {formatearCantidad(Math.abs(diferencia).toFixed(3))}
                    </span>
                  )}
                </p>
                {errores[p.id] && <p className="text-sm text-red-700">{errores[p.id]}</p>}
              </div>
              <input
                inputMode="decimal"
                aria-label={`Contado de ${p.nombre}`}
                placeholder="—"
                value={texto}
                onChange={(e) => setContado((c) => ({ ...c, [p.id]: e.target.value }))}
                className={`min-h-11 w-24 rounded-lg border bg-white px-3 text-right text-base tabular-nums ${
                  errores[p.id] ? 'border-red-600' : 'border-gray-300'
                }`}
              />
            </li>
          );
        })}
      </ul>

      <div className="sticky bottom-0 -mx-4 mt-4 flex flex-col gap-2 border-t border-gray-200 bg-gray-50 p-4">
        {errores.general && <Aviso>{errores.general}</Aviso>}
        <AvisoError error={guardar.error ?? confirmar.error} />
        {mensaje && <Aviso tipo="exito">{mensaje}</Aviso>}
        <p className="text-sm text-gray-600">{escritos.length === 1 ? '1 producto contado' : `${escritos.length} productos contados`}</p>
        <div className="flex gap-2">
          <Boton variante="secundario" onClick={alGuardar} disabled={ocupado} className="flex-1">
            Guardar borrador
          </Boton>
          <Boton onClick={alConfirmar} disabled={ocupado || escritos.length === 0} className="flex-1">
            {confirmar.isPending ? 'Confirmando…' : 'Confirmar'}
          </Boton>
        </div>
      </div>
    </>
  );
}

