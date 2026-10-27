import { useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { UNIDADES, stockDe, useProductos, type Presentacion, type Producto } from '@/modules/catalogo/api';
import { useCuentasFiado, useResumenCaja } from '@/modules/caja/api';
import { leerDecimal, paraEditar, restarDinero } from '@/shared/decimal';
import { aTexto } from '@/shared/fechas';
import { formatearCantidad, formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { ErrorDeNegocio } from '@/shared/rpc';
import { useUnSoloEnvio } from '@/shared/unSoloEnvio';
import { nuevaClave } from '@/shared/uuid';
import { Aviso, AvisoError, Boton, Campo, Cargando, Selector, Tarjeta } from '@/shared/ui';
import { FormCliente } from './Clientes';
import {
  COMPROBANTES,
  MEDIOS,
  periodoVigente,
  useCalculoVenta,
  useClientes,
  usePeriodosIva,
  useRegistrarVenta,
  type LineaVenta,
  type Medio,
  type TipoComprobante,
} from './api';

interface LineaEnPantalla {
  producto: Producto;
  presentacion: Presentacion;
  cantidad: string;
  descuento: string;
}

interface Opcion {
  producto: Producto;
  presentacion: Presentacion;
}

function normalizar(texto: string): string {
  return texto.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
}

/**
 * Punto de venta (HU-02: cobrar en pocos toques). Buscar por 3 letras o
 * escanear el código, ajustar cantidades y cobrar. Los totales los calcula la
 * base; la pantalla solo los muestra. Una clave de idempotencia por venta:
 * tocar dos veces «Cobrar» registra una sola.
 */
export function PuntoVenta() {
  const productos = useProductos();
  const clientes = useClientes();
  const registrar = useRegistrarVenta();
  const caja = useResumenCaja();
  const cuentas = useCuentasFiado();
  const buscador = useRef<HTMLInputElement>(null);
  const unaVez = useUnSoloEnvio();

  const [busqueda, setBusqueda] = useState('');
  const [lineas, setLineas] = useState<LineaEnPantalla[]>([]);
  const [tipo, setTipo] = useState<TipoComprobante>('NOTA_VENTA');
  const [clienteId, setClienteId] = useState('');
  const [nuevoCliente, setNuevoCliente] = useState(false);
  const [medio, setMedio] = useState<Medio>('EFECTIVO');
  const [recibido, setRecibido] = useState('');
  const [clave, setClave] = useState(nuevaClave);
  const [ultima, setUltima] = useState<{ id: string; total: string; vuelto: string | null } | null>(null);

  const opciones = useMemo<Opcion[]>(() => {
    const texto = normalizar(busqueda.trim());
    if (texto.length < 2) return [];
    return (productos.data ?? [])
      .filter((p) => p.activo)
      .flatMap((p) =>
        p.presentaciones
          .filter((r) => r.activo && r.se_vende && r.precio_venta !== null)
          .filter(
            (r) =>
              normalizar(p.nombre).includes(texto) ||
              r.codigo_barras === busqueda.trim() ||
              // Los códigos del SRI son del producto: llevan a su presentación base.
              (Number(r.factor) === 1 &&
                [p.codigo_principal, p.codigo_auxiliar].some((c) => c !== null && normalizar(c) === texto)),
          )
          .map((r) => ({ producto: p, presentacion: r })),
      )
      .slice(0, 10);
  }, [productos.data, busqueda]);

  const agregar = ({ producto, presentacion }: Opcion) => {
    setUltima(null);
    setLineas((ls) => {
      const i = ls.findIndex((l) => l.presentacion.id === presentacion.id);
      if (i === -1) return [...ls, { producto, presentacion, cantidad: '1', descuento: '' }];
      return ls.map((l, j) => {
        if (j !== i) return l;
        const actual = leerDecimal(l.cantidad, { decimales: 3 });
        return { ...l, cantidad: actual.ok ? paraEditar(String(Number(actual.valor) + 1)) : l.cantidad };
      });
    });
    setBusqueda('');
    buscador.current?.focus();
  };

  // Enter: un código de barras exacto o un único resultado se agregan solos.
  const alTeclear = (evento: KeyboardEvent<HTMLInputElement>) => {
    if (evento.key !== 'Enter') return;
    evento.preventDefault();
    const porCodigo = opciones.find((o) => o.presentacion.codigo_barras === busqueda.trim());
    const elegida = porCodigo ?? (opciones.length === 1 ? opciones[0] : undefined);
    if (elegida) agregar(elegida);
  };

  const cambiar = (indice: number, cambios: Partial<LineaEnPantalla>) =>
    setLineas((ls) => ls.map((l, i) => (i === indice ? { ...l, ...cambios } : l)));

  // Líneas listas para la base, o null si alguna está mal escrita.
  const paraEnviar = useMemo<LineaVenta[] | null>(() => {
    if (lineas.length === 0) return null;
    const salida: LineaVenta[] = [];
    for (const l of lineas) {
      const cantidad = leerDecimal(l.cantidad, { decimales: 3, permitirCero: false });
      const descuento = l.descuento.trim() === '' ? ({ ok: true, valor: '0' } as const) : leerDecimal(l.descuento, { decimales: 2 });
      if (!cantidad.ok || !descuento.ok) return null;
      salida.push({ presentacion_id: l.presentacion.id, cantidad: cantidad.valor, descuento: descuento.valor });
    }
    return salida;
  }, [lineas]);

  const calculo = useCalculoVenta(paraEnviar);
  const total = paraEnviar ? calculo.data?.total : undefined;
  const lineaConError =
    calculo.error instanceof ErrorDeNegocio
      ? Number((calculo.error.detalle as { linea?: number } | null)?.linea ?? 0) - 1
      : -1;

  // Caja y fiado (Fase 9): la base vuelve a validarlo todo al cobrar.
  const cajaCerrada = caja.isSuccess && caja.data === null;
  const sinCajaParaEfectivo = medio === 'EFECTIVO' && cajaCerrada;
  const cuentaCliente = cuentas.data?.find((c) => c.cliente_id === clienteId);
  const fiadoSinCliente = medio === 'FIADO' && clienteId === '';

  const recibidoLeido = recibido.trim() === '' ? null : leerDecimal(recibido, { decimales: 2 });
  const vuelto = total && recibidoLeido?.ok ? restarDinero(recibidoLeido.valor, total) : null;
  const faltaDinero = vuelto !== null && vuelto.startsWith('-');

  const cobrar = () => {
    if (!paraEnviar || !total || calculo.isError || sinCajaParaEfectivo || fiadoSinCliente) return;
    unaVez((terminar) => registrar.mutate(
      {
        lineas: paraEnviar,
        // Un solo medio por toda la venta; la base también acepta pagos mixtos.
        pagos: Number(total) > 0 ? [{ medio, monto: total }] : [],
        clienteId: clienteId || null,
        tipoComprobante: tipo,
        clave,
      },
      {
        onSuccess: (r) => {
          setUltima({ id: r.venta_id, total: r.total, vuelto: medio === 'EFECTIVO' ? vuelto : null });
          setLineas([]);
          setRecibido('');
          setClienteId('');
          setTipo('NOTA_VENTA');
          setMedio('EFECTIVO');
          setClave(nuevaClave());
          buscador.current?.focus();
        },
        onSettled: terminar,
      },
    ));
  };

  if (productos.isPending) return <Cargando />;

  return (
    <div className="grid gap-4 md:grid-cols-[1fr_20rem]">
      <section>
        <h1 className="mb-3 text-xl font-semibold">Vender</h1>
        <AvisoIvaCero />
        <div className="relative mb-3">
          <input
            ref={buscador}
            type="search"
            inputMode="search"
            autoFocus
            placeholder="Producto o código de barras"
            aria-label="Buscar producto o escanear código"
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            onKeyDown={alTeclear}
            className="min-h-12 w-full rounded-lg border border-gray-300 bg-white px-3 text-base"
          />
          {opciones.length > 0 && (
            <ul className="absolute z-10 mt-1 w-full divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white shadow-lg">
              {opciones.map((o) => (
                <li key={o.presentacion.id}>
                  <button
                    type="button"
                    onClick={() => agregar(o)}
                    className="flex min-h-12 w-full items-center gap-3 px-3 text-left hover:bg-gray-50"
                  >
                    <span className="flex-1">
                      {o.producto.nombre}
                      {Number(o.presentacion.factor) !== 1 && ` — ${o.presentacion.nombre}`}
                      <span className="block text-sm text-gray-500">
                        Stock {formatearCantidad(stockDe(o.producto))} {UNIDADES[o.producto.unidad_base]}
                      </span>
                    </span>
                    <span className="font-semibold tabular-nums">{formatearDinero(o.presentacion.precio_venta ?? '0')}</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>

        {ultima && (
          <div className="mb-3">
            <Aviso tipo="exito">
              Venta registrada por {formatearDinero(ultima.total)}
              {ultima.vuelto && !ultima.vuelto.startsWith('-') && ` · vuelto ${formatearDinero(ultima.vuelto)}`}.{' '}
              <a href={enlace({ nombre: 'venta', id: ultima.id })} className="underline">
                Ver venta
              </a>
            </Aviso>
          </div>
        )}

        {lineas.length === 0 ? (
          <Tarjeta>
            <p className="text-gray-500">Escribe al menos 2 letras del producto o escanea su código.</p>
          </Tarjeta>
        ) : (
          <ol className="flex flex-col gap-2">
            {lineas.map((l, i) => {
              const calculada = paraEnviar ? calculo.data?.lineas[i] : undefined;
              const porPeso = l.producto.unidad_base === 'KG' && Number(l.presentacion.factor) === 1;
              return (
                <li
                  key={l.presentacion.id}
                  className={`rounded-xl border bg-white p-3 ${lineaConError === i ? 'border-red-400 bg-red-50' : 'border-gray-200'}`}
                >
                  <div className="flex items-start gap-2">
                    <p className="flex-1 font-medium">
                      {l.producto.nombre}
                      {Number(l.presentacion.factor) !== 1 && ` — ${l.presentacion.nombre}`}
                      <span className="block text-sm font-normal text-gray-500">
                        {formatearDinero(l.presentacion.precio_venta ?? '0')}
                        {porPeso ? ' / kg' : ' c/u'}
                      </span>
                    </p>
                    <p className="font-semibold tabular-nums">{calculada ? formatearDinero(calculada.total) : '—'}</p>
                  </div>
                  <div className="mt-2 flex items-end gap-2">
                    {!porPeso && (
                      <Boton
                        variante="secundario"
                        aria-label="Uno menos"
                        onClick={() => {
                          const n = Number(leerDecimal(l.cantidad, { decimales: 3 }).ok ? l.cantidad.replace(',', '.') : 1);
                          if (n <= 1) setLineas((ls) => ls.filter((_, j) => j !== i));
                          else cambiar(i, { cantidad: paraEditar(String(n - 1)) });
                        }}
                      >
                        −
                      </Boton>
                    )}
                    <div className="w-24">
                      <Campo
                        etiqueta={porPeso ? 'Kilos' : 'Cantidad'}
                        inputMode="decimal"
                        value={l.cantidad}
                        onChange={(e) => cambiar(i, { cantidad: e.target.value })}
                      />
                    </div>
                    {!porPeso && (
                      <Boton variante="secundario" aria-label="Uno más" onClick={() => agregar(l)}>
                        +
                      </Boton>
                    )}
                    <div className="w-24">
                      <Campo
                        etiqueta="Descuento $"
                        inputMode="decimal"
                        placeholder="0"
                        value={l.descuento}
                        onChange={(e) => cambiar(i, { descuento: e.target.value })}
                      />
                    </div>
                    <Boton
                      variante="secundario"
                      className="ml-auto"
                      aria-label={`Quitar ${l.producto.nombre}`}
                      onClick={() => setLineas((ls) => ls.filter((_, j) => j !== i))}
                    >
                      ✕
                    </Boton>
                  </div>
                </li>
              );
            })}
          </ol>
        )}
      </section>

      <aside className="flex flex-col gap-3 md:sticky md:top-16 md:self-start">
        <Tarjeta>
          <div className="flex flex-col gap-3">
            <Selector etiqueta="Comprobante" value={tipo} onChange={(e) => setTipo(e.target.value as TipoComprobante)}>
              {Object.entries(COMPROBANTES).map(([valor, texto]) => (
                <option key={valor} value={valor}>
                  {texto}
                </option>
              ))}
            </Selector>
            {nuevoCliente ? (
              <div className="rounded-lg bg-gray-50 p-3">
                <FormCliente
                  alTerminar={(id) => {
                    if (id) setClienteId(id);
                    setNuevoCliente(false);
                  }}
                />
              </div>
            ) : (
              <div className="flex items-end gap-2">
                <div className="min-w-0 flex-1">
                  <Selector etiqueta="Cliente" value={clienteId} onChange={(e) => setClienteId(e.target.value)}>
                    <option value="">Consumidor final</option>
                    {clientes.data
                      ?.filter((c) => c.activo)
                      .map((c) => (
                        <option key={c.id} value={c.id}>
                          {c.nombre}
                          {c.identificacion ? ` · ${c.identificacion}` : ''}
                        </option>
                      ))}
                  </Selector>
                </div>
                <Boton variante="secundario" onClick={() => setNuevoCliente(true)}>
                  Nuevo
                </Boton>
              </div>
            )}
          </div>
        </Tarjeta>

        <Tarjeta>
          {calculo.data && paraEnviar && (
            <dl className="mb-3 grid grid-cols-2 gap-x-4 text-sm tabular-nums">
              <dt className="text-gray-600">Subtotal</dt>
              <dd className="text-right">{formatearDinero(calculo.data.subtotal)}</dd>
              {Number(calculo.data.descuento) > 0 && (
                <>
                  <dt className="text-gray-600">Descuento</dt>
                  <dd className="text-right">−{formatearDinero(calculo.data.descuento)}</dd>
                </>
              )}
              <dt className="text-gray-600">IVA</dt>
              <dd className="text-right">{formatearDinero(calculo.data.iva)}</dd>
            </dl>
          )}
          <p className="flex items-baseline justify-between">
            <span className="text-gray-600">Total</span>
            <span className="text-3xl font-semibold tabular-nums">{total ? formatearDinero(total) : '$0,00'}</span>
          </p>

          <div className="mt-3 flex flex-col gap-3">
            <div className="grid grid-cols-2 gap-1" role="radiogroup" aria-label="Medio de pago">
              {(Object.keys(MEDIOS) as Medio[]).map((m) => (
                <button
                  key={m}
                  type="button"
                  role="radio"
                  aria-checked={medio === m}
                  onClick={() => setMedio(m)}
                  className={`min-h-11 rounded-lg border text-sm ${
                    medio === m ? 'border-gray-900 bg-gray-900 text-white' : 'border-gray-300 bg-white'
                  }`}
                >
                  {MEDIOS[m]}
                </button>
              ))}
            </div>
            {sinCajaParaEfectivo && (
              <Aviso>
                La caja está cerrada. <a href={enlace({ nombre: 'caja' })} className="underline">Abrir caja</a> para cobrar en
                efectivo.
              </Aviso>
            )}
            {medio === 'FIADO' &&
              (fiadoSinCliente ? (
                <Aviso>Elige el cliente que se lleva al fiado.</Aviso>
              ) : (
                <p className="text-sm text-gray-600">
                  {cuentaCliente?.fiado_permitido
                    ? `Debe ${formatearDinero(cuentaCliente.saldo)} · disponible ${formatearDinero(cuentaCliente.disponible)}`
                    : 'Este cliente no tiene fiado autorizado.'}
                </p>
              ))}
            {medio === 'EFECTIVO' && !cajaCerrada && (
              <Campo
                etiqueta="Recibido"
                inputMode="decimal"
                placeholder="Opcional"
                value={recibido}
                onChange={(e) => setRecibido(e.target.value)}
                error={recibidoLeido && !recibidoLeido.ok ? recibidoLeido.mensaje : faltaDinero ? 'No alcanza para el total' : null}
              />
            )}
            {vuelto && !faltaDinero && (
              <p className="flex items-baseline justify-between">
                <span className="text-gray-600">Vuelto</span>
                <span className="text-2xl font-semibold tabular-nums">{formatearDinero(vuelto)}</span>
              </p>
            )}
            {paraEnviar && <AvisoError error={calculo.error} />}
            {lineas.length > 0 && !paraEnviar && <Aviso>Revisa las cantidades y descuentos.</Aviso>}
            <AvisoError error={registrar.error} />
            <Boton
              className="min-h-14 text-lg"
              onClick={cobrar}
              disabled={
                !total ||
                calculo.isFetching ||
                calculo.isError ||
                registrar.isPending ||
                faltaDinero ||
                sinCajaParaEfectivo ||
                fiadoSinCliente
              }
            >
              {registrar.isPending ? 'Cobrando…' : total ? `Cobrar ${formatearDinero(total)}` : 'Cobrar'}
            </Boton>
          </div>
        </Tarjeta>
      </aside>
    </div>
  );
}

/** Mientras rige «IVA 0 %» (D-045), quien vende lo ve antes de cobrar. */
function AvisoIvaCero() {
  const periodos = usePeriodosIva();
  const vigente = periodoVigente(periodos.data ?? [], aTexto(new Date()));
  if (!vigente?.iva_cero) return null;
  return (
    <div className="mb-3">
      <Aviso tipo="info">Las ventas van con IVA 0 %{vigente.nota ? ` (${vigente.nota})` : ''}.</Aviso>
    </div>
  );
}
