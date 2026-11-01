import forge from 'node-forge';

/**
 * Firma XAdES-BES de un comprobante del SRI (D-053).
 *
 * Copia la forma de las facturas del portal del SRI: RSA con SHA-256,
 * C14N inclusivo y firma envuelta al final del comprobante. El XML lo genera
 * la base en una sola línea, sin comentarios ni atributos desordenados: así el
 * texto ya está canonizado y no hace falta un canonizador general.
 */

const NS_DS = 'http://www.w3.org/2000/09/xmldsig#';
const NS_XADES = 'http://uri.etsi.org/01903/v1.3.2#';
const NS_XADES141 = 'http://uri.etsi.org/01903/v1.4.1#';
const C14N = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315';
const RSA_SHA256 = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256';
const SHA256 = 'http://www.w3.org/2001/04/xmlenc#sha256';
const ENVUELTA = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature';

// Identificadores de las bolsas del .p12; los tipos de forge los dejan opcionales.
const BOLSA_CLAVE_PROTEGIDA = forge.pki.oids.pkcs8ShroudedKeyBag as string;
const BOLSA_CLAVE = forge.pki.oids.keyBag as string;
const BOLSA_CERTIFICADO = forge.pki.oids.certBag as string;

export interface Identidad {
  clave: forge.pki.rsa.PrivateKey;
  certificado: forge.pki.Certificate;
}

export function sha256Base64(texto: string): string {
  const md = forge.md.sha256.create();
  md.update(texto, 'utf8');
  return forge.util.encode64(md.digest().getBytes());
}

/** Busca el certificado que corresponde a la clave privada del archivo .p12. */
export function abrirP12(p12Base64: string, contrasena: string, ahora = new Date()): Identidad {
  let p12: forge.pkcs12.Pkcs12Pfx;
  try {
    p12 = forge.pkcs12.pkcs12FromAsn1(forge.asn1.fromDer(forge.util.decode64(p12Base64)), false, contrasena);
  } catch {
    throw new Error('No se pudo abrir la firma: revisa el archivo .p12 y su contraseña');
  }
  const claves = [
    ...(p12.getBags({ bagType: BOLSA_CLAVE_PROTEGIDA })[BOLSA_CLAVE_PROTEGIDA] ?? []),
    ...(p12.getBags({ bagType: BOLSA_CLAVE })[BOLSA_CLAVE] ?? []),
  ];
  const clave = claves[0]?.key as forge.pki.rsa.PrivateKey | undefined;
  if (!clave) throw new Error('El archivo .p12 no tiene clave privada');

  const certificado = (p12.getBags({ bagType: BOLSA_CERTIFICADO })[BOLSA_CERTIFICADO] ?? [])
    .map((b) => b.cert)
    .find((c) => {
      const publica = c?.publicKey as forge.pki.rsa.PublicKey | undefined;
      return publica?.n?.equals(clave.n) && publica.e.equals(clave.e);
    });
  if (!certificado) throw new Error('El archivo .p12 no tiene el certificado de la clave');
  if (ahora < certificado.validity.notBefore || ahora > certificado.validity.notAfter) {
    throw new Error('La firma electrónica está vencida');
  }
  return { clave, certificado };
}

