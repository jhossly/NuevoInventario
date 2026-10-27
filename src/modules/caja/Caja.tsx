import { useState } from 'react';
import { useContexto } from '@/modules/sesion/sesion';
import { formatearMomento } from '@/modules/ventas/api';
import { leerDecimal } from '@/shared/decimal';
import { formatearDinero } from '@/shared/formato';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Cargando, Encabezado, Tarjeta } from '@/shared/ui';
import {
  useAbrirCaja,
  useCajasCerradas,
  useCerrarCaja,
  useExplicarDiferencia,
  useMovimientoCaja,
  useMovimientosCaja,
  useResumenCaja,
  type ResumenCaja,
} from './api';

/** Caja del turno (HU-04): abrir con fondo, ingresos y egresos, cerrar contando. */
export function Caja() {
  const esDueno = useContexto().rol === 'DUENO';
  const caja = useResumenCaja();
  const [cierre, setCierre] = useState<{ diferencia?: string; esperado?: string } | null>(null);

  return (
    <>
      <Encabezado titulo="Caja" />
      {caja.isPending && <Cargando />}
      <AvisoError error={caja.error} />
      {cierre && (
        <div className="mb-4">
          <Aviso tipo="exito">
            Caja cerrada.
            {cierre.diferencia !== undefined &&
              ` Esperado ${formatearDinero(cierre.esperado ?? '0')} · diferencia ${formatearDinero(cierre.diferencia)}.`}
          </Aviso>
        </div>
      )}
      {caja.isSuccess && !caja.data && <AbrirCaja alAbrir={() => setCierre(null)} />}
      {caja.data && <CajaAbierta caja={caja.data} esDueno={esDueno} alCerrar={setCierre} />}
      {esDueno && <Historial />}
    </>
  );
}

function AbrirCaja({ alAbrir }: { alAbrir: () => void }) {
  const abrir = useAbrirCaja();
  const [fondo, setFondo] = useState('');
  const [error, setError] = useState<string | null>(null);
  return (
    <Tarjeta className="mb-4">
      <p className="mb-3 text-gray-600">No hay una caja abierta. Sin caja no se cobra en efectivo.</p>
      <div className="flex items-end gap-2">
        <div className="flex-1">
          <Campo
            etiqueta="Fondo inicial (efectivo para dar vuelto)"
            inputMode="decimal"
            value={fondo}
            onChange={(e) => setFondo(e.target.value)}
            error={error}
          />
        </div>
        <Boton
          disabled={abrir.isPending}
          onClick={() => {
            const leido = leerDecimal(fondo || '0', { decimales: 2 });
            if (!leido.ok) return setError(leido.mensaje);
            setError(null);
            abrir.mutate(leido.valor, { onSuccess: alAbrir });
          }}
        >
          Abrir caja
        </Boton>
      </div>
      <div className="mt-3">
        <AvisoError error={abrir.error} />
      </div>
    </Tarjeta>
  );
}

function CajaAbierta({
  caja,
  esDueno,
  alCerrar,
}: {
  caja: ResumenCaja;
  esDueno: boolean;
  alCerrar: (r: { diferencia?: string; esperado?: string }) => void;
}) {
  const movimientos = useMovimientosCaja(caja.caja_id);

  return (
    <>
      <Tarjeta className="mb-4">
        <p className="mb-2 text-sm text-gray-500">Abierta {formatearMomento(caja.abierta_en)}</p>
        <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm tabular-nums">
          <dt className="text-gray-600">Fondo inicial</dt>
          <dd className="text-right">{formatearDinero(caja.fondo_inicial)}</dd>
          <dt className="text-gray-600">Ventas</dt>
          <dd className="text-right">{caja.ventas}</dd>
          {esDueno && caja.esperado !== undefined && (
            <>
              <dt className="text-gray-600">+ Ventas en efectivo</dt>
              <dd className="text-right">{formatearDinero(caja.ventas_efectivo ?? '0')}</dd>
              <dt className="text-gray-600">+ Abonos en efectivo</dt>
              <dd className="text-right">{formatearDinero(caja.abonos_efectivo ?? '0')}</dd>
              <dt className="text-gray-600">+ Ingresos</dt>
              <dd className="text-right">{formatearDinero(caja.ingresos ?? '0')}</dd>
              <dt className="text-gray-600">− Egresos</dt>
              <dd className="text-right">{formatearDinero(caja.egresos ?? '0')}</dd>
              <dt className="font-semibold">Debería haber</dt>
              <dd className="text-right font-semibold">{formatearDinero(caja.esperado)}</dd>
            </>
          )}
        </dl>
      </Tarjeta>

      <MovimientoManual />

      {(movimientos.data?.length ?? 0) > 0 && (
        <Tarjeta className="mb-4">
          <h2 className="mb-2 font-semibold">Ingresos y egresos</h2>
          <ul className="divide-y divide-gray-100 text-sm">
            {movimientos.data?.map((m) => (
              <li key={m.id} className="flex justify-between gap-2 py-1">
                <span>
                  {m.motivo}
                  {m.automatico && <span className="text-gray-500"> (automático)</span>}
                </span>
                <span className={`tabular-nums ${m.tipo === 'EGRESO' ? 'text-red-800' : 'text-green-800'}`}>
                  {m.tipo === 'EGRESO' ? '−' : '+'}
                  {formatearDinero(m.monto)}
                </span>
              </li>
            ))}
          </ul>
        </Tarjeta>
      )}

      <CerrarCaja alCerrar={alCerrar} />
    </>
  );
}

