-- =============================================================================
-- Pruebas de caja y fiado (Fase 9)
--   * HU-04: sin caja no hay ventas en efectivo; esperado = fondo + ventas en
--     efectivo + abonos en efectivo + ingresos − egresos; diferencia al cerrar
--   * cierre a ciegas del Vendedor (D-032); la caja no se reabre
--   * fiado: límite del Vendedor (Fase 4), abonos, ajustes, saldo
--   * anulaciones y devoluciones devuelven el efectivo desde la caja o
--     descuentan el fiado
--   * inmutabilidad y aislamiento
-- Las ventas al fiado simultáneas están en supabase/tests/concurrencia/.
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(50);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a001', 'dueno.a@prueba.test'),
  ('00000000-0000-0000-0000-00000000a002', 'vendedor.a@prueba.test'),
  ('00000000-0000-0000-0000-00000000b001', 'dueno.b@prueba.test');

insert into public.empresas (id, ruc, razon_social) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '0900000000001', 'Bodega A'),
  ('bbbbbbbb-0000-0000-0000-000000000000', '0900000000002', 'Bodega B');

insert into public.perfiles (id, nombre) values
  ('00000000-0000-0000-0000-00000000a001', 'Dueño A'),
  ('00000000-0000-0000-0000-00000000a002', 'Vendedor A'),
  ('00000000-0000-0000-0000-00000000b001', 'Dueño B');

insert into public.membresias (empresa_id, usuario_id, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a001', 'DUENO'),
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a002', 'VENDEDOR'),
  ('bbbbbbbb-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000b001', 'DUENO');

-- Catálogo y clientes del Dueño de A
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite 1 L","tarifa_iva":15,"precio_venta":3.45}') -> 'data' ->> 'id', true);
select set_config('prueba.u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid), true);
select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 100, 2);
select set_config('prueba.juan', public.guardar_cliente(null,
  '{"nombre":"Juan","fiado_permitido":true,"limite_fiado":20}') -> 'data' ->> 'id', true);
select set_config('prueba.pedro', public.guardar_cliente(null, '{"nombre":"Pedro"}') -> 'data' ->> 'id', true);

reset role;

-- Ayuda: venta de n aceites con los pagos dados.
create function pg_temp.venta(n int, pagos jsonb, cliente text default null)
returns jsonb language sql as $$
  select public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.u'), 'cantidad', n)),
    pagos, nullif(cliente, '')::uuid, null, gen_random_uuid())
$$;
grant execute on function pg_temp.venta(int, jsonb, text) to authenticated;

-- =============================================================================
-- Vendedor: caja
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);

select is(pg_temp.venta(1, null) -> 'error' ->> 'codigo', 'CAJA_CERRADA',
  'K1. HU-04: sin caja abierta no se vende en efectivo');

select set_config('prueba.v_transf', pg_temp.venta(1, '[{"medio":"TRANSFERENCIA","monto":3.45}]') -> 'data' ->> 'venta_id', true);
select is((select caja_id from public.ventas where id = nullif(current_setting('prueba.v_transf'), '')::uuid), null,
  'K2. Una venta por transferencia no necesita caja');

select set_config('prueba.caja', coalesce(public.abrir_caja(20) -> 'data' ->> 'caja_id', ''), true);
select isnt(nullif(current_setting('prueba.caja'), ''), null,
  'K3. El Vendedor abre la caja con $20 de fondo');

select is(public.abrir_caja(10) -> 'error' ->> 'mensaje', 'Ya hay una caja abierta',
  'K4. Solo hay una caja abierta a la vez');

select set_config('prueba.v_efectivo', pg_temp.venta(3, null) -> 'data' ->> 'venta_id', true);
select is((select caja_id::text from public.ventas where id = current_setting('prueba.v_efectivo')::uuid),
  current_setting('prueba.caja'),
  'K5. La venta en efectivo queda en la caja abierta');

select set_config('prueba.v_mixta', pg_temp.venta(3, '[{"medio":"EFECTIVO","monto":5},{"medio":"TARJETA","monto":5.35}]')
  -> 'data' ->> 'venta_id', true);
