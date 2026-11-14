-- =============================================================================
-- Pruebas de «¿Cuánto gano?» con productos que todavía no existen (D-066)
--   * cuentas de un producto nuevo por bulto, mezclado con uno existente
--   * sin precio; precio sugerido; errores con la línea; no crea nada
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(9);

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

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite","tarifa_iva":15,"precio_venta":3.45}') -> 'data' ->> 'id', true);
select set_config('prueba.aceite_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid and factor = 1), true);
select set_config('prueba.productos', (select count(*)::text from public.productos), true);

-- Nuevo va primero en el arreglo y responde en ese orden (D-068).
-- Galletas X: 2 bultos de 12 a $6 + 15 % → $13,80; $0,575 c/u.
-- Precio $0,75 con IVA → $0,6522 sin IVA × 24 = $15,65; utilidad $1,85.
-- Aceite: 10 × $2,10 + 15 % = $24,15; venta $30; utilidad $5,85.
select set_config('prueba.r', public.simular_compra(jsonb_build_array(
    jsonb_build_object('nuevo', jsonb_build_object('nombre', 'Galletas X', 'factor', '12', 'precio_venta', '0.75'),
                       'cantidad', '2', 'costo_unitario', '6', 'tarifa_iva', '15'),
    jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'),
                       'cantidad', 10, 'costo_unitario', 2.10, 'tarifa_iva', 15)), 0.20)::text, true);

select is(current_setting('prueba.r')::jsonb -> 'data' -> 'compra' ->> 'total', '37.95',
  'N1. El total suma el producto nuevo y el existente');

select is(current_setting('prueba.r')::jsonb -> 'data' -> 'lineas' -> 0 ->> 'nombre', 'Galletas X',
  'N2. Las líneas responden en el orden enviado, con su nombre');

select is(current_setting('prueba.r')::jsonb -> 'data' -> 'lineas' -> 0 ->> 'utilidad', '1.85',
  'N3. Utilidad del nuevo con el precio que se piensa poner');

select is(current_setting('prueba.r')::jsonb -> 'data' ->> 'utilidad', '7.70',
  'N4. Utilidad total de la compra');

-- 0,575 / 0,80 × 1,15 = 0,8266 → $0,83
select is(current_setting('prueba.r')::jsonb -> 'data' -> 'detalle' -> 0 ->> 'precio_sugerido', '0.83',
  'N5. Precio sugerido por unidad para el margen pedido');

select is((current_setting('prueba.r')::jsonb -> 'data' -> 'detalle' -> 0 ->> 'costo_anterior'), null,
  'N6. Un producto nuevo no tiene costo anterior');

select is((public.simular_compra(jsonb_build_array(
    jsonb_build_object('nuevo', jsonb_build_object('nombre', 'Chifles', 'factor', '10'),
                       'cantidad', '1', 'costo_unitario', '3')), 0.20) -> 'data' ->> 'sin_precio')::int, 1,
  'N7. Sin precio de venta se avisa y no suma');

select is(public.simular_compra(jsonb_build_array(
    jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1, 'costo_unitario', 1),
    jsonb_build_object('nuevo', jsonb_build_object('nombre', '  ', 'factor', '10'),
                       'cantidad', '1', 'costo_unitario', '3')), 0.20) -> 'error' -> 'detalle' ->> 'linea', '2',
  'N8. Sin nombre se rechaza e indica la línea');

select is((select count(*)::text from public.productos), current_setting('prueba.productos'),
  'N9. Simular no crea productos');

select * from finish();
rollback;
