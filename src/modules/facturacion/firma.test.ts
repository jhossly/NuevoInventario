import forge from 'node-forge';
import { beforeAll, describe, expect, it } from 'vitest';
import { abrirP12, firmarComprobante, verificarFirma } from '../../../supabase/functions/facturar/firma';
import {
  armarAutorizacion,
  armarRecepcion,
  leerAutorizacion,
  leerRecepcion,
  yaEstabaRecibida,
} from '../../../supabase/functions/facturar/sri';

const XML =
  '<?xml version="1.0" encoding="UTF-8"?><factura id="comprobante" version="1.1.0"><infoTributaria>' +
  '<razonSocial>DOÑA ROSA &amp; HIJOS</razonSocial></infoTributaria></factura>';

let p12Base64 = '';
let vencido = '';

function crearP12(clave: forge.pki.rsa.KeyPair, desde: Date, hasta: Date) {
  const c = forge.pki.createCertificate();
  c.publicKey = clave.publicKey;
  c.serialNumber = '0a1b2c';
  c.validity.notBefore = desde;
  c.validity.notAfter = hasta;
  const nombre = [
    { name: 'commonName', value: 'AUTORIDAD, DE PRUEBA' },
    { name: 'countryName', value: 'EC' },
  ];
  c.setSubject(nombre);
  c.setIssuer(nombre);
  c.sign(clave.privateKey, forge.md.sha256.create());
  const asn1 = forge.pkcs12.toPkcs12Asn1(clave.privateKey, [c], 'clave', { algorithm: '3des' });
  return forge.util.encode64(forge.asn1.toDer(asn1).getBytes());
}

beforeAll(() => {
  const clave = forge.pki.rsa.generateKeyPair({ bits: 2048 });
  p12Base64 = crearP12(clave, new Date('2020-01-01'), new Date('2090-01-01'));
  vencido = crearP12(clave, new Date('2020-01-01'), new Date('2021-01-01'));
}, 60_000);

describe('firma del comprobante', () => {
  it('firma y la firma se verifica, también con ñ y &', () => {
    const firmado = firmarComprobante(XML, abrirP12(p12Base64, 'clave'));
    expect(verificarFirma(firmado)).toEqual({ comprobante: true, propiedades: true, firma: true });
    expect(firmado.endsWith('</ds:Signature></factura>')).toBe(true);
    expect(firmado).toContain('rsa-sha256');
  });

  it('detecta un comprobante alterado después de firmar', () => {
    const firmado = firmarComprobante(XML, abrirP12(p12Base64, 'clave'));
    const alterado = firmado.replace('DOÑA ROSA', 'DOÑA ROSSA');
    expect(verificarFirma(alterado).comprobante).toBe(false);
  });

  it('escribe el emisor con la coma escapada y el número de serie en decimal', () => {
    const firmado = firmarComprobante(XML, abrirP12(p12Base64, 'clave'));
    expect(firmado).toContain('<ds:X509IssuerName>C=EC,CN=AUTORIDAD\\, DE PRUEBA</ds:X509IssuerName>');
    expect(firmado).toContain(`<ds:X509SerialNumber>${0x0a1b2c}</ds:X509SerialNumber>`);
  });

  it('avisa de contraseña equivocada y de firma vencida', () => {
    expect(() => abrirP12(p12Base64, 'otra')).toThrow('No se pudo abrir la firma');
    expect(() => abrirP12(vencido, 'clave')).toThrow('La firma electrónica está vencida');
  });

  it('no firma algo que no es un comprobante', () => {
    expect(() => firmarComprobante('<a></a>', abrirP12(p12Base64, 'clave'))).toThrow('id="comprobante"');
  });
});

describe('servicios del SRI', () => {
  it('arma los pedidos', () => {
    expect(armarRecepcion('<x/>', () => 'QkFTRTY0')).toContain('<xml>QkFTRTY0</xml>');
    expect(armarAutorizacion('123')).toContain('<claveAccesoComprobante>123</claveAccesoComprobante>');
  });

  it('lee una recepción aceptada', () => {
    const r = leerRecepcion(
      '<soap:Envelope><soap:Body><ns2:validarComprobanteResponse><RespuestaRecepcionComprobante><estado>RECIBIDA</estado>' +
        '<comprobantes/></RespuestaRecepcionComprobante></ns2:validarComprobanteResponse></soap:Body></soap:Envelope>',
    );
    expect(r).toEqual({ estado: 'RECIBIDA', mensajes: [] });
  });

  it('lee una devolución con sus mensajes y reconoce la clave ya recibida', () => {
    const r = leerRecepcion(
      '<RespuestaRecepcionComprobante><estado>DEVUELTA</estado><comprobantes><comprobante><claveAcceso>1</claveAcceso>' +
        '<mensajes><mensaje><identificador>43</identificador><mensaje>CLAVE ACCESO REGISTRADA</mensaje>' +
        '<informacionAdicional>Ya existe &amp; listo</informacionAdicional><tipo>ERROR</tipo></mensaje></mensajes>' +
        '</comprobante></comprobantes></RespuestaRecepcionComprobante>',
    );
    expect(r.estado).toBe('DEVUELTA');
    expect(r.mensajes).toEqual([
      { identificador: '43', mensaje: 'CLAVE ACCESO REGISTRADA', informacionAdicional: 'Ya existe & listo', tipo: 'ERROR' },
    ]);
    expect(yaEstabaRecibida(r)).toBe(true);
  });

  it('lee una autorización sin confundirse con el comprobante que trae dentro', () => {
    const r = leerAutorizacion(
      '<RespuestaAutorizacionComprobante><claveAccesoConsultada>1</claveAccesoConsultada><numeroComprobantes>1</numeroComprobantes>' +
        '<autorizaciones><autorizacion><estado>AUTORIZADO</estado><numeroAutorizacion>999</numeroAutorizacion>' +
        '<fechaAutorizacion>2026-10-31T10:00:00-05:00</fechaAutorizacion><ambiente>PRUEBAS</ambiente>' +
        '<comprobante><![CDATA[<factura><estado>OTRO</estado></factura>]]></comprobante><mensajes/></autorizacion></autorizaciones>' +
        '</RespuestaAutorizacionComprobante>',
    );
    expect(r).toEqual({
      estado: 'AUTORIZADO',
      numeroAutorizacion: '999',
      fechaAutorizacion: '2026-10-31T10:00:00-05:00',
      mensajes: [],
    });
  });

  it('lee un rechazo y una consulta todavía sin resultado', () => {
    const r = leerAutorizacion(
      '<autorizaciones><autorizacion><estado>NO AUTORIZADO</estado><fechaAutorizacion>x</fechaAutorizacion>' +
        '<mensajes><mensaje><identificador>39</identificador><mensaje>FIRMA INVALIDA</mensaje><tipo>ERROR</tipo></mensaje></mensajes>' +
        '</autorizacion></autorizaciones>',
    );
    expect(r.estado).toBe('NO AUTORIZADO');
    expect(r.mensajes[0]?.mensaje).toBe('FIRMA INVALIDA');
    expect(leerAutorizacion('<numeroComprobantes>0</numeroComprobantes><autorizaciones/>').estado).toBe('EN PROCESO');
  });
});
