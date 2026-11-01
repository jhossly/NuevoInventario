-- =============================================================================
-- Pruebas de reportes de compras y resumen por mes (D-055)
--   * totales, por proveedor y por producto; anuladas fuera
--   * resumen de 12 meses: ventas netas, compras y facturas sin registrar
--   * período inválido, permisos y aislamiento
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(12);

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

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite","codigo_iva":"4","precio_venta":3.45}') -> 'data' ->> 'id', true);
select set_config('prueba.u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid), true);
select set_config('prueba.p1', public.guardar_proveedor(null,
  '{"tipo_identificacion":"RUC","identificacion":"1790000000001","nombre":"Tesalia"}') -> 'data' ->> 'id', true);
select set_config('prueba.p2', public.guardar_proveedor(null,
  '{"tipo_identificacion":"RUC","identificacion":"1790000000002","nombre":"Arca"}') -> 'data' ->> 'id', true);

create function pg_temp.compra(p_proveedor text, p_doc text, p_fecha date, p_cant numeric)
returns uuid language sql as $$
  select (public.registrar_compra(p_proveedor::uuid, true, p_doc, p_fecha,
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.u'), 'cantidad', p_cant, 'costo_unitario', 2)),
    gen_random_uuid()) -> 'data' ->> 'compra_id')::uuid
$$;
reset role;
grant execute on function pg_temp.compra(text, text, date, numeric) to authenticated;
set local role authenticated;

-- Enero: Tesalia 2 compras ($23 + $11,50). Febrero: Arca $46. Marzo: una anulada.
select pg_temp.compra(current_setting('prueba.p1'), '1-1-1', '2026-01-10', 10);
select pg_temp.compra(current_setting('prueba.p1'), '1-1-2', '2026-01-20', 5);
select pg_temp.compra(current_setting('prueba.p2'), '2-1-1', '2026-02-05', 20);
select public.anular_compra(pg_temp.compra(current_setting('prueba.p2'), '2-1-2', '2026-03-01', 1), 'Error');

select set_config('prueba.r', public.reporte_compras('2026-01-01', '2026-01-31')::text, true);
select results_eq(
  $$ select r -> 'totales' ->> 'compras', r -> 'totales' ->> 'sin_iva', r -> 'totales' ->> 'iva', r -> 'totales' ->> 'total'
       from (select current_setting('prueba.r')::jsonb -> 'data' r) x $$,
  $$ values ('2'::text, '30.00'::text, '4.50'::text, '34.50'::text) $$,
  'C1. Totales de enero');

select results_eq(
  $$ select l ->> 'nombre', l ->> 'compras', l ->> 'total', l ->> 'ultima'
       from jsonb_array_elements(public.reporte_compras('2026-01-01', '2026-02-28') -> 'data' -> 'por_proveedor') l $$,
  $$ values ('Arca'::text, '1'::text, '46.00'::text, '2026-02-05'::text),
            ('Tesalia', '2', '34.50', '2026-01-20') $$,
  'C2. Por proveedor, del mayor al menor');

select results_eq(
  $$ select l ->> 'nombre', (l ->> 'cantidad')::numeric, l ->> 'total'
       from jsonb_array_elements(public.reporte_compras('2026-01-01', '2026-02-28') -> 'data' -> 'por_producto') l $$,
  $$ values ('Aceite'::text, 35::numeric, '80.50'::text) $$,
  'C3. Por producto');

select results_eq(
  $$ select r -> 'totales' ->> 'compras', r -> 'totales' ->> 'anuladas', r -> 'totales' ->> 'total', jsonb_array_length(r -> 'por_proveedor')
       from (select public.reporte_compras('2026-03-01', '2026-03-31') -> 'data' r) x $$,
  $$ values ('0'::text, '1'::text, '0.00'::text, 0) $$,
  'C4. Una compra anulada no suma');

select is(public.reporte_compras('2026-02-01', '2026-01-01') -> 'error' ->> 'mensaje',
  'La fecha inicial es posterior a la final', 'C5. Período inválido');

-- Resumen por mes
select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'AJUSTE', 1, 2, 'x');
select public.registrar_venta(
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.u'), 'cantidad', 2)),
  '[{"medio":"TRANSFERENCIA","monto":6.90}]'::jsonb, null, null, gen_random_uuid());

reset role;
insert into public.comprobantes (empresa_id, clave_acceso, tipo, numero, fecha_emision, ambiente, numero_autorizacion,
                                 subtotal, descuento, iva, total, pagos, xml)
values ('aaaaaaaa-0000-0000-0000-000000000000', repeat('1', 49), '01', '001-100-000000001', '2026-02-14', '2', repeat('1', 49),
        10, 0, 0, 10, '[]', '<x/>');
set local role authenticated;

select set_config('prueba.mes', extract(month from (now() at time zone 'America/Guayaquil'))::int::text, true);
select set_config('prueba.anio', extract(year from (now() at time zone 'America/Guayaquil'))::int::text, true);

select is(jsonb_array_length(public.resumen_mensual(2026) -> 'data' -> 'meses'), 12, 'M1. Siempre doce meses');
select results_eq(
  $$ select m ->> 'compras', m ->> 'num_compras', m ->> 'sin_registrar', m ->> 'num_sin_registrar'
       from jsonb_array_elements(public.resumen_mensual(2026) -> 'data' -> 'meses') m where m ->> 'mes' = '2' $$,
  $$ values ('46.00'::text, '1'::text, '10.00'::text, '1'::text) $$,
  'M2. Febrero: compras y factura de venta sin registrar');
select results_eq(
  $$ select m ->> 'compras', m ->> 'num_compras' from jsonb_array_elements(public.resumen_mensual(2026) -> 'data' -> 'meses') m
      where m ->> 'mes' = '3' $$,
  $$ values ('0.00'::text, '0'::text) $$,
  'M3. Marzo: la anulada no cuenta');
select results_eq(
  $$ select m ->> 'ventas', m ->> 'utilidad' from jsonb_array_elements(public.resumen_mensual(current_setting('prueba.anio')::int) -> 'data' -> 'meses') m
      where m ->> 'mes' = current_setting('prueba.mes') $$,
  $$ values ('6.90'::text, '1.42'::text) $$,
  'M4. El mes actual suma la venta y su utilidad');
select is(public.resumen_mensual(1) -> 'error' ->> 'mensaje', 'El año no es válido', 'M5. Año inválido');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.reporte_compras('2026-01-01', '2026-01-31') -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'S1. El Vendedor no ve las compras');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);
select is(public.reporte_compras('2026-01-01', '2026-02-28') -> 'data' -> 'totales' ->> 'total', '0.00',
  'S2. Otra bodega no ve estas compras');

select * from finish();
rollback;
