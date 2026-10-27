-- =============================================================================
-- Pruebas de reportes y exportación (Fase 10)
--   * margen por producto: aceite de la Fase 3 (18,2 % / 22,2 %) y galleta de
--     la HU-05 (24 % / 31,6 %); anuladas fuera, devoluciones restadas
--   * resumen de ventas, acumulado RIMPE, exportación para el contador
--   * solo el Dueño, solo su empresa
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(26);

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

-- Período de prueba: hoy, con un día de margen por la zona horaria.
select set_config('prueba.desde', (current_date - 1)::text, false);
select set_config('prueba.hasta', (current_date + 1)::text, false);
select set_config('prueba.anio', extract(year from now() at time zone 'America/Guayaquil')::int::text, false);

-- =============================================================================
-- Datos: aceite como en la Fase 3 (promedio $2,455294) y galleta de la HU-05
-- (precio $0,75 sin IVA, costo $0,57)
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite 1 L","tarifa_iva":15,"precio_venta":3.45}') -> 'data' ->> 'id', true);
select set_config('prueba.aceite_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid), true);
select set_config('prueba.galleta', public.guardar_producto(null,
  '{"nombre":"Galleta","tarifa_iva":0,"precio_venta":0.75}') -> 'data' ->> 'id', true);
select set_config('prueba.galleta_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.galleta')::uuid), true);
select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 10, 2);
select public.ajustar_inventario(current_setting('prueba.galleta')::uuid, 'APERTURA', 10, 0.57);
select set_config('prueba.prov', public.guardar_proveedor(null,
  '{"tipo_identificacion":"RUC","identificacion":"1790000000001","nombre":"Distribuidora"}') -> 'data' ->> 'id', true);
select public.abrir_caja(0);
reset role;
select privado.registrar_movimiento('aaaaaaaa-0000-0000-0000-000000000000',
  current_setting('prueba.aceite')::uuid, 'COMPRA', 24, 2.645);
set local role authenticated;

create function pg_temp.vender(presentacion text, n numeric)
returns uuid language sql as $$
  select (public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', presentacion, 'cantidad', n)),
    null, null, null, gen_random_uuid()) -> 'data' ->> 'venta_id')::uuid
$$;

-- V1: 3 aceites ($9,00 + IVA $1,35). V2: 4 galletas ($3,00). V3: 1 aceite,
-- anulada. V4: 1 galleta, devuelta completa.
select set_config('prueba.v1', pg_temp.vender(current_setting('prueba.aceite_u'), 3)::text, true);
select set_config('prueba.v2', pg_temp.vender(current_setting('prueba.galleta_u'), 4)::text, true);
select set_config('prueba.v3', pg_temp.vender(current_setting('prueba.aceite_u'), 1)::text, true);
select public.anular_venta(current_setting('prueba.v3')::uuid, 'Error');
select set_config('prueba.v4', pg_temp.vender(current_setting('prueba.galleta_u'), 1)::text, true);
select public.registrar_devolucion(current_setting('prueba.v4')::uuid,
  jsonb_build_array(jsonb_build_object('venta_detalle_id',
    (select id from public.venta_detalles where venta_id = current_setting('prueba.v4')::uuid), 'cantidad', 1)),
  'Rota', 'EFECTIVO', gen_random_uuid());

-- Compras: una con respaldo ($2,00 + IVA $0,30) y otra anulada.
select public.registrar_compra(current_setting('prueba.prov')::uuid, true, '001-001-000000001', null,
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'),
                                       'cantidad', 1, 'costo_unitario', 2)), gen_random_uuid());
select public.anular_compra((public.registrar_compra(null, false, null, null,
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.galleta_u'),
                                       'cantidad', 1, 'costo_unitario', 0.5)), gen_random_uuid())
  -> 'data' ->> 'compra_id')::uuid, 'Duplicada');

