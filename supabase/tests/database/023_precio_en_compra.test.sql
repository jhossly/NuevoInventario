-- =============================================================================
-- Pruebas del precio pensado para productos que ya existen (D-069)
--   * simular usa el precio escrito en vez del de hoy
--   * registrar lo pone en la presentación vendible más pequeña, para todo el stock
--   * sin precio no cambia nada; si la compra falla, el precio no cambia
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(7);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a001', 'dueno.a@prueba.test');
insert into public.empresas (id, ruc, razon_social) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '0900000000001', 'Bodega A');
insert into public.perfiles (id, nombre) values
  ('00000000-0000-0000-0000-00000000a001', 'Dueño A');
insert into public.membresias (empresa_id, usuario_id, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a001', 'DUENO');
insert into public.iva_ventas_periodos (empresa_id, desde, iva_cero)
values ('aaaaaaaa-0000-0000-0000-000000000000', current_date - 1, true);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

-- Chicle a $0,25 con 5 en stock.
select set_config('prueba.chicle', public.guardar_producto(null,
  '{"nombre":"Chicle","tarifa_iva":0,"precio_venta":0.25}') -> 'data' ->> 'id', true);
select public.ajustar_inventario(current_setting('prueba.chicle')::uuid, 'APERTURA', 5, 0.15);

-- 10 chicles a $0,20 c/u: a $0,30 serían $3,00 de venta y $1,00 de ganancia.
select set_config('prueba.lineas', jsonb_build_array(jsonb_build_object(
  'producto_id', current_setting('prueba.chicle'), 'factor', '10', 'cantidad', '1',
  'costo_unitario', '2', 'tarifa_iva', '0', 'precio_venta', '0.30'))::text, true);

select is(public.simular_compra(current_setting('prueba.lineas')::jsonb, 0.20) -> 'data' -> 'detalle' -> 0 ->> 'venta_total',
  '3.00', 'P1. La simulación vende al precio escrito');
select is(public.simular_compra(current_setting('prueba.lineas')::jsonb, 0.20) -> 'data' -> 'detalle' -> 0 ->> 'precio_actual',
  '0.25', 'P2. Y sigue mostrando el precio de hoy para comparar');
select is((select precio_venta::text from public.presentaciones
            where producto_id = current_setting('prueba.chicle')::uuid and factor = 1), '0.25',
  'P3. Simular no cambia el precio');

-- Si la compra no entra, el precio no cambia.
select is(public.registrar_compra_con_nuevos(null, true, null, null,
  current_setting('prueba.lineas')::jsonb, 'cccccccc-0000-0000-0000-000000000001') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS', 'P4. Una compra con respaldo sin documento se rechaza');
select is((select precio_venta::text from public.presentaciones
            where producto_id = current_setting('prueba.chicle')::uuid and factor = 1), '0.25',
  'P5. Y el precio sigue igual');

select is((public.registrar_compra_con_nuevos(null, false, null, null,
  current_setting('prueba.lineas')::jsonb, 'cccccccc-0000-0000-0000-000000000002') -> 'data' ->> 'precios')::int, 1,
  'P6. Registrar avisa que cambió un precio');
select is((select precio_venta::text from public.presentaciones
            where producto_id = current_setting('prueba.chicle')::uuid and factor = 1), '0.30',
  'P7. El chicle ahora se vende a $0,30, también los 5 que había');

select * from finish();
rollback;
