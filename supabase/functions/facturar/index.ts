import { createClient } from 'npm:@supabase/supabase-js@2';
import forge from 'node-forge';
import { abrirP12, firmarComprobante, verificarFirma } from './firma.ts';
import {
  armarAutorizacion,
  armarRecepcion,
  consultarAutorizacion,
  enviarRecepcion,
  leerAutorizacion,
  leerRecepcion,
  yaEstabaRecibida,
  type MensajeSri,
} from './sri.ts';

/**
 * Emite la factura de una venta (D-053): la base la prepara con los permisos de
 * quien llama; aquí se firma y se envía al SRI. La firma .p12 vive solo en los
 * secretos de esta función: nunca llega al navegador ni a la base.
 *
 * La venta ya está guardada: si el SRI no responde, la factura queda pendiente
 * y se reintenta con la misma clave de acceso.
 */

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const responder = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...CORS, 'Content-Type': 'application/json' } });

const fallo = (codigo: string, mensaje: string, estado = 200) =>
  responder({ ok: false, error: { codigo, mensaje } }, estado);

const base64 = (texto: string) => forge.util.encode64(forge.util.encodeUtf8(texto));

const PAUSA_MS = 2500;
const CONSULTAS = 4;

Deno.serve(async (peticion) => {
  if (peticion.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (peticion.method !== 'POST') return fallo('DATOS_INVALIDOS', 'Método no permitido', 405);

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const anonima = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const servicio = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const autorizacion = peticion.headers.get('Authorization');
  if (!autorizacion) return fallo('SIN_PERMISO', 'Inicia sesión', 401);

  let ventaId: string | undefined;
  try {
    ventaId = (await peticion.json())?.venta_id;
  } catch {
    // Cae en la validación siguiente.
  }
  if (!ventaId) return fallo('DATOS_INVALIDOS', 'Falta la venta');

  // Con el usuario: la base decide si puede facturar esta venta.
  const usuario = createClient(url, anonima, { global: { headers: { Authorization: autorizacion } } });
  const preparada = await usuario.rpc('preparar_factura', { p_venta_id: ventaId });
  if (preparada.error) return fallo('ERROR', 'No se pudo preparar la factura');
  if (!preparada.data?.ok) return responder(preparada.data);
  const factura = preparada.data.data as {
    id: string;
    clave_acceso: string;
    ambiente: string;
    estado: string;
    xml: string;
    xml_firmado: string | null;
  };
  if (factura.estado === 'AUTORIZADA') return responder({ ok: true, data: { estado: 'AUTORIZADA' } });

  const p12 = Deno.env.get('FIRMA_P12_BASE64');
  const contrasena = Deno.env.get('FIRMA_CONTRASENA');
  if (!p12 || !contrasena) {
    return fallo('SIN_FIRMA', 'Falta configurar la firma electrónica en el servidor');
  }

  const otroServidor = Deno.env.get('SRI_SERVIDOR_PRUEBAS');
  const admin = createClient(url, servicio);
  const guardar = async (datos: Record<string, unknown>) => {
    const r = await admin.rpc('registrar_resultado_factura', { p_id: factura.id, p_datos: datos });
    if (r.error || !r.data?.ok) throw new Error('No se pudo guardar el resultado de la factura');
  };

  try {
    // Reutiliza la firma si el SRI ya pudo haberla recibido: la clave es la misma.
    let firmado = factura.xml_firmado;
    if (!firmado) {
      firmado = firmarComprobante(factura.xml, abrirP12(p12, contrasena));
      const revision = verificarFirma(firmado);
      if (!revision.comprobante || !revision.propiedades || !revision.firma) {
        return fallo('FIRMA_INVALIDA', 'La firma no pasó la revisión: no se envió al SRI');
      }
      await guardar({ estado: 'PENDIENTE', xml_firmado: firmado });
    }

    let mensajes: MensajeSri[] = [];
    if (factura.estado !== 'RECIBIDA') {
      const recepcion = leerRecepcion(await enviarRecepcion(factura.ambiente, armarRecepcion(firmado, base64), otroServidor));
      mensajes = recepcion.mensajes;
      if (recepcion.estado === 'DEVUELTA' && !yaEstabaRecibida(recepcion)) {
        await guardar({ estado: 'DEVUELTA', mensajes });
        return responder({ ok: true, data: { estado: 'DEVUELTA', mensajes } });
      }
      await guardar({ estado: 'RECIBIDA', mensajes });
    }

    for (let intento = 0; intento < CONSULTAS; intento++) {
      if (intento > 0) await new Promise((listo) => setTimeout(listo, PAUSA_MS));
      const r = leerAutorizacion(await consultarAutorizacion(factura.ambiente, armarAutorizacion(factura.clave_acceso), otroServidor));
      if (r.estado === 'AUTORIZADO') {
        await guardar({
          estado: 'AUTORIZADA',
          numero_autorizacion: r.numeroAutorizacion ?? factura.clave_acceso,
          fecha_autorizacion: r.fechaAutorizacion,
          mensajes: r.mensajes,
        });
        return responder({ ok: true, data: { estado: 'AUTORIZADA' } });
      }
      if (r.estado === 'NO AUTORIZADO') {
        await guardar({ estado: 'NO_AUTORIZADA', mensajes: r.mensajes });
        return responder({ ok: true, data: { estado: 'NO_AUTORIZADA', mensajes: r.mensajes } });
      }
    }
    return responder({ ok: true, data: { estado: 'RECIBIDA' } });
  } catch (e) {
    // SRI caído o sin respuesta: queda como estaba, para reintentar.
    const mensaje = e instanceof Error ? e.message : 'Error desconocido';
    console.error('facturar', factura.id, mensaje);
    if (mensaje.startsWith('La firma') || mensaje.startsWith('No se pudo abrir') || mensaje.startsWith('El archivo')) {
      return fallo('FIRMA', mensaje);
    }
    return fallo('SRI_NO_RESPONDE', 'El SRI no respondió. La venta está guardada: vuelve a intentarlo en un momento');
  }
});