-- =============================================================================
-- Margen por producto (HU-05)
-- =============================================================================
create function pg_temp.margen(producto text)
returns jsonb language sql as $$
  select p from jsonb_array_elements(public.reporte_margen(
    current_setting('prueba.desde')::date, current_setting('prueba.hasta')::date) -> 'data' -> 'productos') p
   where p ->> 'producto_id' = producto
$$;

select results_eq(
  $$ select m ->> 'cantidad', m ->> 'ventas', m ->> 'costo', m ->> 'utilidad', m ->> 'margen', m ->> 'recargo'
       from (select pg_temp.margen(current_setting('prueba.aceite')) m) x $$,
  $$ values ('3.000', '9.00', '7.37', '1.63', '0.1816', '0.2218') $$,
  'M1. Fase 3: aceite con 18,2 % de margen y 22,2 % de recargo; la venta anulada no cuenta');

select results_eq(
  $$ select m ->> 'cantidad', m ->> 'ventas', m ->> 'costo', m ->> 'margen', m ->> 'recargo'
       from (select pg_temp.margen(current_setting('prueba.galleta')) m) x $$,
  $$ values ('4.000', '3.00', '2.28', '0.2400', '0.3158') $$,
  'M2. HU-05: $0,75 sobre $0,57 = 24 % de margen y 31,6 % de recargo; la galleta devuelta no cuenta');

select is(public.reporte_margen(current_setting('prueba.desde')::date, current_setting('prueba.hasta')::date)
    -> 'data' -> 'productos' -> 0 ->> 'nombre', 'Aceite 1 L',
  'M3. Los productos salen ordenados por utilidad');

-- =============================================================================
-- Resumen de ventas
-- =============================================================================
create function pg_temp.resumen()
returns jsonb language sql as $$
  select public.reporte_ventas(current_setting('prueba.desde')::date, current_setting('prueba.hasta')::date) -> 'data'
$$;

select results_eq(
  $$ select r -> 'totales' ->> 'ventas', r -> 'totales' ->> 'anuladas', r -> 'totales' ->> 'base',
            r -> 'totales' ->> 'iva', r -> 'totales' ->> 'total', r -> 'totales' ->> 'utilidad'
       from (select pg_temp.resumen() r) x $$,
  $$ values ('3', '1', '12.00', '1.35', '13.35', '2.35') $$,
  'R1. Ventas netas: $12,00 sin IVA + $1,35 de IVA; utilidad $2,35');

select is(pg_temp.resumen() -> 'totales' ->> 'margen', '0.1962',
  'R1b. Margen del período: $2,354118 ÷ $12,00 = 19,6 %');

select is(pg_temp.resumen() -> 'por_medio' ->> 'EFECTIVO', '14.10',
  'R2. Cobrado en efectivo: $10,35 + $3,00 + $0,75 (la anulada no)');

select is(pg_temp.resumen() ->> 'devoluciones', '0.75',
  'R3. Devoluciones del período: $0,75');

