import type { ZodType } from 'zod';
import { supabase } from './supabase';
import { exigir, interpretarConsulta, interpretarFuncion, type ResultadoSupabase } from '@/shared/rpc';

/**
 * Las dos únicas formas en que la interfaz habla con la base:
 *   * llamar(): funciones de negocio (todas las escrituras, regla 3)
 *   * consultar(): lecturas directas de tablas, ya filtradas por RLS
 * Ambas validan la respuesta con Zod y lanzan ErrorDeNegocio si algo falla.
 */

export async function llamar<T>(funcion: string, argumentos: Record<string, unknown>, esquema: ZodType<T>): Promise<T> {
  const resultado = (await supabase.rpc(funcion, argumentos)) as ResultadoSupabase;
  return exigir(interpretarFuncion(resultado, esquema));
}

export async function consultar<T>(consulta: PromiseLike<ResultadoSupabase>, esquema: ZodType<T>): Promise<T> {
  return exigir(interpretarConsulta(await consulta, esquema));
}
