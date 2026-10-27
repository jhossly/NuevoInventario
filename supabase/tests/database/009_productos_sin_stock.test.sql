-- =============================================================================
-- Pruebas de productos sin control de stock (recargas y servicios, D-046)
--   * se venden sin existencias, sin kardex y con su costo de servicio
--   * compra: actualiza el costo, no el stock; anular y devolver no mueven stock
--   * apertura, ajuste y merma se rechazan
--   * apagar el control solo con stock en cero; volver a encenderlo
--   * permisos: el Vendedor no ve el costo ni lo cambia
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(20);

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

-- Los costos están ocultos al navegador (D-020): se leen como servidor (reset role).
-- Ayuda: venta en efectivo de n unidades de una presentación.
create function pg_temp.venta(p_pres text, p_cantidad numeric, p_monto numeric)
returns jsonb language sql as $$
  select public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', p_pres, 'cantidad', p_cantidad)),
    jsonb_build_array(jsonb_build_object('medio', 'EFECTIVO', 'monto', p_monto)),
    null, null, gen_random_uuid())
$$;
grant execute on function pg_temp.venta(text, numeric, numeric) to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.recarga', coalesce(public.guardar_producto(null,
  '{"nombre":"Recarga Claro $1","codigo_iva":"6","precio_venta":1.00,"controla_stock":false,"costo_servicio":0.95}')
  -> 'data' ->> 'id', ''), true);
select set_config('prueba.recarga_u', (select id::text from public.presentaciones
  where producto_id = nullif(current_setting('prueba.recarga'), '')::uuid), true);
select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite","codigo_iva":"4","precio_venta":3.45}') -> 'data' ->> 'id', true);
select public.abrir_caja(0);

reset role;
select results_eq(
  $$ select p.controla_stock, x.cantidad, x.ultimo_costo
       from public.productos p join public.existencias x on x.producto_id = p.id
      where p.id = nullif(current_setting('prueba.recarga'), '')::uuid $$,
  $$ values (false, 0::numeric(14,3), 0.95::numeric(16,6)) $$,
  'S1. Se crea un servicio sin control de stock y con su costo');
set local role authenticated;

-- =============================================================================
-- Vender sin existencias
-- =============================================================================
select set_config('prueba.v1', coalesce(pg_temp.venta(current_setting('prueba.recarga_u'), 3, 3.00)
  -> 'data' ->> 'venta_id', ''), true);
select isnt(nullif(current_setting('prueba.v1'), ''), null, 'S2. Se venden 3 recargas sin tener stock');

reset role;
select results_eq(
  $$ select costo_unitario, costo_total from public.venta_detalles
      where venta_id = nullif(current_setting('prueba.v1'), '')::uuid $$,
  $$ values (0.95::numeric(16,6), 2.85::numeric(16,6)) $$,
  'S3. Cada línea guarda el costo del servicio');
set local role authenticated;

reset role;
select is((select costo_total from public.ventas where id = nullif(current_setting('prueba.v1'), '')::uuid),
  2.85::numeric(16,6), 'S4. La venta suma ese costo');
set local role authenticated;

reset role;
select is((select count(*)::int from public.movimientos_inventario
            where producto_id = current_setting('prueba.recarga')::uuid), 0,
  'S5. No se escribe nada en el kardex');
set local role authenticated;

reset role;
select is((select cantidad from public.existencias where producto_id = current_setting('prueba.recarga')::uuid),
  0::numeric(14,3), 'S6. El stock sigue en cero');
set local role authenticated;

-- =============================================================================
-- Devolver y anular
-- =============================================================================
select is(public.registrar_devolucion(current_setting('prueba.v1')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id',
      (select id from public.venta_detalles where venta_id = current_setting('prueba.v1')::uuid), 'cantidad', 1)),
    'No se acreditó', 'EFECTIVO', gen_random_uuid()) -> 'data' ->> 'total', '1.00',
  'S7. Se devuelve 1 recarga');
