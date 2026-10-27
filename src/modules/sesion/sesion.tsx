import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Session } from '@supabase/supabase-js';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { llamar } from '@/lib/datos';
import { ErrorDeNegocio } from '@/shared/rpc';

const esquemaContexto = z.object({
  empresa_id: z.string().uuid(),
  nombre: z.string(),
  regimen: z.string(),
  rol: z.enum(['DUENO', 'VENDEDOR']),
  ve_costos: z.boolean(),
  precios_incluyen_iva: z.boolean(),
});

export type Contexto = z.infer<typeof esquemaContexto>;

export type EstadoSesion =
  | { estado: 'cargando' }
  | { estado: 'sin-sesion' }
  | { estado: 'sin-empresa'; correo: string }
  | { estado: 'error'; mensaje: string }
  | { estado: 'lista'; correo: string; contexto: Contexto };

const SesionContexto = createContext<EstadoSesion>({ estado: 'cargando' });

export function SesionProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [sesion, setSesion] = useState<Session | null | undefined>(undefined);

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => setSesion(data.session));
    const { data } = supabase.auth.onAuthStateChange((evento, nueva) => {
      // Al cambiar de usuario no debe quedar nada del anterior en caché.
      if (evento === 'SIGNED_OUT' || evento === 'SIGNED_IN') queryClient.clear();
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
