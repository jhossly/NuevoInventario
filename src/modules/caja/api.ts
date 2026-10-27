import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { consultar, llamar } from '@/lib/datos';
import { decimal, uuid } from '@/shared/esquemas';

// -----------------------------------------------------------------------------
// Caja
// -----------------------------------------------------------------------------
const textoDecimal = decimal.nullable();

/** El detalle del esperado solo llega al Dueño (cierre a ciegas, D-032). */
export const esquemaResumenCaja = z.object({
  caja: z
    .object({
      caja_id: uuid,
      abierta_en: z.string(),
      fondo_inicial: decimal,
      cerrada_en: z.string().nullable(),
      monto_contado: textoDecimal,
      ventas: z.number(),
      ventas_efectivo: decimal.optional(),
      abonos_efectivo: decimal.optional(),
      ingresos: decimal.optional(),
      egresos: decimal.optional(),
      esperado: decimal.optional(),
      diferencia: textoDecimal.optional(),
      explicacion: z.string().nullable().optional(),
    })
    .nullable(),
});

export const esquemaMovimientoCaja = z.object({
  id: uuid,
  tipo: z.enum(['INGRESO', 'EGRESO']),
  monto: decimal,
  motivo: z.string(),
  automatico: z.boolean(),
  creado_en: z.string(),
});

export const esquemaCajaCerrada = z.object({
  id: uuid,
  abierta_en: z.string(),
  cerrada_en: z.string(),
  fondo_inicial: decimal,
  monto_contado: decimal,
});

export type ResumenCaja = NonNullable<z.infer<typeof esquemaResumenCaja>['caja']>;
export type MovimientoCaja = z.infer<typeof esquemaMovimientoCaja>;

export const claves = {
  caja: (id: string | null) => ['caja', id ?? 'abierta'] as const,
  movimientos: (cajaId: string) => ['caja', cajaId, 'movimientos'] as const,
  cerradas: ['caja', 'cerradas'] as const,
  cuentas: ['fiado', 'cuentas'] as const,
  cuenta: (clienteId: string) => ['fiado', clienteId] as const,
};

export function useResumenCaja(cajaId: string | null = null) {
  return useQuery({
    queryKey: claves.caja(cajaId),
    queryFn: async () => (await llamar('resumen_caja', { p_caja_id: cajaId }, esquemaResumenCaja)).caja,
  });
}

export function useMovimientosCaja(cajaId: string | undefined) {
  return useQuery({
    queryKey: claves.movimientos(cajaId ?? ''),
    queryFn: () =>
      consultar(
        supabase
          .from('caja_movimientos')
          .select('id,tipo,monto:monto::text,motivo,automatico,creado_en')
          .eq('caja_id', cajaId ?? '')
          .order('creado_en', { ascending: false }),
        z.array(esquemaMovimientoCaja),
      ),
    enabled: Boolean(cajaId),
  });
}

export function useCajasCerradas() {
  return useQuery({
    queryKey: claves.cerradas,
    queryFn: () =>
      consultar(
        supabase
          .from('cajas')
          .select('id,abierta_en,cerrada_en,fondo_inicial:fondo_inicial::text,monto_contado:monto_contado::text')
          .not('cerrada_en', 'is', null)
          .order('cerrada_en', { ascending: false })
          .limit(30),
        z.array(esquemaCajaCerrada),
      ),
  });
}

function useInvalidarCaja() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ['caja'] });
}

export function useAbrirCaja() {
  const invalidar = useInvalidarCaja();
  return useMutation({
    mutationFn: (fondo: string) => llamar('abrir_caja', { p_fondo_inicial: fondo }, z.object({ caja_id: uuid })),
    onSuccess: invalidar,
  });
}

