import { useRef } from 'react';

/**
 * Evita que un doble toque mande dos pedidos. `disabled` en el botón no basta:
 * los dos clics llegan antes de que React vuelva a dibujar. La clave de
 * idempotencia ya protege los datos; esto evita además una respuesta duplicada.
 *
 *   const unaVez = useUnSoloEnvio();
 *   unaVez((terminar) => guardar.mutate(datos, { onSettled: terminar }));
 */
export function useUnSoloEnvio() {
  const enCurso = useRef(false);
  return (accion: (terminar: () => void) => void) => {
    if (enCurso.current) return;
    enCurso.current = true;
    accion(() => {
      enCurso.current = false;
    });
  };
}
