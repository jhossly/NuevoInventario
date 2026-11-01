/**
 * Servicios web del SRI (esquema offline). Solo arma y lee los SOAP; no sabe
 * nada de la base, para poder probarlo sin conexión.
 */

const SERVIDORES: Record<string, string> = {
  '1': 'https://celcer.sri.gob.ec',
  '2': 'https://cel.sri.gob.ec',
};

const BASE = '/comprobantes-electronicos-ws';

export interface MensajeSri {
  identificador: string;
  mensaje: string;
  informacionAdicional?: string;
  tipo?: string;
}

export interface Recepcion {
  estado: 'RECIBIDA' | 'DEVUELTA';
  mensajes: MensajeSri[];
}

export interface Autorizacion {
  estado: 'AUTORIZADO' | 'NO AUTORIZADO' | 'EN PROCESO';
  numeroAutorizacion?: string;
  fechaAutorizacion?: string;
  mensajes: MensajeSri[];
}

function etiqueta(xml: string, nombre: string): string | undefined {
  return xml.match(new RegExp(`<(?:\\w+:)?${nombre}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:\\w+:)?${nombre}>`))?.[1]?.trim();
}

function textoXml(t: string | undefined): string | undefined {
  return t?.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
}

function leerMensajes(xml: string): MensajeSri[] {
  return [...xml.matchAll(/<(?:\w+:)?mensaje(?:\s[^>]*)?>\s*<(?:\w+:)?identificador[\s\S]*?<\/(?:\w+:)?mensaje>\s*(?=<\/|<(?:\w+:)?mensaje\b)/g)].map((m) => {
    const b = m[0];
    const interior = b.replace(/^<(?:\w+:)?mensaje(?:\s[^>]*)?>/, '');
    return {
      identificador: etiqueta(interior, 'identificador') ?? '',
      mensaje: textoXml(etiqueta(interior, 'mensaje')) ?? '',
      informacionAdicional: textoXml(etiqueta(interior, 'informacionAdicional')),
      tipo: etiqueta(interior, 'tipo'),
    };
  });
}

export function armarRecepcion(xmlFirmado: string, base64: (texto: string) => string): string {
  return (
    '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" ' +
    'xmlns:ec="http://ec.gob.sri.ws.recepcion"><soapenv:Header/><soapenv:Body><ec:validarComprobante>' +
    `<xml>${base64(xmlFirmado)}</xml></ec:validarComprobante></soapenv:Body></soapenv:Envelope>`
  );
}

export function armarAutorizacion(claveAcceso: string): string {
  return (
    '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" ' +
    'xmlns:ec="http://ec.gob.sri.ws.autorizacion"><soapenv:Header/><soapenv:Body><ec:autorizacionComprobante>' +
    `<claveAccesoComprobante>${claveAcceso}</claveAccesoComprobante></ec:autorizacionComprobante></soapenv:Body></soapenv:Envelope>`
  );
}

export function leerRecepcion(respuesta: string): Recepcion {
  const estado = etiqueta(respuesta, 'estado');
  if (estado !== 'RECIBIDA' && estado !== 'DEVUELTA') throw new Error('Respuesta del SRI no reconocida');
  return { estado, mensajes: leerMensajes(respuesta) };
}

export function leerAutorizacion(respuesta: string): Autorizacion {
  const bloque = etiqueta(respuesta, 'autorizacion');
  if (!bloque) return { estado: 'EN PROCESO', mensajes: [] };
  const estado = etiqueta(bloque, 'estado');
  // El comprobante viene dentro y puede traer sus propias etiquetas.
  const sinComprobante = bloque.replace(/<(?:\w+:)?comprobante>[\s\S]*<\/(?:\w+:)?comprobante>/, '');
  if (estado === 'AUTORIZADO') {
    return {
      estado,
      numeroAutorizacion: etiqueta(sinComprobante, 'numeroAutorizacion'),
      fechaAutorizacion: etiqueta(sinComprobante, 'fechaAutorizacion'),
      mensajes: leerMensajes(sinComprobante),
    };
  }
  if (estado === 'NO AUTORIZADO') return { estado, mensajes: leerMensajes(sinComprobante) };
  return { estado: 'EN PROCESO', mensajes: leerMensajes(sinComprobante) };
}

/** Error 43: esa clave ya fue recibida; toca preguntar por su autorización. */
export function yaEstabaRecibida(recepcion: Recepcion): boolean {
  return recepcion.mensajes.some((m) => m.identificador === '43');
}

async function llamar(url: string, cuerpo: string, milisegundos: number): Promise<string> {
  const respuesta = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'text/xml; charset=utf-8', SOAPAction: '""' },
    body: cuerpo,
    signal: AbortSignal.timeout(milisegundos),
  });
  const texto = await respuesta.text();
  if (!respuesta.ok && !texto.includes('estado')) throw new Error(`El SRI respondió ${respuesta.status}`);
  return texto;
}

/** `otro` reemplaza al servidor de pruebas (nunca al de producción) para probar sin el SRI. */
function servidor(ambiente: string, otro?: string): string {
  return (ambiente === '1' && otro) || SERVIDORES[ambiente] || '';
}

export function enviarRecepcion(ambiente: string, cuerpo: string, otro?: string): Promise<string> {
  return llamar(`${servidor(ambiente, otro)}${BASE}/RecepcionComprobantesOffline`, cuerpo, 20_000);
}

export function consultarAutorizacion(ambiente: string, cuerpo: string, otro?: string): Promise<string> {
  return llamar(`${servidor(ambiente, otro)}${BASE}/AutorizacionComprobantesOffline`, cuerpo, 20_000);
}