function escapar(texto: string): string {
  return texto.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Nombre del emisor en orden RFC 2253 (del más específico al país). */
function nombreEmisor(certificado: forge.pki.Certificate): string {
  return [...certificado.issuer.attributes]
    .reverse()
    .map((a) => `${a.shortName ?? a.type}=${String(a.value).replace(/([,+"\\<>;])/g, '\\$1')}`)
    .join(',');
}

function bloques(valor: string): string {
  return valor.replace(/\s/g, '');
}

export interface OpcionesFirma {
  /** Fecha de la firma; por defecto, ahora. */
  fecha?: Date;
  /** Identificador de la firma; por defecto, aleatorio. */
  id?: string;
}

/** Devuelve el comprobante con la firma como último hijo del elemento raíz. */
export function firmarComprobante(xml: string, identidad: Identidad, opciones: OpcionesFirma = {}): string {
  const raiz = xml.match(/<(\w+) id="comprobante"[^>]*>/)?.[1];
  if (!raiz) throw new Error('El comprobante no tiene id="comprobante"');
  const cierre = `</${raiz}>`;
  const posicion = xml.lastIndexOf(cierre);
  if (posicion < 0) throw new Error('El comprobante está incompleto');

  const id = opciones.id ?? forge.util.bytesToHex(forge.random.getBytesSync(16));
  const ref = `xmldsig${id}ref0`;
  const firmaId = `xmldsig${id}`;
  const propiedadesId = `xmldsig${id}signedprops`;
  const fecha = (opciones.fecha ?? new Date()).toISOString().replace(/\.\d+Z$/, 'Z');

  const { certificado, clave } = identidad;
  const der = forge.asn1.toDer(forge.pki.certificateToAsn1(certificado)).getBytes();
  const certificadoBase64 = bloques(forge.util.encode64(der));
  const mdCert = forge.md.sha256.create();
  mdCert.update(der, 'raw');
  const digestCert = forge.util.encode64(mdCert.digest().getBytes());
  const serie = BigInt(`0x${certificado.serialNumber}`).toString();

  // Sin los xmlns: se agregan solo al calcular el digest, como manda C14N.
  const propiedades =
    `<xades:SignedSignatureProperties><xades:SigningTime>${fecha}</xades:SigningTime>` +
    `<xades:SigningCertificate><xades:Cert><xades:CertDigest><ds:DigestMethod Algorithm="${SHA256}"></ds:DigestMethod>` +
    `<ds:DigestValue>${digestCert}</ds:DigestValue></xades:CertDigest><xades:IssuerSerial>` +
    `<ds:X509IssuerName>${escapar(nombreEmisor(certificado))}</ds:X509IssuerName>` +
    `<ds:X509SerialNumber>${serie}</ds:X509SerialNumber></xades:IssuerSerial></xades:Cert></xades:SigningCertificate>` +
    `</xades:SignedSignatureProperties><xades:SignedDataObjectProperties>` +
    `<xades:DataObjectFormat ObjectReference="#${ref}"><xades:Description>contenido firmado</xades:Description>` +
    `<xades:MimeType>text/xml</xades:MimeType><xades:Encoding>UTF-8</xades:Encoding></xades:DataObjectFormat>` +
    `</xades:SignedDataObjectProperties>`;
  const propiedadesCanon =
    `<xades:SignedProperties xmlns:ds="${NS_DS}" xmlns:xades="${NS_XADES}" xmlns:xades141="${NS_XADES141}" ` +
    `Id="${propiedadesId}">${propiedades}</xades:SignedProperties>`;

  const firmado = (ns: string) =>
    `<ds:SignedInfo${ns}><ds:CanonicalizationMethod Algorithm="${C14N}"></ds:CanonicalizationMethod>` +
    `<ds:SignatureMethod Algorithm="${RSA_SHA256}"></ds:SignatureMethod>` +
    `<ds:Reference Id="${ref}" URI="#comprobante"><ds:Transforms><ds:Transform Algorithm="${ENVUELTA}"></ds:Transform>` +
    `</ds:Transforms><ds:DigestMethod Algorithm="${SHA256}"></ds:DigestMethod>` +
    `<ds:DigestValue>${sha256Base64(canonizarComprobante(xml))}</ds:DigestValue></ds:Reference>` +
    `<ds:Reference Type="http://uri.etsi.org/01903#SignedProperties" URI="#${propiedadesId}">` +
    `<ds:DigestMethod Algorithm="${SHA256}"></ds:DigestMethod>` +
    `<ds:DigestValue>${sha256Base64(propiedadesCanon)}</ds:DigestValue></ds:Reference></ds:SignedInfo>`;

  const md = forge.md.sha256.create();
  md.update(firmado(` xmlns:ds="${NS_DS}"`), 'utf8');
  const valor = bloques(forge.util.encode64(clave.sign(md)));

  const firma =
    `<ds:Signature xmlns:ds="${NS_DS}" Id="${firmaId}">${firmado('')}` +
    `<ds:SignatureValue Id="${firmaId}sigvalue">${valor}</ds:SignatureValue>` +
    `<ds:KeyInfo><ds:X509Data><ds:X509Certificate>${certificadoBase64}</ds:X509Certificate></ds:X509Data></ds:KeyInfo>` +
    `<ds:Object><xades:QualifyingProperties xmlns:xades="${NS_XADES}" xmlns:xades141="${NS_XADES141}" Target="#${firmaId}">` +
    `<xades:SignedProperties Id="${propiedadesId}">${propiedades}</xades:SignedProperties>` +
    `</xades:QualifyingProperties></ds:Object></ds:Signature>`;

  return xml.slice(0, posicion) + firma + xml.slice(posicion);
}

/** El comprobante tal como lo ve C14N: sin declaración XML, sin firma y sin CR. */
export function canonizarComprobante(xml: string): string {
  return xml
    .replace(/^\uFEFF?<\?xml[^>]*\?>\s*/, '')
    .replace(/<ds:Signature[\s\S]*<\/ds:Signature>/, '')
    .replace(/\r\n?/g, '\n')
    .replace(/\s+$/, '');
}

/**
 * Comprueba una firma como lo haría el SRI: ambos digests y la firma RSA.
 * Sirve para probar el firmador y para no enviar nada mal firmado.
 */
export function verificarFirma(xml: string): { comprobante: boolean; propiedades: boolean; firma: boolean } {
  const bloque = (patron: RegExp, nombre: string) => {
    const m = xml.match(patron);
    if (!m) throw new Error(`Falta ${nombre} en la firma`);
    return m;
  };
  const expandir = (t: string) =>
    t.replace(/<((?:ds|xades):[\w]+)((?:\s[^>]*?)?)\/>/g, '<$1$2></$1>');

  const info = expandir(bloque(/<ds:SignedInfo>[\s\S]*?<\/ds:SignedInfo>/, 'SignedInfo')[0]);
  const digests = [...info.matchAll(/<ds:DigestValue>([^<]+)<\/ds:DigestValue>/g)].map((m) => m[1]);
  const propiedades = expandir(bloque(/<xades:SignedProperties [\s\S]*?<\/xades:SignedProperties>/, 'SignedProperties')[0]);
  const propiedadesCanon = propiedades.replace(
    '<xades:SignedProperties ',
    `<xades:SignedProperties xmlns:ds="${NS_DS}" xmlns:xades="${NS_XADES}" xmlns:xades141="${NS_XADES141}" `,
  );

  const certificado = forge.pki.certificateFromAsn1(
    forge.asn1.fromDer(forge.util.decode64(bloque(/<ds:X509Certificate>([^<]+)</, 'certificado')[1] ?? '')),
  );
  const valor = forge.util.decode64(bloque(/<ds:SignatureValue[^>]*>([^<]+)</, 'SignatureValue')[1] ?? '');
  const md = forge.md.sha256.create();
  md.update(info.replace('<ds:SignedInfo>', `<ds:SignedInfo xmlns:ds="${NS_DS}">`), 'utf8');

  // El documento conserva sus saltos de línea interiores: se calcula con y sin
  // el que queda antes de cerrar, porque C14N guarda el texto entre etiquetas.
  const cuerpo = xml.replace(/^\uFEFF?<\?xml[^>]*\?>\s*/, '').replace(/<ds:Signature[\s\S]*<\/ds:Signature>/, '').replace(/\r\n?/g, '\n');
  return {
    comprobante: [cuerpo, cuerpo.trimEnd()].some((t) => sha256Base64(t) === digests[0]),
    propiedades: sha256Base64(propiedadesCanon) === digests[1],
    firma: (certificado.publicKey as forge.pki.rsa.PublicKey).verify(md.digest().getBytes(), valor),
  };
}
