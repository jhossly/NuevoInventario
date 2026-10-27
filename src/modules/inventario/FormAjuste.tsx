import { useState, type FormEvent } from 'react';
import { UNIDADES, stockDe, useProducto, type Producto } from '@/modules/catalogo/api';
import { leerDecimal, negar } from '@/shared/decimal';
import { formatearCantidad } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Cargando, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import { useAjustar, type TipoAjuste } from './api';

export function PantallaAjuste({ id }: { id: string }) {
  const producto = useProducto(id);
  if (producto.isPending) return <Cargando />;
  if (producto.error) return <AvisoError error={producto.error} />;
  if (!producto.data) return <Tarjeta>El producto no existe o no es de tu empresa.</Tarjeta>;
  return <FormAjuste producto={producto.data} />;
}

type Sentido = 'entrada' | 'salida';

const AYUDA: Record<TipoAjuste, string> = {
  APERTURA: 'Stock inicial del producto, con lo que costó cada unidad. Solo se hace una vez.',
  AJUSTE: 'Corrige el stock por una razón concreta. Para un conteo completo usa «Conteo».',
  MERMA: 'Producto dañado, vencido o perdido. Sale al costo promedio.',
};

function FormAjuste({ producto }: { producto: Producto }) {
  const ajustar = useAjustar();
  const unaVez = useUnSoloEnvio();
  const unidad = UNIDADES[producto.unidad_base];
  const sinStock = Number(stockDe(producto)) === 0;

  const [tipo, setTipo] = useState<TipoAjuste>(sinStock ? 'APERTURA' : 'AJUSTE');
  const [sentido, setSentido] = useState<Sentido>('entrada');
  const [cantidad, setCantidad] = useState('');
  const [costo, setCosto] = useState('');
  const [motivo, setMotivo] = useState('');
  const [errores, setErrores] = useState<{ cantidad?: string; costo?: string; motivo?: string }>({});
  const [resultado, setResultado] = useState<string | null>(null);
  // Una clave por intento: si la red falla y se vuelve a enviar, la base
  // devuelve el mismo movimiento en vez de duplicarlo. Cambia al terminar bien.
  const [clave, setClave] = useState(nuevaClave);

  const pideCosto = tipo === 'APERTURA' || (tipo === 'AJUSTE' && sentido === 'entrada');
  const esSalida = tipo === 'MERMA' || (tipo === 'AJUSTE' && sentido === 'salida');

  const cambiar = (accion: () => void) => {
    accion();
    setResultado(null);
    // Cambió lo que se quiere registrar: es otra operación, otra clave.
    setClave(nuevaClave());
  };

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    const nuevos: typeof errores = {};
    const cantidadLeida = leerDecimal(cantidad, { decimales: 3, permitirCero: false });
    if (!cantidadLeida.ok) nuevos.cantidad = cantidadLeida.mensaje;
    const costoLeido = pideCosto && costo.trim() !== '' ? leerDecimal(costo, { decimales: 6 }) : null;
    if (costoLeido && !costoLeido.ok) nuevos.costo = costoLeido.mensaje;
    if (tipo === 'APERTURA' && !costoLeido) nuevos.costo = 'La apertura necesita el costo';
    if (tipo !== 'APERTURA' && motivo.trim() === '') nuevos.motivo = 'Escribe el motivo';
    setErrores(nuevos);
    if (Object.keys(nuevos).length > 0 || !cantidadLeida.ok) return;

    unaVez((terminar) => ajustar.mutate(
      {
        productoId: producto.id,
        tipo,
        cantidad: esSalida ? negar(cantidadLeida.valor) : cantidadLeida.valor,
        costoUnitario: costoLeido?.ok ? costoLeido.valor : null,
        motivo: motivo.trim() || null,
        clave,
      },
      {
        onSuccess: (r) => {
          setResultado(`Listo. Stock ahora: ${formatearCantidad(r.saldo_cantidad)} ${unidad}.`);
          setCantidad('');
          setCosto('');
          setMotivo('');
          setClave(nuevaClave());
          if (tipo === 'APERTURA') setTipo('AJUSTE');
        },
        onSettled: terminar,
      },
    ));
  };

  return (
    <>
      <Encabezado titulo={`Ajustar: ${producto.nombre}`} volver={enlace({ nombre: 'producto', id: producto.id })} />
      <Tarjeta>
        <p className="mb-4 text-gray-600">
          Stock actual: <strong className="text-gray-900">{formatearCantidad(stockDe(producto))} {unidad}</strong>
        </p>
        <form onSubmit={enviar} className="flex flex-col gap-4" noValidate>
          <Selector etiqueta="Tipo" value={tipo} onChange={(e) => cambiar(() => setTipo(e.target.value as TipoAjuste))}>
            {sinStock && <option value="APERTURA">Apertura (stock inicial)</option>}
            <option value="AJUSTE">Ajuste</option>
            <option value="MERMA">Merma</option>
          </Selector>
          <p className="-mt-2 text-sm text-gray-500">{AYUDA[tipo]}</p>

          {tipo === 'AJUSTE' && (
            <fieldset className="flex gap-2">
              <legend className="mb-1 text-sm font-medium text-gray-700">Sentido</legend>
              {(['entrada', 'salida'] as const).map((s) => (
                <Boton
                  key={s}
                  variante={sentido === s ? 'primario' : 'secundario'}
                  aria-pressed={sentido === s}
                  onClick={() => cambiar(() => setSentido(s))}
                >
                  {s === 'entrada' ? 'Entra (+)' : 'Sale (−)'}
                </Boton>
              ))}
            </fieldset>
          )}

          <Campo
            etiqueta={`Cantidad (${unidad})`}
            inputMode="decimal"
            value={cantidad}
            onChange={(e) => cambiar(() => setCantidad(e.target.value))}
            error={errores.cantidad}
          />

          {pideCosto && (
            <Campo
              etiqueta="Costo por unidad"
              ayuda={
                tipo === 'APERTURA'
                  ? 'Lo que costó cada unidad, con IVA si el IVA de compras es costo'
                  : 'Opcional. Vacío = entra al costo promedio actual'
              }
              inputMode="decimal"
              value={costo}
              onChange={(e) => cambiar(() => setCosto(e.target.value))}
              error={errores.costo}
            />
          )}

          {tipo !== 'APERTURA' && (
            <Campo
              etiqueta="Motivo"
              placeholder={tipo === 'MERMA' ? 'Botella rota, vencido…' : 'Error al registrar una compra…'}
              value={motivo}
              onChange={(e) => cambiar(() => setMotivo(e.target.value))}
              error={errores.motivo}
            />
          )}

          <AvisoError error={ajustar.error} />
          {resultado && <Aviso tipo="exito">{resultado}</Aviso>}

          <Boton type="submit" disabled={ajustar.isPending}>
            {ajustar.isPending ? 'Guardando…' : 'Registrar'}
          </Boton>
        </form>
      </Tarjeta>
    </>
  );
}
