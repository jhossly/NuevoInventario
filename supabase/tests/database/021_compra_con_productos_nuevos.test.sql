-- =============================================================================
-- Pruebas de la compra a mano que crea productos nuevos (D-067)
--   * crea producto, «Caja N», precio y tarifa; registra stock y costo
--   * usa el existente con el mismo nombre; no duplica en reintentos
--   * si la compra falla no queda ningún producto creado
--   * por completar y marcar revisado; permisos
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(14);

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

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite","tarifa_iva":15,"precio_venta":3.45}') -> 'data' ->> 'id', true);
select set_config('prueba.aceite_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid and factor = 1), true);

-- Galletas X nueva: 2 cajas de 12 a $6 + 15 %. Aceite existente.
-- «aceite» escrito como nuevo usa el Aceite que ya existe.
select set_config('prueba.r', public.registrar_compra_con_nuevos(null, false, null, null,
  jsonb_build_array(
    jsonb_build_object('nuevo', jsonb_build_object('nombre', 'Galletas X', 'factor', '12', 'precio_venta', '0.75'),
                       'cantidad', '2', 'costo_unitario', '6', 'tarifa_iva', '15'),
    jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1, 'costo_unitario', 2),
    jsonb_build_object('nuevo', jsonb_build_object('nombre', ' aceite ', 'factor', '1'),
                       'cantidad', '1', 'costo_unitario', '2', 'tarifa_iva', '15')),
  'cccccccc-0000-0000-0000-000000000001')::text, true);

select is(current_setting('prueba.r')::jsonb ->> 'ok', 'true', 'C1. Se registra la compra con un producto nuevo');
select is((current_setting('prueba.r')::jsonb -> 'data' ->> 'creados')::int, 1,
  'C2. Solo se crea Galletas X; «aceite» usa el que ya existe');

select set_config('prueba.galletas', (select id::text from public.productos where nombre = 'Galletas X'), true);

select results_eq(
  $$ select p.unidad_base, p.tarifa_iva::numeric, p.por_completar from public.productos p
      where p.id = current_setting('prueba.galletas')::uuid $$,
  $$ values ('UND'::text, 15::numeric, true) $$,
  'C3. El producto nuevo es por unidad, con la tarifa de la compra y queda por completar');

select results_eq(
  $$ select r.nombre, r.factor::numeric, r.se_vende, r.precio_venta::numeric from public.presentaciones r
      where r.producto_id = current_setting('prueba.galletas')::uuid order by r.factor $$,
  $$ values ('Unidad'::text, 1::numeric, true, 0.75::numeric), ('Caja 12'::text, 12::numeric, false, null::numeric) $$,
  'C4. Unidad con el precio dado y «Caja 12» solo para comprar');

select is((select cantidad::numeric from public.existencias where producto_id = current_setting('prueba.galletas')::uuid),
  24::numeric, 'C5. Entran 24 unidades al stock');

select is((select costo_unitario_base::numeric from public.compra_detalles
            where compra_id = (current_setting('prueba.r')::jsonb -> 'data' ->> 'compra_id')::uuid and orden = 1),
  0.575::numeric, 'C6. Costo por unidad con el IVA pagado');

select is((select por_completar from public.productos where id = current_setting('prueba.aceite')::uuid), false,
  'C7. El producto existente no queda por completar');

-- Reintento con la misma clave: devuelve la misma compra y no crea nada.
select is(public.registrar_compra_con_nuevos(null, false, null, null,
  jsonb_build_array(jsonb_build_object('nuevo', jsonb_build_object('nombre', 'Otro', 'factor', '1'),
                                       'cantidad', '1', 'costo_unitario', '1')),
  'cccccccc-0000-0000-0000-000000000001') -> 'data' ->> 'repetido', 'true',
  'C8. Reenviar con la misma clave devuelve la misma compra');
select is((select count(*)::int from public.productos where nombre = 'Otro'), 0,
  'C9. El reintento no crea productos');

-- Compra que no entra (respaldo sin documento): el producto nuevo no queda.
select is(public.registrar_compra_con_nuevos(null, true, null, null,
  jsonb_build_array(jsonb_build_object('nuevo', jsonb_build_object('nombre', 'Chifles', 'factor', '10'),
                                       'cantidad', '1', 'costo_unitario', '3')),
  'cccccccc-0000-0000-0000-000000000002') -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'C10. Una compra con respaldo sin documento se rechaza');
select is((select count(*)::int from public.productos where nombre = 'Chifles'), 0,
  'C11. Si la compra no entra, no queda el producto creado');

select is(public.registrar_compra_con_nuevos(null, false, null, null,
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1, 'costo_unitario', 1),
                    jsonb_build_object('nuevo', jsonb_build_object('nombre', ''), 'cantidad', '1', 'costo_unitario', '3')),
  'cccccccc-0000-0000-0000-000000000003') -> 'error' -> 'detalle' ->> 'linea', '2',
  'C12. Sin nombre se rechaza e indica la línea');

select public.marcar_producto_revisado(current_setting('prueba.galletas')::uuid);
select is((select por_completar from public.productos where id = current_setting('prueba.galletas')::uuid), false,
  'C13. Marcado como revisado deja de estar por completar');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.marcar_producto_revisado(current_setting('prueba.galletas')::uuid) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'C14. El Vendedor no marca productos ni registra compras');

select * from finish();
rollback;
