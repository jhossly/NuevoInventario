/**
 * Claves de idempotencia (uuid v4).
 *
 * crypto.randomUUID solo existe en contextos seguros (https o localhost). El
 * Dueño puede abrir la app desde el celular por la red local (http://192.168…),
 * donde no está; crypto.getRandomValues sí, así que se usa como respaldo.
 */
export function nuevaClave(fuente: Pick<Crypto, 'getRandomValues'> & Partial<Pick<Crypto, 'randomUUID'>> = crypto): string {
  if (typeof fuente.randomUUID === 'function') return fuente.randomUUID();

  const bytes = fuente.getRandomValues(new Uint8Array(16));
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40; // versión 4
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80; // variante RFC 4122
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
