import { useState, type FormEvent } from 'react';
import { Check } from 'lucide-react';
import { Aviso, AvisoError, Boton, Campo, Cargando, Casilla, Selector, Tarjeta } from '@/shared/ui';
import { useConfiguracionFacturacion, useGuardarFacturacion, type Configuracion } from './api';

/** Configuración de la facturación electrónica, dentro de Mi negocio. */
export function ConfigFacturacion() {
  const config = useConfiguracionFacturacion();
  return (
    <Tarjeta className="mt-4">
      <h2 className="mb-1 font-semibold">Facturación electrónica</h2>
      <p className="mb-3 text-sm text-gray-600">Emite tus facturas desde esta app con tu firma electrónica.</p>
      {config.isPending && <Cargando />}
      <AvisoError error={config.error} />
      {config.data && <Formulario config={config.data} />}
    </Tarjeta>
  );
}

function Formulario({ config }: { config: Configuracion & { ultimo: number } }) {
  const guardar = useGuardarFacturacion();
  const [activa, setActiva] = useState(config.facturacion_activa);
  const [ambiente, setAmbiente] = useState(config.ambiente_sri);
  const [establecimiento, setEstablecimiento] = useState(config.establecimiento);
  const [punto, setPunto] = useState(config.punto_emision);
  const [ultimo, setUltimo] = useState(String(config.ultimo));
  const [obligado, setObligado] = useState(config.obligado_contabilidad);
  const [leyenda, setLeyenda] = useState(config.leyenda_rimpe ?? '');
  const [guardado, setGuardado] = useState(false);
  const [errorNumero, setErrorNumero] = useState<string | null>(null);

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    setGuardado(false);
    const numero = Number(ultimo);
    if (!Number.isInteger(numero) || numero < 0) {
      setErrorNumero('Escribe un número entero');
      return;
    }
    setErrorNumero(null);
    if (
      ambiente === '2' &&
      config.ambiente_sri !== '2' &&
      !window.confirm('En producción las facturas son documentos legales reales. ¿Pasar a producción?')
    ) {
      return;
    }
    guardar.mutate(
      {
        facturacion_activa: activa,
        ambiente_sri: ambiente,
        establecimiento,
        punto_emision: punto,
        obligado_contabilidad: obligado,
        leyenda_rimpe: leyenda,
        ultimo_secuencial: numero,
      },
      { onSuccess: () => setGuardado(true) },
    );
  };

  return (
    <form onSubmit={enviar} className="flex flex-col gap-3" noValidate>
      <Casilla etiqueta="Facturar desde esta app" checked={activa} onChange={(e) => setActiva(e.target.checked)} />
      <Selector etiqueta="Ambiente del SRI" value={ambiente} onChange={(e) => setAmbiente(e.target.value as '1' | '2')}>
        <option value="1">Pruebas (sin valor tributario)</option>
        <option value="2">Producción (facturas reales)</option>
      </Selector>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Campo
          etiqueta="Establecimiento"
          inputMode="numeric"
          maxLength={3}
          value={establecimiento}
          onChange={(e) => setEstablecimiento(e.target.value)}
        />
        <Campo
          etiqueta="Punto de emisión"
          ayuda="Usa uno distinto al del portal"
          inputMode="numeric"
          maxLength={3}
          value={punto}
          onChange={(e) => setPunto(e.target.value)}
        />
        <Campo
          etiqueta="Último número usado"
          ayuda="La próxima factura es el siguiente"
          inputMode="numeric"
          value={ultimo}
          onChange={(e) => setUltimo(e.target.value)}
          error={errorNumero}
        />
      </div>
      <Campo etiqueta="Leyenda del régimen" value={leyenda} maxLength={200} onChange={(e) => setLeyenda(e.target.value)} />
      <Casilla
        etiqueta="Obligado a llevar contabilidad"
        checked={obligado}
        onChange={(e) => setObligado(e.target.checked)}
      />
      <AvisoError error={guardar.error} />
      {guardado && <Aviso tipo="exito">Cambios guardados</Aviso>}
      <Boton type="submit" icono={Check} disabled={guardar.isPending}>
        {guardar.isPending ? 'Guardando…' : 'Guardar facturación'}
      </Boton>
    </form>
  );
}