select isnt(nullif(current_setting('prueba.v_mixta'), ''), null,
  'K6. Venta mixta: $5 en efectivo y $5,35 con tarjeta');

select is(public.movimiento_caja('EGRESO', 3, 'Pago de hielo', gen_random_uuid()) ->> 'ok', 'true',
  'K7. Egreso manual con motivo');
select public.movimiento_caja('INGRESO', 1, 'Cambio traído del banco', gen_random_uuid());

select is(public.movimiento_caja('EGRESO', 3, ' ', gen_random_uuid()) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'K8. Un egreso necesita motivo');

-- =============================================================================
-- Vendedor: fiado
-- =============================================================================
select set_config('prueba.v_fiado', pg_temp.venta(3, '[{"medio":"FIADO","monto":10.35}]', current_setting('prueba.juan'))
  -> 'data' ->> 'venta_id', true);
select isnt(nullif(current_setting('prueba.v_fiado'), ''), null,
  'F1. El Vendedor fía $10,35 a Juan (límite $20)');

select results_eq(
  $$ select c ->> 'saldo', c ->> 'disponible'
       from jsonb_array_elements(public.cuentas_fiado() -> 'data' -> 'clientes') c
      where c ->> 'cliente_id' = current_setting('prueba.juan') $$,
  $$ values ('10.35', '9.65') $$,
  'F2. Juan debe $10,35 y le quedan $9,65');

select results_eq(
  $$ select r -> 'error' ->> 'codigo', r -> 'error' ->> 'mensaje'
       from (select pg_temp.venta(3, '[{"medio":"FIADO","monto":10.35}]', current_setting('prueba.juan')) r) x $$,
  $$ values ('LIMITE_FIADO', 'Juan supera su límite de fiado (disponible 9.65)') $$,
  'F3. Fase 4: el Vendedor no pasa el límite de fiado');

select is(pg_temp.venta(1, '[{"medio":"FIADO","monto":3.45}]', current_setting('prueba.pedro')) -> 'error' ->> 'codigo',
  'LIMITE_FIADO',
  'F4. El Vendedor no fía a un cliente sin fiado autorizado');

select is(pg_temp.venta(1, '[{"medio":"FIADO","monto":3.45}]') -> 'error' ->> 'mensaje',
  'Elige el cliente que se lleva al fiado',
  'F5. No hay fiado sin cliente');

select is(public.registrar_abono(current_setting('prueba.juan')::uuid, 5, 'EFECTIVO', 'eeeeeeee-0000-0000-0000-000000000001')
    -> 'data' ->> 'saldo', '5.35',
  'F6. Juan abona $5 en efectivo: debe $5,35');

select is(public.registrar_abono(current_setting('prueba.juan')::uuid, 5, 'EFECTIVO', 'eeeeeeee-0000-0000-0000-000000000001')
    -> 'data' ->> 'repetido', 'true',
  'F7. El mismo abono reenviado no se cobra dos veces');

select is(public.registrar_abono(current_setting('prueba.juan')::uuid, 6, 'EFECTIVO', gen_random_uuid())
    -> 'error' ->> 'mensaje', 'El abono supera lo que debe el cliente',
  'F8. No se abona más de lo que se debe');

select is(public.ajustar_fiado(current_setting('prueba.juan')::uuid, 1, 'x') -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'F9. El Vendedor no ajusta cuentas de fiado');

select is(public.resumen_caja(null) -> 'data' -> 'caja' ? 'esperado', false,
  'C1. D-032: el Vendedor no ve el efectivo esperado');

reset role;

-- =============================================================================
-- Dueño: fiado, anulaciones y devoluciones
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select is(public.ajustar_fiado(current_setting('prueba.juan')::uuid, 1, 'Recargo por envase') -> 'data' ->> 'saldo', '6.35',
  'F10. El Dueño ajusta la cuenta de Juan: debe $6,35');

select set_config('prueba.v_pedro', pg_temp.venta(1, '[{"medio":"FIADO","monto":3.45}]', current_setting('prueba.pedro'))
  -> 'data' ->> 'venta_id', true);
select isnt(nullif(current_setting('prueba.v_pedro'), ''), null,
  'F11. Fase 4: el Dueño sí puede fiar a un cliente sin fiado autorizado');

