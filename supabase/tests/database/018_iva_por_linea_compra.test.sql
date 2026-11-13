-- =============================================================================
-- Pruebas de IVA elegido por línea en la compra a mano (D-064)
--   * producto con 0 % comprado con 15 %: IVA, total y costo con IVA
--   * se guarda la tarifa de la compra; la del producto no cambia
--   * sin tarifa, la del producto; 0 % sobre un producto con 15 %
--   * tarifa inexistente
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(8);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a001', 'dueno.a@prueba.test');

insert into public.empresas (id, ruc, razon_social) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '0900000000001', 'Bodega A');

insert into public.perfiles (id, nombre) values
  ('00000000-0000-0000-0000-00000000a001', 'Dueño A');

insert into public.membresias (empresa_id, usuario_id, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a001', 'DUENO');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.galletas', public.guardar_producto(null,
  '{"nombre":"Galletas","tarifa_iva":0}') -> 'data' ->> 'id', true);
select set_config('prueba.caja10', public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.galletas'), 'nombre', 'Caja 10', 'factor', 10)) -> 'data' ->> 'id', true);
select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite","tarifa_iva":15}') -> 'data' ->> 'id', true);
select set_config('prueba.aceite_base', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid and factor = 1), true);

select set_config('prueba.prov', public.guardar_proveedor(null,
  '{"tipo_identificacion":"RUC","identificacion":"1790000000001","nombre":"Distribuidora"}')
  -> 'data' ->> 'id', true);

-- Galletas (0 %) compradas con 15 %: 2 cajas a $10 → base 20, IVA 3, costo 23 / 20 u.
select is(public.calcular_compra(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.caja10'), 'cantidad', 2,
    'costo_unitario', 10, 'tarifa_iva', 15))) -> 'data' ->> 'total', '23.00',
  'I1. La vista previa suma el 15 % aunque el producto tenga 0 %');

select set_config('prueba.compra', public.registrar_compra(
  current_setting('prueba.prov')::uuid, true, '001-001-000000001', null,
  jsonb_build_array(
    jsonb_build_object('presentacion_id', current_setting('prueba.caja10'), 'cantidad', 2,
                       'costo_unitario', 10, 'tarifa_iva', 15),
    jsonb_build_object('presentacion_id', current_setting('prueba.aceite_base'), 'cantidad', 4,
                       'costo_unitario', 2, 'tarifa_iva', 0),
    jsonb_build_object('presentacion_id', current_setting('prueba.aceite_base'), 'cantidad', 1,
                       'costo_unitario', 2)),
  'cccccccc-0000-0000-0000-000000000001') -> 'data' ->> 'compra_id', true);

select isnt(nullif(current_setting('prueba.compra'), ''), null,
  'I2. Se registra la compra con tarifas elegidas');

select results_eq(
  $$ select orden, tarifa_iva::numeric, iva::numeric
       from public.compra_detalles where compra_id = current_setting('prueba.compra')::uuid
      order by orden $$,
  $$ values (1, 15::numeric, 3.00::numeric), (2, 0::numeric, 0::numeric), (3, 15::numeric, 0.30::numeric) $$,
  'I3. Cada línea guarda la tarifa de la compra; sin tarifa, la del producto');

select is((select costo_unitario_base::numeric from public.compra_detalles
            where compra_id = current_setting('prueba.compra')::uuid and orden = 1),
  1.15::numeric,
  'I4. El IVA pagado entra al costo de la galleta');

select is((select tarifa_iva::numeric from public.productos
            where id = current_setting('prueba.galletas')::uuid),
  0::numeric,
  'I5. La tarifa del producto sigue en 0 %');

select is((select total::numeric from public.compras where id = current_setting('prueba.compra')::uuid),
  33.30::numeric,
  'I6. El total de la compra suma el IVA elegido (20 + 3 + 8 + 2 + 0,30)');

select is(public.calcular_compra(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.caja10'), 'cantidad', 1,
    'costo_unitario', 10, 'tarifa_iva', 7))) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'I7. Una tarifa que no existe se rechaza');

select is(public.calcular_compra(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.caja10'), 'cantidad', 1,
    'costo_unitario', 10, 'tarifa_iva', 'quince'))) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'I8. Una tarifa mal escrita se rechaza');

select * from finish();
rollback;
