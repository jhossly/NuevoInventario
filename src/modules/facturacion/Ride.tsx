import { useMemo } from 'react';
import { Printer } from 'lucide-react';
import { useContexto } from '@/modules/sesion/sesion';
import { enlace } from '@/shared/ruta';
import { Aviso, AvisoError, Boton, Cargando, Encabezado } from '@/shared/ui';
import { useFacturaDeVenta } from './api';

const FORMAS_PAGO: Record<string, string> = {
  '01': 'Sin utilización del sistema financiero',
  '16': 'Tarjeta de débito',
  '19': 'Tarjeta de crédito',
  '20': 'Otros con utilización del sistema financiero',
};

const IVA: Record<string, string> = { '0': '0 %', '2': '12 %', '3': '14 %', '4': '15 %', '5': '5 %', '6': 'No objeto', '7': 'Exento', '10': '13 %' };

function leer(xml: string) {
  const doc = new DOMParser().parseFromString(xml, 'text/xml');
  const t = (padre: Element | Document, nombre: string) => padre.getElementsByTagName(nombre)[0]?.textContent ?? '';
  return {
    t: (nombre: string) => t(doc, nombre),
    detalles: [...doc.getElementsByTagName('detalle')].map((d) => ({
      codigo: t(d, 'codigoPrincipal'),
      descripcion: t(d, 'descripcion'),
      cantidad: Number(t(d, 'cantidad')),
      precio: t(d, 'precioUnitario'),
      descuento: t(d, 'descuento'),
      total: t(d, 'precioTotalSinImpuesto'),
    })),
    impuestos: [...doc.getElementsByTagName('totalImpuesto')].map((i) => ({
      codigo: t(i, 'codigoPorcentaje'),
      base: t(i, 'baseImponible'),
      valor: t(i, 'valor'),
    })),
    pagos: [...doc.getElementsByTagName('pago')].map((p) => ({ forma: t(p, 'formaPago'), total: t(p, 'total') })),
  };
}

/**
 * Representación impresa de la factura (RIDE), leída del XML autorizado para
 * que muestre exactamente lo que recibió el SRI. Se guarda como PDF desde
 * «Imprimir». Le falta el código de barras de la clave de acceso.
 */
