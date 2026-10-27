import { createClient } from '@supabase/supabase-js';
import { leerEnv } from './env';

const env = leerEnv(import.meta.env);

/**
 * Cliente único de Supabase para el navegador.
 * Usa la clave pública (anon): por sí sola no da acceso a datos,
 * porque los permisos SQL, RLS y las funciones siguen protegiendo todo.
 */
export const supabase = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
  },
});
