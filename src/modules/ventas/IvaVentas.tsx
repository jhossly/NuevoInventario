import { useState, type FormEvent } from 'react';
import { formatearFecha } from '@/modules/compras/api';
import { aTexto } from '@/shared/fechas';
import { enlace } from '@/shared/ruta';
import { Aviso, AvisoError, Boton, Campo, Encabezado, Selector, Tarjeta, Cargando } from '@/shared/ui';
import { periodoVigente, useFijarIva, usePeriodosIva, useQuitarIva, type PeriodoIva } from './api';

const textoPeriodo = (p: Pick<PeriodoIva, 'iva_cero'>) =>
  p.iva_cero ? 'Ventas con IVA 0 %' : 'Ventas con la tarifa de cada producto';

/**
 * IVA de ventas por fecha (D-045): desde un día, toda venta sale con IVA 0 %
 * o vuelve a la tarifa de cada producto. Las ventas ya hechas no cambian.
 */
export function IvaVentas() {
  const periodos = usePeriodosIva();
  const fijar = useFijarIva();
  const quitar = useQuitarIva();
  const hoy = aTexto(new Date());

  const [desde, setDesde] = useState(hoy);
  const [modo, setModo] = useState<'cero' | 'tarifa'>('cero');
  const [nota, setNota] = useState('');
  const [guardado, setGuardado] = useState(false);

  const lista = periodos.data ?? [];
  const vigente = periodoVigente(lista, hoy);

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    setGuardado(false);
    fijar.mutate(
      { desde, ivaCero: modo === 'cero', nota: nota.trim() || null },
      {
        onSuccess: () => {
          setGuardado(true);
          setNota('');
        },
      },
    );
  };

  return (
    <>
      <Encabezado titulo="IVA de ventas" volver={enlace({ nombre: 'reportes' })} />

      <Tarjeta className="mb-4">
        <p className="text-sm text-gray-600">Hoy:</p>
        <p className="text-lg font-semibold">{textoPeriodo(vigente ?? { iva_cero: false })}</p>
        {vigente && <p className="text-sm text-gray-600">desde el {formatearFecha(vigente.desde)}</p>}
        <p className="mt-2 text-sm text-gray-600">
          La tarifa de cada producto (0 %, 5 %, 15 %, No objeto, Exento) se guarda siempre y se vuelve a usar cuando las
          ventas dejen de ir con IVA 0 %.
        </p>
      </Tarjeta>

      <Tarjeta className="mb-4">
        <h2 className="mb-3 font-semibold">Cambiar desde una fecha</h2>
        <form onSubmit={enviar} className="flex flex-col gap-3" noValidate>
          <div className="grid grid-cols-2 gap-3">
            <Campo etiqueta="Desde" type="date" min={hoy} value={desde} onChange={(e) => setDesde(e.target.value)} />
            <Selector etiqueta="Las ventas van" value={modo} onChange={(e) => setModo(e.target.value as 'cero' | 'tarifa')}>
              <option value="cero">Con IVA 0 %</option>
              <option value="tarifa">Con la tarifa de cada producto</option>
            </Selector>
          </div>
          <Campo
            etiqueta="Nota (opcional)"
            ayuda="Por ejemplo, la resolución o el motivo"
            value={nota}
            maxLength={200}
            onChange={(e) => setNota(e.target.value)}
            autoComplete="off"
          />
          <AvisoError error={fijar.error} />
          {guardado && <Aviso tipo="exito">Guardado</Aviso>}
          <Boton type="submit" disabled={fijar.isPending || !desde}>
            {fijar.isPending ? 'Guardando…' : 'Guardar'}
          </Boton>
        </form>
      </Tarjeta>

      {periodos.isPending && <Cargando />}
      <AvisoError error={periodos.error ?? quitar.error} />
      {lista.length > 0 && <h2 className="mb-2 font-semibold">Historial</h2>}
      <ul className="flex flex-col gap-2">
        {lista.map((p) => (
          <li key={p.id} className="flex items-center gap-3 rounded-xl border border-gray-200 bg-white p-3 text-sm">
            <div className="min-w-0 flex-1">
              <p className="font-medium">
                Desde el {formatearFecha(p.desde)}: {p.iva_cero ? 'IVA 0 %' : 'tarifa de cada producto'}
              </p>
              {p.nota && <p className="text-gray-500">{p.nota}</p>}
            </div>
            {p.desde > hoy ? (
              <Boton
                variante="secundario"
                disabled={quitar.isPending}
                onClick={() => window.confirm('¿Quitar este cambio programado?') && quitar.mutate(p.id)}
              >
                Quitar
              </Boton>
            ) : (
              p.id === vigente?.id && <span className="text-green-800">vigente</span>
            )}
          </li>
        ))}
      </ul>
    </>
  );
}