export function Ride({ ventaId }: { ventaId: string }) {
  const contexto = useContexto();
  const factura = useFacturaDeVenta(ventaId);
  const f = factura.data;
  const x = useMemo(() => (f ? leer(f.xml_firmado ?? f.xml) : null), [f]);

  if (factura.isPending) return <Cargando />;
  if (!f || !x || f.estado !== 'AUTORIZADA') {
    return (
      <>
        <Encabezado titulo="Factura" volver={enlace({ nombre: 'venta', id: ventaId })} />
        <AvisoError error={factura.error} />
        <Aviso tipo="info">Esta venta todavía no tiene una factura autorizada.</Aviso>
      </>
    );
  }

  return (
    <>
      <div className="print:hidden">
        <Encabezado
          titulo={`Factura ${f.numero}`}
          volver={enlace({ nombre: 'venta', id: ventaId })}
          acciones={
            <Boton icono={Printer} onClick={() => window.print()}>
              Imprimir o guardar PDF
            </Boton>
          }
        />
      </div>
      <article className="rounded-xl border border-gray-200 bg-white p-6 text-sm print:border-0 print:p-0">
        {f.ambiente === '1' && (
          <p className="mb-4 rounded border border-amber-400 p-2 text-center font-bold">
            AMBIENTE DE PRUEBAS: SIN VALOR TRIBUTARIO
          </p>
        )}
        <div className="grid gap-4 sm:grid-cols-2 print:grid-cols-2">
          <div>
            {contexto.logo && <img src={contexto.logo} alt="" className="mb-2 h-16 object-contain" />}
            <p className="text-base font-bold">{x.t('razonSocial')}</p>
            {x.t('nombreComercial') && <p>{x.t('nombreComercial')}</p>}
            <p>Dirección: {x.t('dirMatriz')}</p>
            <p>Obligado a llevar contabilidad: {x.t('obligadoContabilidad')}</p>
            {x.t('contribuyenteRimpe') && <p>{x.t('contribuyenteRimpe')}</p>}
          </div>
          <div className="rounded border border-gray-300 p-3">
            <p>R.U.C.: {x.t('ruc')}</p>
            <p className="text-base font-bold">FACTURA</p>
            <p>No. {f.numero}</p>
            <p className="mt-1">Número de autorización:</p>
            <p className="break-all font-mono text-xs">{f.numero_autorizacion}</p>
            {f.fecha_autorizacion && <p>Autorización: {new Date(f.fecha_autorizacion).toLocaleString('es-EC')}</p>}
            <p>Ambiente: {f.ambiente === '1' ? 'PRUEBAS' : 'PRODUCCIÓN'}</p>
            <p>Emisión: NORMAL</p>
            <p className="mt-1">Clave de acceso:</p>
            <p className="break-all font-mono text-xs">{f.clave_acceso}</p>
          </div>
        </div>

        <div className="my-4 rounded border border-gray-300 p-3">
          <p>Cliente: {x.t('razonSocialComprador')}</p>
          <p>Identificación: {x.t('identificacionComprador')}</p>
          <p>Fecha de emisión: {x.t('fechaEmision')}</p>
          {x.t('direccionComprador') && <p>Dirección: {x.t('direccionComprador')}</p>}
        </div>

        <div className="overflow-x-auto">
          <table className="w-full border-collapse">
            <thead>
              <tr className="border-b border-gray-400 text-left">
                <th className="py-1 pr-2">Código</th>
                <th className="pr-2">Descripción</th>
                <th className="pr-2 text-right">Cant.</th>
                <th className="pr-2 text-right">P. unit.</th>
                <th className="pr-2 text-right">Desc.</th>
                <th className="text-right">Total</th>
              </tr>
            </thead>
            <tbody>
              {x.detalles.map((d, i) => (
                <tr key={i} className="border-b border-gray-100">
                  <td className="py-1 pr-2">{d.codigo}</td>
                  <td className="pr-2">{d.descripcion}</td>
                  <td className="pr-2 text-right tabular-nums">{d.cantidad}</td>
                  <td className="pr-2 text-right tabular-nums">{Number(d.precio).toFixed(4)}</td>
                  <td className="pr-2 text-right tabular-nums">{d.descuento}</td>
                  <td className="text-right tabular-nums">{d.total}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-4 grid gap-4 sm:grid-cols-2 print:grid-cols-2">
          <div>
            <p className="font-semibold">Forma de pago</p>
            {x.pagos.map((p, i) => (
              <p key={i}>
                {FORMAS_PAGO[p.forma] ?? p.forma}: ${p.total}
              </p>
            ))}
          </div>
          <dl className="grid grid-cols-[1fr_auto] gap-x-4 tabular-nums">
            {x.impuestos.map((i) => (
              <div key={i.codigo} className="col-span-2 grid grid-cols-subgrid">
                <dt>Subtotal {IVA[i.codigo] ?? i.codigo}</dt>
                <dd className="text-right">{i.base}</dd>
              </div>
            ))}
            <dt>Descuento</dt>
            <dd className="text-right">{x.t('totalDescuento')}</dd>
            {x.impuestos
              .filter((i) => Number(i.valor) > 0)
              .map((i) => (
                <div key={i.codigo} className="col-span-2 grid grid-cols-subgrid">
                  <dt>IVA {IVA[i.codigo] ?? i.codigo}</dt>
                  <dd className="text-right">{i.valor}</dd>
                </div>
              ))}
            <dt className="font-bold">TOTAL</dt>
            <dd className="text-right font-bold">{x.t('importeTotal')}</dd>
          </dl>
        </div>
      </article>
    </>
  );
}
