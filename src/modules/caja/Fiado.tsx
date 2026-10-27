import { useState } from 'react';
import { useContexto } from '@/modules/sesion/sesion';
import { formatearMomento } from '@/modules/ventas/api';
import { leerDecimal, sumarDinero } from '@/shared/decimal';
import { formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Cargando, Encabezado, Tarjeta } from '@/shared/ui';
import { useAjustarFiado, useCuentasFiado, useMovimientosFiado, useRegistrarAbono, type Cuenta } from './api';

const TIPOS = { CARGO: 'Venta al fiado', ABONO: 'Abono', AJUSTE: 'Ajuste' } as const;
const MEDIOS_ABONO = { EFECTIVO: 'Efectivo', TRANSFERENCIA: 'Transferencia', TARJETA: 'Tarjeta' } as const;

/** Cuentas de fiado: quién debe, cuánto le queda, abonos y ajustes. */
export function Fiado() {
  const cuentas = useCuentasFiado();
  const [elegido, setElegido] = useState<string | null>(null);
  const deben = (cuentas.data ?? []).filter((c) => Number(c.saldo) !== 0);
  const total = sumarDinero(deben.map((c) => c.saldo));

  return (
    <>
      <Encabezado titulo="Fiado" />
      {cuentas.isPending && <Cargando />}
      <AvisoError error={cuentas.error} />
      {cuentas.isSuccess && (
        <p className="mb-3 text-sm text-gray-600">
          Por cobrar: <strong className="text-gray-900">{formatearDinero(total)}</strong> de{' '}
          {deben.length === 1 ? '1 cliente' : `${deben.length} clientes`}.
          Para autorizar fiado a un cliente, edítalo en <a className="underline" href={enlace({ nombre: 'clientes' })}>Clientes</a>.
        </p>
      )}
      {cuentas.isSuccess && cuentas.data.length === 0 && <Tarjeta>Ningún cliente tiene fiado autorizado ni deuda.</Tarjeta>}
      <ul className="flex flex-col gap-2">
        {cuentas.data?.map((c) => (
          <li key={c.cliente_id} className="rounded-xl border border-gray-200 bg-white">
            <button
              type="button"
              onClick={() => setElegido(elegido === c.cliente_id ? null : c.cliente_id)}
              className="flex w-full items-center gap-3 p-3 text-left"
              aria-expanded={elegido === c.cliente_id}
            >
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">{c.nombre}</p>
                <p className="text-sm text-gray-500">
                  {c.fiado_permitido ? `Límite ${formatearDinero(c.limite)} · disponible ${formatearDinero(c.disponible)}` : 'Sin fiado autorizado'}
                </p>
              </div>
              <p className={`font-semibold tabular-nums ${Number(c.saldo) > 0 ? 'text-red-800' : ''}`}>
                {formatearDinero(c.saldo)}
              </p>
            </button>
            {elegido === c.cliente_id && <Cuenta cuenta={c} />}
          </li>
        ))}
      </ul>
    </>
  );
}

