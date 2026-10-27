import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';

/**
 * Pantalla temporal de la Fase 5: solo comprueba que la app llega a Supabase.
 * El inicio de sesión y los módulos llegan en las Fases 6 a 8.
 */
export function App() {
  const conexion = useQuery({
    queryKey: ['salud-conexion'],
    queryFn: async () => {
      // Sin sesión, la política correcta es NO devolver datos: un error de
      // permisos aquí confirma que la seguridad está activa.
      const { error } = await supabase.rpc('mi_contexto');
      return error ? `Conectado; acceso protegido (${error.code ?? 'sin código'})` : 'Conectado';
    },
  });

  return (
    <main className="mx-auto max-w-md p-4">
      <h1 className="text-2xl font-semibold">Bodega</h1>
      <p className="mt-2 text-gray-600">Fase 5: entorno de desarrollo.</p>
      <p className="mt-4 rounded-lg border border-gray-300 bg-white p-3" role="status">
        {conexion.isPending && 'Comprobando conexión…'}
        {conexion.isError && `Sin conexión: ${(conexion.error as Error).message}`}
        {conexion.isSuccess && conexion.data}
      </p>
    </main>
  );
}
