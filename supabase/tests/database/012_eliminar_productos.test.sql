-- =============================================================================
-- Pruebas de eliminar productos y presentaciones (D-052)
--   * sin historial se elimina todo: producto, presentaciones, existencias y
--     códigos recordados; queda la auditoría
--   * con movimientos o ventas no se elimina
--   * la presentación base se protege; una base repetida sí se elimina
--   * permisos y aislamiento
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(14);

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

select set_config('prueba.nuevo', public.guardar_producto(null,
  '{"nombre":"Prueba","codigo_iva":"0","precio_venta":1,"imagen":"aaaaaaaa-0000-0000-0000-000000000000/f.webp"}') -> 'data' ->> 'id', true);
select set_config('prueba.nuevo_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.nuevo')::uuid), true);
select set_config('prueba.caja', public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.nuevo'), 'nombre', 'Caja 12', 'factor', 12, 'precio_venta', 10)) -> 'data' ->> 'id', true);

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite","codigo_iva":"0","precio_venta":3}') -> 'data' ->> 'id', true);
select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 5, 2);

select set_config('prueba.recarga', public.guardar_producto(null,
  '{"nombre":"Recarga","codigo_iva":"6","precio_venta":1,"controla_stock":false}') -> 'data' ->> 'id', true);
select set_config('prueba.recarga_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.recarga')::uuid), true);
select public.registrar_venta(
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.recarga_u'), 'cantidad', 1)),
  '[{"medio":"TRANSFERENCIA","monto":1}]'::jsonb, null, null, gen_random_uuid());

-- Permisos
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.eliminar_producto(current_setting('prueba.nuevo')::uuid) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'E1. El Vendedor no elimina productos');
select is(public.eliminar_presentacion(current_setting('prueba.caja')::uuid) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'E2. El Vendedor no elimina presentaciones');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);
select is(public.eliminar_producto(current_setting('prueba.nuevo')::uuid) -> 'error' ->> 'mensaje', 'El producto no existe',
  'E3. Otra bodega no elimina productos ajenos');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

-- Presentaciones
select is(public.eliminar_presentacion(current_setting('prueba.nuevo_u')::uuid) -> 'error' ->> 'mensaje',
  'La presentación base no se elimina', 'E4. La presentación base se protege');
select is(public.eliminar_presentacion(current_setting('prueba.recarga_u')::uuid) -> 'error' ->> 'mensaje',
  'La presentación base no se elimina', 'E5. Tampoco la de un producto vendido');
select is(public.eliminar_presentacion(current_setting('prueba.caja')::uuid) ->> 'ok', 'true',
  'E6. Una presentación sin uso se elimina');

select set_config('prueba.repetida', public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.nuevo'), 'nombre', 'unidad', 'factor', 1, 'precio_venta', 0.5)) -> 'data' ->> 'id', true);
select is(public.eliminar_presentacion(current_setting('prueba.repetida')::uuid) ->> 'ok', 'true',
  'E7. Una base repetida se elimina');

-- Productos
select is(public.eliminar_producto(current_setting('prueba.aceite')::uuid) -> 'error' ->> 'mensaje',
  'Este producto ya tiene historial: desactívalo en vez de eliminarlo', 'E8. Con movimientos no se elimina');
select is(public.eliminar_producto(current_setting('prueba.recarga')::uuid) -> 'error' ->> 'mensaje',
  'Este producto ya tiene historial: desactívalo en vez de eliminarlo', 'E9. Con ventas no se elimina, aunque no controle stock');

reset role;
insert into public.codigos_sri (empresa_id, codigo, presentacion_id)
values ('aaaaaaaa-0000-0000-0000-000000000000', 'P-1', current_setting('prueba.nuevo_u')::uuid);
set local role authenticated;

select is(public.eliminar_producto(current_setting('prueba.nuevo')::uuid) -> 'data' ->> 'imagen',
  'aaaaaaaa-0000-0000-0000-000000000000/f.webp', 'E10. Sin historial se elimina y devuelve la imagen a borrar');

select is((select count(*)::int from public.productos where id = current_setting('prueba.nuevo')::uuid), 0,
  'E11. El producto ya no está');
select is((select count(*)::int from public.presentaciones where producto_id = current_setting('prueba.nuevo')::uuid), 0,
  'E12. Sus presentaciones tampoco');

reset role;
select results_eq(
  $$ select (select count(*)::int from public.existencias where producto_id = current_setting('prueba.nuevo')::uuid),
            (select count(*)::int from public.codigos_sri where codigo = 'P-1') $$,
  $$ values (0, 0) $$,
  'E13. Ni su existencia ni su código recordado');
select is((select count(*)::int from public.auditoria where accion = 'PRODUCTO_ELIMINADO'), 1,
  'E14. Queda en la auditoría');

select * from finish();
rollback;
