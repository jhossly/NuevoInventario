import { z } from 'zod';

/**
 * Variables de entorno que SÍ pueden llegar al navegador.
 * Vite solo expone las que empiezan con VITE_.
 *
 * Nunca agregues aquí la clave de servicio de Supabase ni la contraseña del .p12:
 * todo lo que empieza con VITE_ queda visible para cualquiera que abra la app.
 */
const esquemaEnv = z.object({
  VITE_SUPABASE_URL: z.string().url('VITE_SUPABASE_URL debe ser una URL'),
  VITE_SUPABASE_ANON_KEY: z.string().min(20, 'VITE_SUPABASE_ANON_KEY parece incompleta'),
});

export type Env = z.infer<typeof esquemaEnv>;

export function leerEnv(fuente: Record<string, unknown>): Env {
  const resultado = esquemaEnv.safeParse(fuente);
  if (!resultado.success) {
    const problemas = resultado.error.issues.map((i) => `- ${i.path.join('.')}: ${i.message}`);
    throw new Error(
      `Configuración incompleta. Copia .env.example a .env.local y complétalo.\n${problemas.join('\n')}`,
    );
  }
  return resultado.data;
}
