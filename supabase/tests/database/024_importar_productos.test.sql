-- =============================================================================
-- Pruebas de importar productos del Excel (D-071)
--   * crea con código, categoría (creada o existente), tarifa y por completar
--   * stock con costo entra como apertura; sin costo o en cero, sin stock
--   * no duplica por código ni por nombre; reimportar no crea nada
--   * una fila con error no deja nada creado; permisos
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(11);

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

-- Ya existen: uno con código y otro solo por nombre.
select public.guardar_producto(null, '{"nombre":"Doritos queso 21g","codigo_principal":"300055191","tarifa_iva":15}');
select public.guardar_producto(null, '{"nombre":"Cheetos queso 21G","tarifa_iva":15}');

select set_config('prueba.filas', jsonb_build_array(
  jsonb_build_object('nombre', 'K chitos natural 67g', 'codigo', '300036732', 'categoria', 'FRITOLAY', 'stock', '7', 'costo', '0.32'),
  jsonb_build_object('nombre', 'Doritos   queso 21G', 'codigo', '300055191', 'categoria', 'FRITOLAY', 'stock', '1', 'costo', '0.30'),
  jsonb_build_object('nombre', 'CHEETOS QUESO 21G', 'codigo', '300035902', 'categoria', 'FRITOLAY', 'stock', '22', 'costo', '0.30'),
  jsonb_build_object('nombre', 'Detodito natural 88g', 'codigo', '300056704', 'categoria', 'fritolay', 'stock', '0'),
  jsonb_build_object('nombre', 'Ruffles natural 40 G', 'codigo', '300057811', 'categoria', 'FRITOLAY', 'stock', '22', 'costo', ''),
  jsonb_build_object('nombre', 'Coca cola 3L', 'categoria', 'COCA-COLA', 'stock', '5', 'costo', '2.10'))::text, true);

select set_config('prueba.r', public.importar_productos(current_setting('prueba.filas')::jsonb, 15)::text, true);

select is(current_setting('prueba.r')::jsonb -> 'data',
  '{"creados": 4, "con_stock": 2, "existentes": 2}'::jsonb,
  'I1. Crea 4, salta 2 que ya existen (por código y por nombre) y pone stock a 2');

select results_eq(
  $$ select p.codigo_principal, c.nombre, p.tarifa_iva::numeric, p.por_completar from public.productos p
       join public.categorias c on c.id = p.categoria_id where p.nombre = 'K chitos natural 67g' $$,
  $$ values ('300036732'::text, 'FRITOLAY'::text, 15::numeric, true) $$,
  'I2. Con su código, la categoría de la hoja, la tarifa elegida y por completar');

select is((select count(*)::int from public.categorias where lower(nombre) = 'fritolay'), 1,
  'I3. «fritolay» usa la categoría FRITOLAY que ya se creó');

-- El costo no se ve con el rol de la app (D-020): se mira como administrador.
reset role;
select results_eq(
  $$ select e.cantidad::numeric, round(e.costo_promedio, 2) from public.existencias e
       join public.productos p on p.id = e.producto_id where p.nombre = 'K chitos natural 67g' $$,
  $$ values (7::numeric, 0.32::numeric) $$,
  'I4. El stock con costo entra como apertura');
set local role authenticated;

select is((select coalesce(max(e.cantidad), 0)::numeric from public.existencias e
            join public.productos p on p.id = e.producto_id where p.nombre = 'Ruffles natural 40 G'), 0::numeric,
  'I5. Sin costo, el producto queda sin stock');

select is((select count(*)::int from public.productos where codigo_principal = '300055191'), 1,
  'I6. No se duplica el que tenía el mismo código');

select is((select count(*)::int from public.productos where lower(nombre) = 'cheetos queso 21g'), 1,
  'I7. No se duplica el que tenía el mismo nombre');

-- Reimportar el mismo archivo no crea nada.
select is(public.importar_productos(current_setting('prueba.filas')::jsonb, 15) -> 'data' ->> 'creados', '0',
  'I8. Subir otra vez el mismo archivo no crea nada');

-- Una fila sin nombre: error con la línea y nada creado.
select is(public.importar_productos(jsonb_build_array(
    jsonb_build_object('nombre', 'Producto bueno'),
    jsonb_build_object('nombre', '  ')), 15) -> 'error' -> 'detalle' ->> 'linea', '2',
  'I9. Una fila sin nombre se rechaza e indica la fila');
select is((select count(*)::int from public.productos where nombre = 'Producto bueno'), 0,
  'I10. Y no queda nada creado');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.importar_productos(current_setting('prueba.filas')::jsonb, 15) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'I11. El Vendedor no importa productos');

select * from finish();
rollback;
