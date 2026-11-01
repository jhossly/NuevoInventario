import { useState, type ChangeEvent, type FormEvent } from 'react';
import { leerDecimal, paraEditar } from '@/shared/decimal';
import { ConfigFacturacion } from '@/modules/facturacion/ConfigFacturacion';
import { Aviso, AvisoError, Boton, Campo, Cargando, Casilla, Encabezado, Tarjeta } from '@/shared/ui';
import { reducirLogo, useGuardarNegocio, useNegocio, type Negocio } from './api';

type Montos = 'descuento_max_vendedor' | 'monto_max_consumidor_final' | 'monto_max_sin_comprobante' | 'limite_ingresos_rimpe';

const ETIQUETAS: Record<Montos, { etiqueta: string; ayuda: string }> = {
  descuento_max_vendedor: { etiqueta: 'Descuento máximo del Vendedor (%)', ayuda: '0 = no puede dar descuentos' },
  monto_max_consumidor_final: { etiqueta: 'Consumidor final hasta ($)', ayuda: 'Sobre este total, la factura pide identificar al cliente' },
  monto_max_sin_comprobante: { etiqueta: 'Venta sin comprobante hasta ($)', ayuda: '0 = nunca' },
  limite_ingresos_rimpe: { etiqueta: 'Límite anual de ingresos RIMPE ($)', ayuda: 'Reportes avisa al llegar al 80 %' },
};
const MONTOS = Object.keys(ETIQUETAS) as Montos[];

/** Datos y ajustes de la bodega (D-047), solo para el Dueño. */
export function MiNegocio() {
  const negocio = useNegocio();
  return (
    <>
      <Encabezado titulo="Mi negocio" />
      {negocio.isPending && <Cargando />}
      <AvisoError error={negocio.error} />
      {negocio.data && <Formulario negocio={negocio.data} />}
      {negocio.data && <ConfigFacturacion />}
    </>
  );
}