select is(public.reporte_ventas(current_date, current_date - 1) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R4. El período no puede estar invertido');

select is(public.reporte_margen(current_date - 400, current_date) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R5. El período no pasa de un año');

-- =============================================================================
-- RIMPE
-- =============================================================================
select results_eq(
  $$ select r ->> 'acumulado', r ->> 'limite', r ->> 'porcentaje', r ->> 'disponible'
       from (select public.acumulado_rimpe(current_setting('prueba.anio')::int) -> 'data' r) x $$,
  $$ values ('12.00', '20000.00', '0.0006', '19988.00') $$,
  'A1. Acumulado del año: $12,00 de $20.000 (0,06 %)');

select is(jsonb_array_length(public.acumulado_rimpe(current_setting('prueba.anio')::int) -> 'data' -> 'por_mes'), 12,
  'A2. El acumulado trae los 12 meses');

select is((select sum((m ->> 'base')::numeric)
             from jsonb_array_elements(public.acumulado_rimpe(current_setting('prueba.anio')::int) -> 'data' -> 'por_mes') m),
  12.00::numeric,
  'A3. Los meses suman el acumulado');

reset role;
update public.empresas set limite_ingresos_rimpe = 1000 where id = 'aaaaaaaa-0000-0000-0000-000000000000';
set local role authenticated;

select is(public.acumulado_rimpe(current_setting('prueba.anio')::int) -> 'data' ->> 'porcentaje', '0.0120',
  'A4. El límite es configurable: $12 de $1.000 = 1,2 %');

-- =============================================================================
-- Exportación para el contador
-- =============================================================================
create function pg_temp.exportacion()
returns jsonb language sql as $$
  select public.exportacion_contador(current_setting('prueba.desde')::date, current_setting('prueba.hasta')::date) -> 'data'
$$;

select results_eq(
  $$ select jsonb_array_length(e -> 'ventas'), jsonb_array_length(e -> 'devoluciones'), jsonb_array_length(e -> 'compras')
       from (select pg_temp.exportacion() e) x $$,
  $$ values (4, 1, 2) $$,
  'E1. Se exportan todos los documentos, también los anulados');

select results_eq(
  $$ select v ->> 'base_0', v ->> 'base_gravada', v ->> 'iva', v ->> 'total', v ->> 'cliente', v ->> 'estado'
       from jsonb_array_elements(pg_temp.exportacion() -> 'ventas') v
      where v ->> 'venta' = left(current_setting('prueba.v1'), 8) $$,
  $$ values ('0.00', '9.00', '1.35', '10.35', 'Consumidor final', 'CONFIRMADA') $$,
  'E2. La venta del aceite: base gravada $9,00 e IVA $1,35');

select is((select v ->> 'estado' from jsonb_array_elements(pg_temp.exportacion() -> 'ventas') v
            where v ->> 'venta' = left(current_setting('prueba.v3'), 8)), 'ANULADA',
  'E3. La venta anulada aparece marcada');

select results_eq(
  $$ select r ->> 'ventas_base_0', r ->> 'ventas_base_gravada', r ->> 'ventas_iva',
            r ->> 'devoluciones_base_0', r ->> 'compras_base_gravada', r ->> 'compras_iva'
       from (select pg_temp.exportacion() -> 'resumen' r) x $$,
  $$ values ('3.75', '9.00', '1.35', '0.75', '2.00', '0.30') $$,
  'E4. Resumen de IVA: ventas, devoluciones y compras confirmadas');

select is((select c ->> 'identificacion' from jsonb_array_elements(pg_temp.exportacion() -> 'compras') c
            where c ->> 'estado' = 'CONFIRMADA'), '1790000000001',
  'E5. La compra exporta el RUC del proveedor');

reset role;

-- =============================================================================
-- Vendedor, Dueño de B y visitante
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);

select is(public.reporte_margen(current_date, current_date) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V1. El Vendedor no ve el margen');
select is(public.reporte_ventas(current_date, current_date) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V2. El Vendedor no ve el resumen de ventas');
select is(public.acumulado_rimpe(2026) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V3. El Vendedor no ve el acumulado RIMPE');
select is(public.exportacion_contador(current_date, current_date) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V4. El Vendedor no exporta para el contador');

reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);

select is(jsonb_array_length(public.reporte_margen(current_setting('prueba.desde')::date, current_setting('prueba.hasta')::date)
    -> 'data' -> 'productos'), 0,
  'B1. El Dueño de B no ve el margen de A');
select is(jsonb_array_length(public.exportacion_contador(current_setting('prueba.desde')::date, current_setting('prueba.hasta')::date)
    -> 'data' -> 'ventas'), 0,
  'B2. El Dueño de B no exporta ventas de A');
select is(public.acumulado_rimpe(current_setting('prueba.anio')::int) -> 'data' ->> 'acumulado', '0.00',
  'B3. El acumulado de B no suma ventas de A');

reset role;
set local role anon;
select set_config('request.jwt.claims', '', true);
select throws_ok($$ select public.exportacion_contador(current_date, current_date) $$, '42501', null,
  'N1. Visitante sin sesión no exporta');
reset role;

select * from finish();
rollback;