select is(public.anular_venta(current_setting('prueba.v_efectivo')::uuid, 'Error de cobro') ->> 'ok', 'true',
  'A1. El Dueño anula la venta en efectivo');

select results_eq(
  $$ select tipo, monto::numeric, automatico from public.caja_movimientos
      where venta_id = current_setting('prueba.v_efectivo')::uuid $$,
  $$ values ('EGRESO'::text, 10.35::numeric, true) $$,
  'A2. El efectivo de la venta anulada sale de la caja (egreso automático)');

select public.anular_venta(current_setting('prueba.v_pedro')::uuid, 'Se arrepintió');
select is((select sum(monto) from public.fiado_movimientos where cliente_id = current_setting('prueba.pedro')::uuid),
  0::numeric,
  'A3. Anular una venta al fiado deja la cuenta de Pedro en cero');

select set_config('prueba.linea_mixta', (select id::text from public.venta_detalles
  where venta_id = current_setting('prueba.v_mixta')::uuid), true);
select is(public.registrar_devolucion(current_setting('prueba.v_mixta')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id', current_setting('prueba.linea_mixta'), 'cantidad', 1)),
    'Botella abierta', 'EFECTIVO', gen_random_uuid()) -> 'data' ->> 'total', '3.45',
  'A4. Devolución de 1 aceite en efectivo: $3,45');

select results_eq(
  $$ select m.monto::numeric, d.caja_id::text from public.caja_movimientos m
       join public.devoluciones d on d.id = m.devolucion_id
      where d.venta_id = current_setting('prueba.v_mixta')::uuid $$,
  $$ values (3.45::numeric, current_setting('prueba.caja')) $$,
  'A5. El efectivo devuelto sale de la caja abierta');

select set_config('prueba.linea_fiado', (select id::text from public.venta_detalles
  where venta_id = current_setting('prueba.v_fiado')::uuid), true);
select is(public.registrar_devolucion(current_setting('prueba.v_fiado')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id', current_setting('prueba.linea_fiado'), 'cantidad', 1)),
    'Vencido', 'ABONO_FIADO', gen_random_uuid()) ->> 'ok', 'true',
  'A6. Devolución de una venta al fiado como abono a la cuenta');

select is((select sum(monto) from public.fiado_movimientos where cliente_id = current_setting('prueba.juan')::uuid),
  2.90::numeric,
  'A7. Juan pasa a deber $6,35 − $3,45 = $2,90');

select is(public.registrar_devolucion(current_setting('prueba.v_fiado')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id', current_setting('prueba.linea_fiado'), 'cantidad', 2)),
    'Vencido', 'ABONO_FIADO', gen_random_uuid()) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'A8. Un reintegro como abono no supera lo que se debe');

-- =============================================================================
-- Cierre (HU-04)
-- =============================================================================
-- Esperado: fondo 20 + ventas en efectivo 15,35 (10,35 + 5) + abonos 5
--           + ingresos 1 − egresos 16,80 (3 + 10,35 + 3,45) = 24,55
select results_eq(
  $$ select c ->> 'fondo_inicial', c ->> 'ventas_efectivo', c ->> 'abonos_efectivo',
            c ->> 'ingresos', c ->> 'egresos', c ->> 'esperado'
       from (select public.resumen_caja(null) -> 'data' -> 'caja' c) x $$,
  $$ values ('20.00', '15.35', '5.00', '1.00', '16.80', '24.55') $$,
  'C2. HU-04: fondo + ventas en efectivo + abonos + ingresos − egresos = $24,55');

reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);

select results_eq(
  $$ select r ->> 'ok', r -> 'data' ? 'diferencia'
       from (select public.cerrar_caja(24, 'Faltan monedas') r) x $$,
  $$ values ('true', false) $$,
  'C3. El Vendedor cierra contando $24 y no recibe la diferencia');

select throws_ok($$ select monto_esperado from public.cajas $$, '42501', null,
  'C4. El Vendedor no lee el esperado de la caja');

select is(public.cerrar_caja(24, null) -> 'error' ->> 'codigo', 'CAJA_CERRADA',
  'C5. Una caja cerrada no se vuelve a cerrar');