export function useMovimientoCaja() {
  const invalidar = useInvalidarCaja();
  return useMutation({
    mutationFn: (d: { tipo: 'INGRESO' | 'EGRESO'; monto: string; motivo: string; clave: string }) =>
      llamar(
        'movimiento_caja',
        { p_tipo: d.tipo, p_monto: d.monto, p_motivo: d.motivo, p_clave_idempotencia: d.clave },
        z.object({ movimiento_id: uuid, repetido: z.boolean() }),
      ),
    onSuccess: invalidar,
  });
}

export function useCerrarCaja() {
  const invalidar = useInvalidarCaja();
  return useMutation({
    mutationFn: (d: { contado: string; nota: string | null }) =>
      llamar(
        'cerrar_caja',
        { p_monto_contado: d.contado, p_nota: d.nota },
        z.object({ caja_id: uuid, esperado: decimal.optional(), contado: decimal.optional(), diferencia: decimal.optional() }),
      ),
    onSuccess: invalidar,
  });
}

export function useExplicarDiferencia() {
  const invalidar = useInvalidarCaja();
  return useMutation({
    mutationFn: (d: { cajaId: string; explicacion: string }) =>
      llamar('explicar_diferencia_caja', { p_caja_id: d.cajaId, p_explicacion: d.explicacion }, z.object({ caja_id: uuid })),
    onSuccess: invalidar,
  });
}

// -----------------------------------------------------------------------------
// Fiado
// -----------------------------------------------------------------------------
export const esquemaCuenta = z.object({
  cliente_id: uuid,
  nombre: z.string(),
  fiado_permitido: z.boolean(),
  limite: decimal,
  saldo: decimal,
  disponible: decimal,
});

export const esquemaMovimientoFiado = z.object({
  id: uuid,
  tipo: z.enum(['CARGO', 'ABONO', 'AJUSTE']),
  monto: decimal,
  medio: z.string().nullable(),
  motivo: z.string().nullable(),
  venta_id: uuid.nullable(),
  creado_en: z.string(),
});

export type Cuenta = z.infer<typeof esquemaCuenta>;
export type MovimientoFiado = z.infer<typeof esquemaMovimientoFiado>;

export function useCuentasFiado() {
  return useQuery({
    queryKey: claves.cuentas,
    queryFn: async () => (await llamar('cuentas_fiado', {}, z.object({ clientes: z.array(esquemaCuenta) }))).clientes,
  });
}

export function useMovimientosFiado(clienteId: string | null) {
  return useQuery({
    queryKey: claves.cuenta(clienteId ?? ''),
    queryFn: () =>
      consultar(
        supabase
          .from('fiado_movimientos')
          .select('id,tipo,monto:monto::text,medio,motivo,venta_id,creado_en')
          .eq('cliente_id', clienteId ?? '')
          .order('creado_en', { ascending: false }),
        z.array(esquemaMovimientoFiado),
      ),
    enabled: Boolean(clienteId),
  });
}

function useInvalidarFiado() {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: ['fiado'] }),
      queryClient.invalidateQueries({ queryKey: ['caja'] }),
    ]);
}

export function useRegistrarAbono() {
  const invalidar = useInvalidarFiado();
  return useMutation({
    mutationFn: (d: { clienteId: string; monto: string; medio: string; clave: string }) =>
      llamar(
        'registrar_abono',
        { p_cliente_id: d.clienteId, p_monto: d.monto, p_medio: d.medio, p_clave_idempotencia: d.clave },
        z.object({ movimiento_id: uuid, repetido: z.boolean(), saldo: decimal }),
      ),
    onSuccess: invalidar,
  });
}

export function useAjustarFiado() {
  const invalidar = useInvalidarFiado();
  return useMutation({
    mutationFn: (d: { clienteId: string; monto: string; motivo: string }) =>
      llamar(
        'ajustar_fiado',
        { p_cliente_id: d.clienteId, p_monto: d.monto, p_motivo: d.motivo },
        z.object({ movimiento_id: uuid, saldo: decimal }),
      ),
    onSuccess: invalidar,
  });
}
