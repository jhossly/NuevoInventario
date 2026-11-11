import { useCallback, useEffect, useRef, useState, type Dispatch, type SetStateAction } from 'react';
import { useSesion } from '@/modules/sesion/sesion';

const PREFIJO = 'bodega:borrador:';

function leer<T>(clave: string): T | undefined {
  try {
    const texto = localStorage.getItem(clave);
    return texto === null ? undefined : (JSON.parse(texto) as T);
  } catch {
    return undefined;
  }
}

function escribir(clave: string, valor: unknown) {
  try {
    localStorage.setItem(clave, JSON.stringify(valor));
  } catch {
    // Sin espacio o sin almacenamiento: se trabaja igual, solo sin borrador.
  }
}

function quitar(clave: string) {
  try {
    localStorage.removeItem(clave);
  } catch {
    // Nada que hacer.
  }
}

/**
 * Como useState, pero lo escrito queda guardado en el aparato (D-062): sobrevive
 * a cambiar de pantalla, cambiar de app o que el celular cierre la pestaña. Se
 * separa por usuario, para que en un mismo celular no se mezclen el Dueño y el
 * Vendedor. `borrar` lo descarta: se llama al guardar o al cancelar.
 */
export function useBorrador<T>(
  nombre: string,
  inicial: T | (() => T),
): [T, Dispatch<SetStateAction<T>>, () => void] {
  const sesion = useSesion();
  const usuario = sesion.estado === 'lista' ? sesion.correo : 'anonimo';
  const clave = `${PREFIJO}${usuario}:${nombre}`;
  const inicialRef = useRef(inicial);

  const [valor, setValor] = useState<T>(() => {
    const guardado = leer<T>(clave);
    if (guardado !== undefined) return guardado;
    const i = inicialRef.current;
    return i instanceof Function ? i() : i;
  });

  useEffect(() => {
    escribir(clave, valor);
  }, [clave, valor]);

  const borrar = useCallback(() => {
    quitar(clave);
    const i = inicialRef.current;
    setValor(i instanceof Function ? i() : i);
  }, [clave]);

  return [valor, setValor, borrar];
}

/** Al salir de la cuenta no deben quedar borradores de esa persona en el aparato. */
export function borrarBorradoresDe(correo: string) {
  try {
    for (const clave of Object.keys(localStorage)) {
      if (clave.startsWith(`${PREFIJO}${correo}:`)) localStorage.removeItem(clave);
    }
  } catch {
    // Nada que hacer.
  }
}
