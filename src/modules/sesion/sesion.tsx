import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Session } from '@supabase/supabase-js';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { llamar } from '@/lib/datos';
import { ErrorDeNegocio } from '@/shared/rpc';

const esquemaContexto = z.object({
  empresa_id: z.string().uuid(),
  nombre: z.string(),
  logo: z.string().nullable(),
  regimen: z.string(),
  rol: z.enum(['DUENO', 'VENDEDOR']),
  ve_costos: z.boolean(),
  precios_incluyen_iva: z.boolean(),
  // Opcionales: la app nueva no se cae si la base aún no se actualiza.
  facturacion_activa: z.boolean().optional(),
  ambiente_sri: z.string().optional(),
});

export type Contexto = z.infer<typeof esquemaContexto>;

export type EstadoSesion =
  | { estado: 'cargando' }
  | { estado: 'sin-sesion' }
  | { estado: 'sin-empresa'; correo: string }
  | { estado: 'error'; mensaje: string }
  | { estado: 'lista'; correo: string; contexto: Contexto }
  | { estado: 'nueva-clave'; terminar: () => void };

const SesionContexto = createContext<EstadoSesion>({ estado: 'cargando' });

export function SesionProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [sesion, setSesion] = useState<Session | null | undefined>(undefined);
  // Vino por el enlace de «Olvidé mi contraseña»: primero se pide la nueva.
  const [recuperando, setRecuperando] = useState(false);
  const usuarioAnterior = useRef<string | null | undefined>(undefined);

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      usuarioAnterior.current = data.session?.user.id ?? null;
      setSesion(data.session);
    });
    const { data } = supabase.auth.onAuthStateChange((evento, nueva) => {
      // Al cambiar de usuario no debe quedar nada del anterior en caché. Ojo:
      // Supabase repite SIGNED_IN al volver a la pestaña (y al volver del
      // selector de archivos del celular) con el mismo usuario; limpiar ahí
      // reiniciaba la pantalla y se perdía lo escrito.
      const id = nueva?.user.id ?? null;
      if (evento === 'SIGNED_OUT' || id !== usuarioAnterior.current) queryClient.clear();
      usuarioAnterior.current = id;
      if (evento === 'PASSWORD_RECOVERY') setRecuperando(true);
      if (evento === 'SIGNED_OUT') setRecuperando(false);
      setSesion(nueva);
    });
    return () => data.subscription.unsubscribe();
  }, [queryClient]);

  const usuario = sesion?.user.id;
  const contexto = useQuery({
    queryKey: ['contexto', usuario],
    queryFn: () => llamar('mi_contexto', {}, esquemaContexto),
    enabled: Boolean(usuario),
    staleTime: 5 * 60_000,
    retry: false,
  });

  let estado: EstadoSesion;
  if (sesion === undefined) estado = { estado: 'cargando' };
  else if (sesion === null) estado = { estado: 'sin-sesion' };
  else if (recuperando) estado = { estado: 'nueva-clave', terminar: () => setRecuperando(false) };
  else if (contexto.isPending) estado = { estado: 'cargando' };
  else if (contexto.isError) {
    const error = contexto.error;
    estado =
      error instanceof ErrorDeNegocio && error.codigo === 'SIN_PERMISO'
        ? { estado: 'sin-empresa', correo: sesion.user.email ?? '' }
        : { estado: 'error', mensaje: error.message };
  } else estado = { estado: 'lista', correo: sesion.user.email ?? '', contexto: contexto.data };

  return <SesionContexto.Provider value={estado}>{children}</SesionContexto.Provider>;
}

export function useSesion(): EstadoSesion {
  return useContext(SesionContexto);
}

/** Solo para pantallas que se muestran con la sesión lista. */
export function useContexto(): Contexto {
  const sesion = useSesion();
  if (sesion.estado !== 'lista') throw new Error('useContexto fuera de una sesión lista');
  return sesion.contexto;
}

export async function cerrarSesion(): Promise<void> {
  await supabase.auth.signOut();
}