reset role;
select results_eq(
  $$ select dd.costo_total from public.devolucion_detalles dd
       join public.devoluciones d on d.id = dd.devolucion_id
      where d.venta_id = current_setting('prueba.v1')::uuid $$,
  $$ values (0.95::numeric(16,6)) $$,
  'S8. La devolución vuelve al costo con que salió');
set local role authenticated;

select set_config('prueba.v2', pg_temp.venta(current_setting('prueba.recarga_u'), 2, 2.00) -> 'data' ->> 'venta_id', true);
select is(public.anular_venta(current_setting('prueba.v2')::uuid, 'Número equivocado') ->> 'ok', 'true',
  'S9. Se anula una venta de recargas');
reset role;
select results_eq(
  $$ select (select count(*)::int from public.movimientos_inventario
              where producto_id = current_setting('prueba.recarga')::uuid),
            (select cantidad from public.existencias where producto_id = current_setting('prueba.recarga')::uuid) $$,
  $$ values (0, 0::numeric(14,3)) $$,
  'S10. Devolver y anular tampoco mueven stock ni kardex');
set local role authenticated;

-- =============================================================================
-- Compras: actualizan el costo
-- =============================================================================
select ok((public.registrar_compra(null, false, null, null,
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.recarga_u'),
                                         'cantidad', 20, 'costo_unitario', 0.94)),
    gen_random_uuid()) ->> 'ok')::boolean,
  'S11. Se compra saldo de recargas');
reset role;
select results_eq(
  $$ select cantidad, ultimo_costo from public.existencias where producto_id = current_setting('prueba.recarga')::uuid $$,
  $$ values (0::numeric(14,3), 0.94::numeric(16,6)) $$,
  'S12. La compra cambia el costo, no el stock');
set local role authenticated;

-- =============================================================================
-- Ajustes y cambio del control
-- =============================================================================
select is(public.ajustar_inventario(current_setting('prueba.recarga')::uuid, 'APERTURA', 10, 1) -> 'error' ->> 'mensaje',
  'Este producto no controla stock: no se ajusta ni se cuenta',
  'S13. Una apertura se rechaza');
select is(public.ajustar_inventario(current_setting('prueba.recarga')::uuid, 'MERMA', -1, null, 'x') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS', 'S14. Una merma se rechaza');

select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 5, 2);
select is(public.guardar_producto(current_setting('prueba.aceite')::uuid, '{"controla_stock":false}') -> 'error' ->> 'mensaje',
  'Para dejar de controlar el stock, primero llévalo a cero con un ajuste',
  'S15. Con stock no se deja de controlar');

select public.guardar_producto(current_setting('prueba.recarga')::uuid, '{"costo_servicio":0.96}');
reset role;
select is((select ultimo_costo from public.existencias where producto_id = current_setting('prueba.recarga')::uuid),
  0.96::numeric(16,6), 'S16. El Dueño cambia el costo del servicio');
set local role authenticated;

-- =============================================================================
-- Vendedor
-- =============================================================================
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select ok((pg_temp.venta(current_setting('prueba.recarga_u'), 1, 1.00) ->> 'ok')::boolean,
  'S17. El Vendedor vende recargas');
select is(public.guardar_producto(current_setting('prueba.recarga')::uuid, '{"costo_servicio":0}') -> 'error' ->> 'codigo',
  'SIN_PERMISO', 'S18. El Vendedor no cambia el costo');
select ok(not has_column_privilege('authenticated', 'public.existencias', 'ultimo_costo', 'select'),
  'S19. El costo del servicio está oculto al navegador (D-020)');

-- Volver a controlar el stock: arranca en cero y ya no se vende sin existencias
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);
select public.guardar_producto(current_setting('prueba.recarga')::uuid, '{"controla_stock":true}');
select is(pg_temp.venta(current_setting('prueba.recarga_u'), 1, 1.00) -> 'error' ->> 'codigo', 'STOCK_INSUFICIENTE',
  'S20. Al volver a controlar el stock, sin existencias no se vende');

select * from finish();
rollback;