function MovimientoManual() {
  const registrar = useMovimientoCaja();
  const unaVez = useUnSoloEnvio();
  const [tipo, setTipo] = useState<'INGRESO' | 'EGRESO' | null>(null);
  const [monto, setMonto] = useState('');
  const [motivo, setMotivo] = useState('');
  const [errores, setErrores] = useState<{ monto?: string; motivo?: string }>({});
  const [clave, setClave] = useState(nuevaClave);

  if (tipo === null) {
    return (
      <div className="mb-4 flex gap-2">
        <Boton variante="secundario" onClick={() => setTipo('INGRESO')}>
          + Ingreso
        </Boton>
        <Boton variante="secundario" onClick={() => setTipo('EGRESO')}>
          − Egreso
        </Boton>
      </div>
    );
  }

  const enviar = () => {
    const leido = leerDecimal(monto, { decimales: 2, permitirCero: false });
    const nuevos = {
      monto: leido.ok ? undefined : leido.mensaje,
      motivo: motivo.trim() === '' ? 'Escribe el motivo' : undefined,
    };
    setErrores(nuevos);
    if (!leido.ok || nuevos.motivo) return;
    unaVez((terminar) =>
      registrar.mutate(
        { tipo, monto: leido.valor, motivo: motivo.trim(), clave },
        {
          onSuccess: () => {
            setTipo(null);
            setMonto('');
            setMotivo('');
            setClave(nuevaClave());
          },
          onSettled: terminar,
        },
      ),
    );
  };

  return (
    <Tarjeta className="mb-4">
      <h2 className="mb-3 font-semibold">{tipo === 'INGRESO' ? 'Ingreso de efectivo' : 'Egreso de efectivo'}</h2>
      <div className="grid grid-cols-[8rem_1fr] gap-3">
        <Campo etiqueta="Monto" inputMode="decimal" value={monto} onChange={(e) => setMonto(e.target.value)} error={errores.monto} />
        <Campo
          etiqueta="Motivo"
          placeholder={tipo === 'EGRESO' ? 'Pago de hielo, transporte…' : 'Cambio traído del banco…'}
          value={motivo}
          onChange={(e) => setMotivo(e.target.value)}
          error={errores.motivo}
        />
      </div>
      <div className="mt-3">
        <AvisoError error={registrar.error} />
      </div>
      <div className="mt-3 flex gap-2">
        <Boton onClick={enviar} disabled={registrar.isPending}>
          Guardar
        </Boton>
        <Boton variante="secundario" onClick={() => setTipo(null)}>
          Cancelar
        </Boton>
      </div>
    </Tarjeta>
  );
}

