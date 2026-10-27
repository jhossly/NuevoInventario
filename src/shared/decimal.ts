/**
 * Lectura de números escritos por la persona ("1,25", "1.25", " 3 ").
 *
 * Devuelve el número como TEXTO normalizado ("1.25") para enviarlo tal cual
 * a la base: un `number` de JavaScript perdería precisión (D-019). No redondea:
 * si hay más decimales de los permitidos, avisa (D-011: redondear es tarea de
 * las funciones SQL, y aquí no queremos cambiar en silencio lo escrito).
 */

export type LecturaDecimal = { ok: true; valor: string } | { ok: false; mensaje: string };

export interface OpcionesDecimal {
  /** Decimales máximos aceptados. */
  decimales: number;
  /** Acepta el signo menos. Por defecto no. */
  permitirNegativo?: boolean;
  /** Acepta cero. Por defecto sí. */
  permitirCero?: boolean;
}

const FORMA = /^(-)?(\d+)(?:[.,](\d+))?$/;

export function leerDecimal(texto: string, opciones: OpcionesDecimal): LecturaDecimal {
  const limpio = texto.trim().replace(/\s+/g, '');
  if (limpio === '') return { ok: false, mensaje: 'Escribe un número' };

  const partes = FORMA.exec(limpio);
  if (!partes) return { ok: false, mensaje: 'Usa solo números y una coma decimal' };

  const [, signo, enteros = '', fraccion = ''] = partes;
  if (signo && !opciones.permitirNegativo) return { ok: false, mensaje: 'No puede ser negativo' };
  if (fraccion.length > opciones.decimales) {
    return {
      ok: false,
      mensaje:
        opciones.decimales === 0
          ? 'Debe ser un número entero'
          : `Máximo ${opciones.decimales} decimales`,
    };
  }

  const enterosLimpios = enteros.replace(/^0+(?=\d)/, '');
  const fraccionLimpia = fraccion.replace(/0+$/, '');
  const esCero = /^0*$/.test(enteros) && /^0*$/.test(fraccion);
  if (esCero && opciones.permitirCero === false) return { ok: false, mensaje: 'No puede ser cero' };

  const valor = `${signo && !esCero ? '-' : ''}${enterosLimpios}${fraccionLimpia ? `.${fraccionLimpia}` : ''}`;
  return { ok: true, valor };
}

/** Prepara un numeric de la base para un campo editable: "12.000000" → "12", "0.450" → "0,45". */
export function paraEditar(valor: string): string {
  const sinCeros = valor.includes('.') ? valor.replace(/0+$/, '').replace(/\.$/, '') : valor;
  return sinCeros.replace('.', ',');
}

/**
 * Vuelto: lo recibido menos el total, en centavos exactos (sin `number`).
 * Es una resta para mostrar en pantalla, no un cálculo de negocio (D-011).
 * Ambos valores deben venir ya validados con 2 decimales como máximo.
 */
export function restarDinero(recibido: string, total: string): string {
  const centavos = (v: string): bigint => {
    const [enteros = '0', fraccion = ''] = v.replace('-', '').split('.');
    const absoluto = BigInt(enteros) * 100n + BigInt((fraccion + '00').slice(0, 2));
    return v.startsWith('-') ? -absoluto : absoluto;
  };
  const diferencia = centavos(recibido) - centavos(total);
  const absoluto = diferencia < 0n ? -diferencia : diferencia;
  const texto = `${absoluto / 100n}.${String(absoluto % 100n).padStart(2, '0')}`;
  return diferencia < 0n ? `-${texto}` : texto;
}

/** Cambia el signo de un decimal ya normalizado ("2" → "-2"). */
export function negar(valor: string): string {
  if (/^-?0(\.0+)?$/.test(valor)) return valor.replace('-', '');
  return valor.startsWith('-') ? valor.slice(1) : `-${valor}`;
}