function Cuenta({ cuenta }: { cuenta: Cuenta }) {
  const esDueno = useContexto().rol === 'DUENO';
  const movimientos = useMovimientosFiado(cuenta.cliente_id);
  return (
    <div className="border-t border-gray-100 p-3">
      {Number(cuenta.saldo) > 0 && <Abonar cuenta={cuenta} />}
      {esDueno && <Ajustar clienteId={cuenta.cliente_id} />}
      {movimientos.isPending && <Cargando />}
      <ul className="mt-3 divide-y divide-gray-100 text-sm">
        {movimientos.data?.map((m) => (
          <li key={m.id} className="flex justify-between gap-2 py-1">
            <span>
              {formatearMomento(m.creado_en)} · {TIPOS[m.tipo]}
              {m.medio && ` (${MEDIOS_ABONO[m.medio as keyof typeof MEDIOS_ABONO] ?? m.medio})`}
              {m.motivo && <span className="text-gray-500"> · {m.motivo}</span>}
              {m.venta_id && (
                <>
                  {' '}
                  <a className="underline" href={enlace({ nombre: 'venta', id: m.venta_id })}>
                    ver venta
                  </a>
                </>
              )}
            </span>
            <span className={`tabular-nums ${m.monto.startsWith('-') ? 'text-green-800' : 'text-red-800'}`}>
              {m.monto.startsWith('-') ? '−' : '+'}
              {formatearDinero(m.monto.replace('-', ''))}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function Abonar({ cuenta }: { cuenta: Cuenta }) {
  const abonar = useRegistrarAbono();
  const unaVez = useUnSoloEnvio();
  const [monto, setMonto] = useState('');
  const [medio, setMedio] = useState<keyof typeof MEDIOS_ABONO>('EFECTIVO');
  const [error, setError] = useState<string | null>(null);
  const [hecho, setHecho] = useState<string | null>(null);
  const [clave, setClave] = useState(nuevaClave);

  return (
    <div className="rounded-lg bg-gray-50 p-3">
      <div className="flex flex-wrap items-end gap-2">
        <div className="w-32">
          <Campo etiqueta="Abono" inputMode="decimal" value={monto} onChange={(e) => setMonto(e.target.value)} error={error} />
        </div>
        <div className="flex gap-1" role="radiogroup" aria-label="Medio del abono">
          {(Object.keys(MEDIOS_ABONO) as (keyof typeof MEDIOS_ABONO)[]).map((m) => (
            <button
              key={m}
              type="button"
              role="radio"
              aria-checked={medio === m}
              onClick={() => setMedio(m)}
              className={`min-h-11 rounded-lg border px-3 text-sm ${medio === m ? 'border-gray-900 bg-gray-900 text-white' : 'border-gray-300 bg-white'}`}
            >
              {MEDIOS_ABONO[m]}
            </button>
          ))}
        </div>
        <Boton variante="secundario" onClick={() => setMonto(cuenta.saldo)}>
          Todo
        </Boton>
        <Boton
          disabled={abonar.isPending}
          onClick={() => {
            const leido = leerDecimal(monto, { decimales: 2, permitirCero: false });
            if (!leido.ok) return setError(leido.mensaje);
            setError(null);
            unaVez((terminar) =>
              abonar.mutate(
                { clienteId: cuenta.cliente_id, monto: leido.valor, medio, clave },
                {
                  onSuccess: (r) => {
                    setHecho(`Abono registrado. Ahora debe ${formatearDinero(r.saldo)}.`);
                    setMonto('');
                    setClave(nuevaClave());
                  },
                  onSettled: terminar,
                },
              ),
            );
          }}
        >
          Registrar abono
        </Boton>
      </div>
      <div className="mt-2">
        <AvisoError error={abonar.error} />
        {hecho && <Aviso tipo="exito">{hecho}</Aviso>}
      </div>
    </div>
  );
}

function Ajustar({ clienteId }: { clienteId: string }) {
  const ajustar = useAjustarFiado();
  const [abierto, setAbierto] = useState(false);
  const [monto, setMonto] = useState('');
  const [motivo, setMotivo] = useState('');
  const [errores, setErrores] = useState<{ monto?: string; motivo?: string }>({});

  if (!abierto) {
    return (
      <Boton variante="secundario" className="mt-2" onClick={() => setAbierto(true)}>
        Ajustar cuenta…
      </Boton>
    );
  }
  return (
    <div className="mt-2 rounded-lg bg-gray-50 p-3">
      <div className="grid grid-cols-[8rem_1fr] gap-2">
        <Campo
          etiqueta="Monto (+ / −)"
          ayuda="− reduce la deuda"
          inputMode="decimal"
          value={monto}
          onChange={(e) => setMonto(e.target.value)}
          error={errores.monto}
        />
        <Campo etiqueta="Motivo" value={motivo} onChange={(e) => setMotivo(e.target.value)} error={errores.motivo} />
      </div>
      <AvisoError error={ajustar.error} />
      <div className="mt-2 flex gap-2">
        <Boton
          disabled={ajustar.isPending}
          onClick={() => {
            const leido = leerDecimal(monto, { decimales: 2, permitirNegativo: true, permitirCero: false });
            const nuevos = {
              monto: leido.ok ? undefined : leido.mensaje,
              motivo: motivo.trim() === '' ? 'Escribe el motivo' : undefined,
            };
            setErrores(nuevos);
            if (!leido.ok || nuevos.motivo) return;
            ajustar.mutate({ clienteId, monto: leido.valor, motivo: motivo.trim() }, { onSuccess: () => setAbierto(false) });
          }}
        >
          Guardar ajuste
        </Boton>
        <Boton variante="secundario" onClick={() => setAbierto(false)}>
          Cancelar
        </Boton>
      </div>
    </div>
  );
}