function CerrarCaja({ alCerrar }: { alCerrar: (r: { diferencia?: string; esperado?: string }) => void }) {
  const cerrar = useCerrarCaja();
  const [abierto, setAbierto] = useState(false);
  const [contado, setContado] = useState('');
  const [nota, setNota] = useState('');
  const [error, setError] = useState<string | null>(null);

  if (!abierto) {
    return (
      <Boton variante="secundario" onClick={() => setAbierto(true)}>
        Cerrar caja…
      </Boton>
    );
  }
  return (
    <Tarjeta className="mb-4">
      <h2 className="mb-1 font-semibold">Cerrar caja</h2>
      <p className="mb-3 text-sm text-gray-600">Cuenta todo el efectivo de la caja, incluido el fondo, y escríbelo.</p>
      <Campo etiqueta="Efectivo contado" inputMode="decimal" value={contado} onChange={(e) => setContado(e.target.value)} error={error} />
      <div className="mt-3">
        <Campo etiqueta="Nota (opcional)" value={nota} onChange={(e) => setNota(e.target.value)} />
      </div>
      <div className="mt-3">
        <AvisoError error={cerrar.error} />
      </div>
      <div className="mt-3 flex gap-2">
        <Boton
          variante="peligro"
          disabled={cerrar.isPending}
          onClick={() => {
            const leido = leerDecimal(contado, { decimales: 2 });
            if (!leido.ok) return setError(leido.mensaje);
            setError(null);
            cerrar.mutate(
              { contado: leido.valor, nota: nota.trim() || null },
              { onSuccess: (r) => alCerrar({ diferencia: r.diferencia, esperado: r.esperado }) },
            );
          }}
        >
          {cerrar.isPending ? 'Cerrando…' : 'Cerrar caja'}
        </Boton>
        <Boton variante="secundario" onClick={() => setAbierto(false)}>
          Cancelar
        </Boton>
      </div>
    </Tarjeta>
  );
}

/** Solo el Dueño: cajas cerradas con su diferencia y la explicación. */
function Historial() {
  const cerradas = useCajasCerradas();
  const [elegida, setElegida] = useState<string | null>(null);
  if (!cerradas.data?.length) return null;
  return (
    <Tarjeta className="mt-6">
      <h2 className="mb-2 font-semibold">Cajas cerradas</h2>
      <ul className="divide-y divide-gray-100">
        {cerradas.data.map((c) => (
          <li key={c.id} className="py-2">
            <button
              type="button"
              onClick={() => setElegida(elegida === c.id ? null : c.id)}
              className="flex w-full justify-between text-left text-sm"
            >
              <span>{formatearMomento(c.cerrada_en)}</span>
              <span className="tabular-nums">contado {formatearDinero(c.monto_contado)}</span>
            </button>
            {elegida === c.id && <DetalleCerrada cajaId={c.id} />}
          </li>
        ))}
      </ul>
    </Tarjeta>
  );
}

function DetalleCerrada({ cajaId }: { cajaId: string }) {
  const resumen = useResumenCaja(cajaId);
  const explicar = useExplicarDiferencia();
  const [texto, setTexto] = useState('');
  const c = resumen.data;
  if (!c) return <Cargando />;
  const diferencia = c.diferencia ?? '0.00';
  const cuadra = Number(diferencia) === 0;
  const falta = diferencia.startsWith('-');
  return (
    <div className="mt-2 rounded-lg bg-gray-50 p-3 text-sm">
      <p className="tabular-nums">
        Esperado {formatearDinero(c.esperado ?? '0')} · contado {formatearDinero(c.monto_contado ?? '0')} ·{' '}
        <strong className={cuadra ? '' : falta ? 'text-red-700' : 'text-amber-700'}>
          {cuadra ? 'cuadra' : `${falta ? 'falta' : 'sobra'} ${formatearDinero(diferencia.replace('-', ''))}`}
        </strong>
      </p>
      {c.explicacion ? (
        <p className="mt-1 text-gray-600">Explicación: {c.explicacion}</p>
      ) : (
        !cuadra && (
          <div className="mt-2 flex items-end gap-2">
            <div className="flex-1">
              <Campo etiqueta="Explicar la diferencia" value={texto} onChange={(e) => setTexto(e.target.value)} />
            </div>
            <Boton
              variante="secundario"
              disabled={explicar.isPending || texto.trim() === ''}
              onClick={() => explicar.mutate({ cajaId, explicacion: texto.trim() })}
            >
              Guardar
            </Boton>
          </div>
        )
      )}
      <AvisoError error={explicar.error} />
    </div>
  );
}