function Formulario({ negocio }: { negocio: Negocio }) {
  const guardar = useGuardarNegocio();
  const [nombre, setNombre] = useState(negocio.nombre_comercial ?? '');
  const [razon, setRazon] = useState(negocio.razon_social);
  const [direccion, setDireccion] = useState(negocio.direccion ?? '');
  const [telefono, setTelefono] = useState(negocio.telefono ?? '');
  const [logo, setLogo] = useState(negocio.logo ?? '');
  const [errorLogo, setErrorLogo] = useState<string | null>(null);
  const [preciosConIva, setPreciosConIva] = useState(negocio.precios_incluyen_iva);
  const [ivaEsCosto, setIvaEsCosto] = useState(negocio.iva_compras_es_costo);
  const [vendedorVeCostos, setVendedorVeCostos] = useState(negocio.vendedor_ve_costos);
  const [montos, setMontos] = useState<Record<Montos, string>>(() => ({
    descuento_max_vendedor: paraEditar(negocio.descuento_max_vendedor),
    monto_max_consumidor_final: paraEditar(negocio.monto_max_consumidor_final),
    monto_max_sin_comprobante: paraEditar(negocio.monto_max_sin_comprobante),
    limite_ingresos_rimpe: paraEditar(negocio.limite_ingresos_rimpe),
  }));
  const [errores, setErrores] = useState<Partial<Record<Montos | 'razon', string>>>({});
  const [guardado, setGuardado] = useState(false);

  const elegirLogo = async (evento: ChangeEvent<HTMLInputElement>) => {
    const archivo = evento.target.files?.[0];
    evento.target.value = '';
    if (!archivo) return;
    setErrorLogo(null);
    try {
      setLogo(await reducirLogo(archivo));
    } catch (e) {
      setErrorLogo(e instanceof Error && e.message.includes('pesada') ? e.message : 'No se pudo leer la imagen');
    }
  };

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    setGuardado(false);
    const nuevos: typeof errores = {};
    if (razon.trim() === '') nuevos.razon = 'La razón social es obligatoria';
    const leidos = {} as Record<Montos, string>;
    for (const clave of MONTOS) {
      const leido = leerDecimal(montos[clave], { decimales: 2 });
      if (leido.ok) leidos[clave] = leido.valor;
      else nuevos[clave] = leido.mensaje;
    }
    setErrores(nuevos);
    if (Object.keys(nuevos).length > 0) return;

    guardar.mutate(
      {
        nombre_comercial: nombre,
        razon_social: razon,
        direccion,
        telefono,
        logo,
        precios_incluyen_iva: preciosConIva,
        iva_compras_es_costo: ivaEsCosto,
        vendedor_ve_costos: vendedorVeCostos,
        ...leidos,
      },
      { onSuccess: () => setGuardado(true) },
    );
  };

  return (
    <form onSubmit={enviar} className="flex flex-col gap-4" noValidate>
      <Tarjeta>
        <h2 className="mb-3 font-semibold">Datos de la bodega</h2>
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap items-center gap-4">
            {logo ? (
              <img src={logo} alt="Logo de la bodega" className="size-20 rounded-lg border border-gray-200 object-contain" />
            ) : (
              <div className="flex size-20 items-center justify-center rounded-lg border border-dashed border-gray-300 text-sm text-gray-500">
                Sin logo
              </div>
            )}
            <div className="flex flex-wrap gap-2">
              <label className="inline-flex min-h-11 cursor-pointer items-center rounded-lg bg-emerald-700 px-4 font-medium text-white hover:bg-emerald-800">
                {logo ? 'Cambiar logo' : 'Subir logo'}
                <input type="file" accept="image/png,image/jpeg,image/webp" className="sr-only" onChange={elegirLogo} />
              </label>
              {logo && (
                <Boton variante="secundario" onClick={() => setLogo('')}>
                  Quitar
                </Boton>
              )}
            </div>
          </div>
          {errorLogo && <Aviso>{errorLogo}</Aviso>}

          <Campo
            etiqueta="Nombre comercial"
            ayuda="El que se ve en la app. Si lo dejas vacío, se usa la razón social."
            value={nombre}
            onChange={(e) => setNombre(e.target.value)}
            autoComplete="off"
          />
          <Campo
            etiqueta="Razón social"
            value={razon}
            onChange={(e) => setRazon(e.target.value)}
            error={errores.razon}
            autoComplete="off"
          />
          <Campo
            etiqueta="RUC"
            ayuda="No se cambia aquí: con él se reconocen tus facturas del SRI."
            value={negocio.ruc}
            readOnly
            disabled
          />
          <Campo
            etiqueta="Dirección"
            value={direccion}
            maxLength={300}
            onChange={(e) => setDireccion(e.target.value)}
            autoComplete="off"
          />
          <Campo
            etiqueta="Teléfono"
            inputMode="tel"
            value={telefono}
            maxLength={20}
            onChange={(e) => setTelefono(e.target.value)}
            autoComplete="off"
          />
        </div>
      </Tarjeta>

      <Tarjeta>
        <h2 className="mb-1 font-semibold">Ajustes</h2>
        <p className="mb-3 text-sm text-gray-600">Valen para lo que registres desde ahora; lo ya registrado no cambia.</p>
        <div className="flex flex-col gap-3">
          <Casilla
            etiqueta="Los precios de venta incluyen IVA"
            checked={preciosConIva}
            onChange={(e) => setPreciosConIva(e.target.checked)}
          />
          <Casilla
            etiqueta="El IVA de las compras se suma al costo"
            checked={ivaEsCosto}
            onChange={(e) => setIvaEsCosto(e.target.checked)}
          />
          <Casilla
            etiqueta="Quien vende puede ver los costos"
            checked={vendedorVeCostos}
            onChange={(e) => setVendedorVeCostos(e.target.checked)}
          />
          <div className="grid gap-3 sm:grid-cols-2">
            {MONTOS.map((clave) => (
              <Campo
                key={clave}
                etiqueta={ETIQUETAS[clave].etiqueta}
                ayuda={ETIQUETAS[clave].ayuda}
                inputMode="decimal"
                value={montos[clave]}
                onChange={(e) => setMontos((m) => ({ ...m, [clave]: e.target.value }))}
                error={errores[clave]}
              />
            ))}
          </div>
        </div>
      </Tarjeta>

      <AvisoError error={guardar.error} />
      {guardado && <Aviso tipo="exito">Cambios guardados</Aviso>}
      <Boton type="submit" disabled={guardar.isPending}>
        {guardar.isPending ? 'Guardando…' : 'Guardar cambios'}
      </Boton>
    </form>
  );
}
