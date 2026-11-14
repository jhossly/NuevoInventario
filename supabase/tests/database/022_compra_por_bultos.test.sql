-- =============================================================================
-- Pruebas de compras por bultos (D-068)
--   * simular: producto existente por producto_id y factor, nuevo, en su orden,
--     con unidades, costo y venta por línea
--   * registrar: usa la presentación con ese contenido o crea «Caja N»
--   * mismas cuentas al simular y al registrar
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(10);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a001', 'dueno.a@prueba.test');
insert into public.empresas (id, ruc, razon_social) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '0900000000001', 'Bodega A');
insert into public.perfiles (id, nombre) values
  ('00000000-0000-0000-0000-00000000a001', 'Dueño A');
insert into public.membresias (empresa_id, usuario_id, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a001', 'DUENO');

-- Vende todo con IVA 0 % desde hoy: el precio completo es venta.
insert into public.iva_ventas_periodos (empresa_id, desde, iva_cero)
values ('aaaaaaaa-0000-0000-0000-000000000000', current_date - 1, true);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.chicle', public.guardar_producto(null,
  '{"nombre":"Chicle Loka Kola","tarifa_iva":15,"precio_venta":0.25}') -> 'data' ->> 'id', true);

-- Línea 1: chupete nuevo, 2 fundas de 24 a $1,791304 + 15 %, se vendería a $0,15.
-- Línea 2: chicle existente, 1 display de 20 a $3,095652 + 15 %.
select set_config('prueba.lineas', jsonb_build_array(
    jsonb_build_object('nuevo', jsonb_build_object('nombre', 'Plop chupete', 'factor', '24', 'precio_venta', '0.15'),
                       'cantidad', '2', 'costo_unitario', '1.791304', 'tarifa_iva', '15'),
    jsonb_build_object('producto_id', current_setting('prueba.chicle'), 'factor', '20',
                       'cantidad', '1', 'costo_unitario', '3.095652', 'tarifa_iva', '15'))::text, true);

select set_config('prueba.r', public.simular_compra(current_setting('prueba.lineas')::jsonb, 0.20)::text, true);

select is(current_setting('prueba.r')::jsonb ->> 'ok', 'true', 'B1. Se simula con producto_id y factor');

-- 3,58 + 0,54 = 4,12 y 3,10 + 0,47 = 3,57 → 7,69
select is(current_setting('prueba.r')::jsonb -> 'data' -> 'compra' ->> 'total', '7.69',
  'B2. Precios sin IVA a partir de los que traían IVA: el total vuelve a ser el de la factura');

select results_eq(
  $$ select (d ->> 'nuevo')::boolean, d ->> 'unidades', d ->> 'costo_total', d ->> 'venta_total'
       from jsonb_array_elements(current_setting('prueba.r')::jsonb -> 'data' -> 'detalle') d $$,
  $$ values (true, '48.000', '4.12', '7.20'), (false, '20.000', '3.57', '5.00') $$,
  'B3. Por línea, en el orden enviado: unidades, costo y venta');

select is(current_setting('prueba.r')::jsonb -> 'data' -> 'detalle' -> 1 ->> 'precio_unidad', '0.2500',
  'B4. El producto existente usa su precio por unidad de hoy');

select is(current_setting('prueba.r')::jsonb -> 'data' ->> 'utilidad', '4.51',
  'B5. Utilidad: 7,20 + 5,00 − 4,12 − 3,57');

select set_config('prueba.c', public.registrar_compra_con_nuevos(null, false, null, null,
  current_setting('prueba.lineas')::jsonb, 'cccccccc-0000-0000-0000-000000000001')::text, true);

select is(current_setting('prueba.c')::jsonb ->> 'ok', 'true', 'B6. Se registra con producto_id y factor');

select is((select total::text from public.compras where id = (current_setting('prueba.c')::jsonb -> 'data' ->> 'compra_id')::uuid),
  '7.69', 'B7. Registrar da el mismo total que simular');

select results_eq(
  $$ select r.nombre, r.se_vende, r.se_compra from public.presentaciones r
      where r.producto_id = current_setting('prueba.chicle')::uuid order by r.factor $$,
  $$ values ('Unidad'::text, true, true), ('Caja 20'::text, false, true) $$,
  'B8. Al chicle se le crea «Caja 20» para comprar');

select is((select cantidad::numeric from public.existencias where producto_id = current_setting('prueba.chicle')::uuid),
  20::numeric, 'B9. Entran 20 chicles');

-- Otra compra con el mismo contenido usa la «Caja 20» que ya hay.
select public.registrar_compra_con_nuevos(null, false, null, null,
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('prueba.chicle'), 'factor', '20',
                                       'cantidad', '1', 'costo_unitario', '3')),
  'cccccccc-0000-0000-0000-000000000002');
select is((select count(*)::int from public.presentaciones where producto_id = current_setting('prueba.chicle')::uuid), 2,
  'B10. No se repite la presentación');

select * from finish();
rollback;