select is(pg_temp.venta(1, null) -> 'error' ->> 'codigo', 'CAJA_CERRADA',
  'C6. HU-04: con la caja cerrada no se vende en efectivo');

select is(public.explicar_diferencia_caja(current_setting('prueba.caja')::uuid, 'x') -> 'error' ->> 'codigo',
  'SIN_PERMISO',
  'C7. El Vendedor no explica la diferencia');

reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select results_eq(
  $$ select c ->> 'esperado', c ->> 'monto_contado', c ->> 'diferencia'
       from (select public.resumen_caja(current_setting('prueba.caja')::uuid) -> 'data' -> 'caja' c) x $$,
  $$ values ('24.55', '24.00', '-0.55') $$,
  'C8. HU-04: el Dueño ve que faltan $0,55');

select is(public.explicar_diferencia_caja(current_setting('prueba.caja')::uuid, 'Vuelto mal dado') ->> 'ok', 'true',
  'C9. El Dueño explica la diferencia');

select is(public.explicar_diferencia_caja(current_setting('prueba.caja')::uuid, 'Otra') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS',
  'C10. La explicación no se reemplaza');

select is(public.registrar_abono(current_setting('prueba.juan')::uuid, 1, 'EFECTIVO', gen_random_uuid())
    -> 'error' ->> 'codigo', 'CAJA_CERRADA',
  'C11. Sin caja abierta no se recibe un abono en efectivo');

select is(public.registrar_abono(current_setting('prueba.juan')::uuid, 1, 'TRANSFERENCIA', gen_random_uuid())
    -> 'data' ->> 'saldo', '1.90',
  'C12. Un abono por transferencia no necesita caja');

select isnt(nullif(public.abrir_caja(0) -> 'data' ->> 'caja_id', ''), null,
  'C13. Después de cerrar se puede abrir una caja nueva');

reset role;

-- =============================================================================
-- Inmutabilidad (como servidor)
-- =============================================================================
select throws_ok(
  $$ update public.cajas set monto_contado = 30 where id = current_setting('prueba.caja')::uuid $$,
  'P0001', null,
  'I1. Una caja cerrada no se modifica ni con privilegios de servidor');

select throws_ok(
  $$ update public.cajas set cerrada_en = null, cerrada_por = null, monto_contado = null,
            monto_esperado = null, diferencia = null where id = current_setting('prueba.caja')::uuid $$,
  'P0001', null,
  'I2. Una caja cerrada no se reabre');

select throws_ok($$ delete from public.cajas $$, 'P0001', null, 'I3. Una caja no se borra');

select throws_ok($$ update public.caja_movimientos set monto = 1 $$, 'P0001', null,
  'I4. Los movimientos de caja no se editan');

select throws_ok($$ delete from public.fiado_movimientos $$, 'P0001', null,
  'I5. La cuenta de fiado no se borra');

select is_empty(
  $$ select x.producto_id
       from public.existencias x
       left join (select producto_id, sum(cantidad) c, sum(valor) v
                    from public.movimientos_inventario group by producto_id) m
         on m.producto_id = x.producto_id
      where x.cantidad <> coalesce(m.c, 0) or x.valor_total <> coalesce(m.v, 0) $$,
  'I6. Existencias sigue coincidiendo con el libro');

-- =============================================================================
-- Dueño de B y visitante
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);

select is(public.resumen_caja(null) -> 'data' -> 'caja', 'null'::jsonb,
  'B1. El Dueño de B no ve la caja de A');

select is(jsonb_array_length(public.cuentas_fiado() -> 'data' -> 'clientes'), 0,
  'B2. El Dueño de B no ve las cuentas de fiado de A');

select is(public.registrar_abono(current_setting('prueba.juan')::uuid, 1, 'TRANSFERENCIA', gen_random_uuid())
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'B3. El Dueño de B no cobra abonos de clientes de A');

reset role;

set local role anon;
select set_config('request.jwt.claims', '', true);
select throws_ok($$ select public.abrir_caja(0) $$, '42501', null,
  'N1. Visitante sin sesión no abre caja');
reset role;

select * from finish();
rollback;
