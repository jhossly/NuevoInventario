-- =============================================================================
-- Pruebas de la calculadora de compra «¿Cuánto gano?» (D-065)
--   * totales, utilidad, costo anterior y precio sugerido
--   * no guarda nada
--   * producto sin precio; margen fuera de rango; permisos
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(10);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a001', 'dueno.a@prueba.test'),
  ('00000000-0000-0000-0000-00000000a002', 'vendedor.a@prueba.test');

insert into public.empresas (id, ruc, razon_social) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '0900000000001', 'Bodega A');

insert into public.perfiles (id, nombre) values
  ('00000000-0000-0000-0000-00000000a001', 'Dueño A'),
  ('00000000-0000-0000-0000-00000000a002', 'Vendedor A');

insert into public.membresias (empresa_id, usuario_id, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a001', 'DUENO'),
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a002', 'VENDEDOR');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

-- Aceite con IVA 15 %, precio $3,45 con IVA → $3,00 de venta.
select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite","tarifa_iva":15,"precio_venta":3.45}') -> 'data' ->> 'id', true);
select set_config('prueba.aceite_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid and factor = 1), true);
select set_config('prueba.sal', public.guardar_producto(null,
  '{"nombre":"Sal","tarifa_iva":0}') -> 'data' ->> 'id', true);
select set_config('prueba.sal_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.sal')::uuid and factor = 1), true);

-- Compra anterior: 10 aceites a $2 + IVA → $2,30 cada uno.
select public.registrar_compra(null, false, null, null,
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'),
                                       'cantidad', 10, 'costo_unitario', 2)),
  'cccccccc-0000-0000-0000-000000000001');

-- Simulación: 10 aceites a $2,10 + 15 % → $2,415 c/u; venta $30; utilidad $5,85.
select set_config('prueba.r', public.simular_compra(jsonb_build_array(
    jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'),
                       'cantidad', 10, 'costo_unitario', 2.10, 'tarifa_iva', 15),
    jsonb_build_object('presentacion_id', current_setting('prueba.sal_u'),
                       'cantidad', 5, 'costo_unitario', 0.40)), 0.20)::text, true);

select is(current_setting('prueba.r')::jsonb -> 'data' -> 'compra' ->> 'total', '26.15',
  'S1. Total de la compra simulada: 21 + 3,15 de IVA + 2 de sal');

select is(current_setting('prueba.r')::jsonb -> 'data' ->> 'utilidad', '5.85',
  'S2. Utilidad solo de las líneas con precio');

select is((current_setting('prueba.r')::jsonb -> 'data' ->> 'sin_precio')::int, 1,
  'S3. La sal sin precio se avisa y no suma');

select is(current_setting('prueba.r')::jsonb -> 'data' -> 'detalle' -> 0 ->> 'costo_anterior', '2.3000',
  'S4. Costo por unidad en la última compra');

select is(current_setting('prueba.r')::jsonb -> 'data' -> 'detalle' -> 0 ->> 'costo_unidad', '2.4150',
  'S5. Costo por unidad en esta compra, con IVA');

-- 2,415 / 0,80 × 1,15 = 3,4716 → $3,48
select is(current_setting('prueba.r')::jsonb -> 'data' -> 'detalle' -> 0 ->> 'precio_sugerido', '3.48',
  'S6. Precio para ganar 20 %, con IVA y redondeado hacia arriba');

select is(current_setting('prueba.r')::jsonb -> 'data' -> 'detalle' -> 1 ->> 'costo_anterior', null,
  'S7. Sin compras anteriores no hay costo anterior');

select is((select count(*)::int from public.compras), 1,
  'S8. Simular no registra ninguna compra');

select is(public.simular_compra(jsonb_build_array(
    jsonb_build_object('presentacion_id', current_setting('prueba.sal_u'), 'cantidad', 1, 'costo_unitario', 1)), 0.95)
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'S9. Un margen fuera de rango se rechaza');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.simular_compra(jsonb_build_array(
    jsonb_build_object('presentacion_id', current_setting('prueba.sal_u'), 'cantidad', 1, 'costo_unitario', 1)), 0.20)
    -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'S10. El Vendedor no ve costos ni utilidades');

select * from finish();
rollback;
