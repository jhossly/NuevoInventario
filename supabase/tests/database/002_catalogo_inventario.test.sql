-- =============================================================================
-- Pruebas de catálogo e inventario (Fase 6)
--   * kardex del aceite de la Fase 3, fila por fila, con costo promedio
--   * reglas de ajustes, conteos, idempotencia y redondeo
--   * Vendedor sin costos, aislamiento entre empresas, libro inmutable
-- Los ids creados se guardan con set_config('prueba.*') para reutilizarlos.
-- Todo ocurre dentro de una transacción que se revierte al final.
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(62);

-- -----------------------------------------------------------------------------
-- Datos de prueba: empresa A (Dueño y Vendedor) y empresa B (Dueño)
-- -----------------------------------------------------------------------------
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

-- =============================================================================
-- Dueño de A: catálogo
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.cat',
  coalesce(public.guardar_categoria(null, 'Aceites') -> 'data' ->> 'id', ''), true);
select isnt(nullif(current_setting('prueba.cat'), ''), null,
  'C1. El Dueño crea una categoría');

select is(public.guardar_categoria(null, '  ACEITES ') -> 'error' ->> 'codigo', 'DUPLICADO',
  'C2. No se repite una categoría aunque cambien mayúsculas y espacios');

select set_config('prueba.aceite', coalesce(public.guardar_producto(null, jsonb_build_object(
  'nombre', 'Aceite 1 L', 'categoria_id', current_setting('prueba.cat'),
  'unidad_base', 'UND', 'tarifa_iva', 15, 'precio_venta', 3.45)) -> 'data' ->> 'id', ''), true);
select isnt(nullif(current_setting('prueba.aceite'), ''), null,
  'C3. El Dueño crea el producto aceite');

select results_eq(
  $$ select nombre, factor::numeric, precio_venta::numeric from public.presentaciones
      where producto_id = current_setting('prueba.aceite')::uuid $$,
  $$ values ('Unidad'::text, 1::numeric, 3.45::numeric) $$,
  'C4. Crear un producto crea su presentación base de factor 1 con su precio');

select is((select cantidad from public.existencias
            where producto_id = current_setting('prueba.aceite')::uuid), 0::numeric(14,3),
  'C5. Crear un producto crea su fila de existencias en cero');

select is(public.guardar_presentacion(null, jsonb_build_object(
    'producto_id', current_setting('prueba.aceite'), 'nombre', 'Caja 12', 'factor', 12,
    'se_vende', false)) ->> 'ok', 'true',
  'C6. El Dueño crea la presentación caja de 12');

select is(public.guardar_presentacion(null, jsonb_build_object(
    'producto_id', current_setting('prueba.aceite'), 'nombre', 'Caja vacía', 'factor', 0))
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'C7. Una presentación no acepta factor cero');

select is(public.guardar_producto(null, '{"nombre":"Sin IVA definido"}') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS',
  'C8. Un producto necesita tarifa de IVA');

select set_config('prueba.queso', coalesce(public.guardar_producto(null,
  '{"nombre":"Queso fresco","unidad_base":"KG","tarifa_iva":0,"precio_venta":6.00}')
  -> 'data' ->> 'id', ''), true);
select is((select nombre from public.presentaciones
            where producto_id = current_setting('prueba.queso')::uuid), 'Kilo',
  'C9. Un producto por kilo tiene presentación base Kilo');

select public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.queso'), 'nombre', 'Libra', 'factor', 0.453592,
  'precio_venta', 2.75));
select is((select factor from public.presentaciones
            where producto_id = current_setting('prueba.queso')::uuid and nombre = 'Libra'),
  0.453592::numeric(14,6),
  'C10. La libra guarda su factor con 6 decimales');

select public.guardar_presentacion(
  (select id from public.presentaciones
    where producto_id = current_setting('prueba.aceite')::uuid and nombre = 'Unidad'),
  '{"precio_venta":3.50}');
select is((select antes ->> 'precio_venta' from public.auditoria
            where accion = 'PRESENTACION_EDITADA'), '3.45',
  'C11. Cambiar el precio deja el anterior en auditoría');

select set_config('prueba.fosforos', coalesce(public.guardar_producto(null,
  '{"nombre":"Fósforos","tarifa_iva":15}') -> 'data' ->> 'id', ''), true);

-- =============================================================================
-- Kardex del aceite (Fase 3). Compra, venta y devolución todavía no tienen
-- función propia (Fase 7): se registran con el motor privado como servidor.
-- =============================================================================
select is(public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 10, 2)
    -> 'data' ->> 'saldo_valor', '20.000000',
  'K1. Apertura: 10 u a $2,00 = $20,000000');

reset role;

select is((privado.registrar_movimiento('aaaaaaaa-0000-0000-0000-000000000000',
    current_setting('prueba.aceite')::uuid, 'COMPRA', 24, 2.645)).saldo_valor,
  83.480000::numeric(16,6),
  'K2. Compra de 24 u a $2,645: inventario $83,480000');

select is((privado.registrar_movimiento('aaaaaaaa-0000-0000-0000-000000000000',
    current_setting('prueba.aceite')::uuid, 'VENTA', -3)).valor,
  -7.365882::numeric(16,6),
  'K3. Venta de 3 u sale al promedio: −$7,365882');

set local role authenticated;

select is(public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'MERMA', -1, null, 'Botella rota')
    -> 'data' ->> 'saldo_valor', '73.658824',
  'K4. Merma de 1 u: inventario $73,658824');

reset role;

select is((privado.registrar_movimiento('aaaaaaaa-0000-0000-0000-000000000000',
    current_setting('prueba.aceite')::uuid, 'DEVOLUCION_VENTA', 1, 2.455294)).saldo_valor,
  76.114118::numeric(16,6),
  'K5. Devolución de 1 u al costo con que salió: inventario $76,114118');

set local role authenticated;

select set_config('prueba.conteo', coalesce(public.guardar_conteo(null,
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('prueba.aceite'),
                                       'cantidad_contada', 29)),
  'Conteo de prueba') -> 'data' ->> 'conteo_id', ''), true);
select is((select cantidad_sistema from public.conteo_detalles
            where conteo_id = current_setting('prueba.conteo')::uuid), 31::numeric(14,3),
  'K6. El conteo en borrador registra 31 u en el sistema');

select is(public.confirmar_conteo(current_setting('prueba.conteo')::uuid) -> 'data' ->> 'movimientos', '1',
  'K7. Confirmar el conteo de 29 u genera un movimiento');

select results_eq(
  $$ select tipo, cantidad::numeric, costo_unitario::numeric, valor::numeric,
            saldo_cantidad::numeric, saldo_valor::numeric
       from public.movimientos_inventario
      where producto_id = current_setting('prueba.aceite')::uuid
      order by secuencia $$,
  $$ values ('APERTURA'::text,       10::numeric, 2::numeric,        20::numeric,        10::numeric, 20::numeric),
            ('COMPRA',               24,          2.645,             63.48,              34,          83.48),
            ('VENTA',                -3,          2.455294,          -7.365882,          31,          76.114118),
            ('MERMA',                -1,          2.455294,          -2.455294,          30,          73.658824),
            ('DEVOLUCION_VENTA',      1,          2.455294,           2.455294,          31,          76.114118),
            ('CONTEO',               -2,          2.455294,          -4.910588,          29,          71.203530) $$,
  'K8. El kardex del aceite coincide fila por fila con la Fase 3');

select results_eq(
  $$ select p ->> 'cantidad', p ->> 'costo_promedio', p ->> 'valor_total'
       from jsonb_array_elements(public.inventario_valorizado() -> 'data' -> 'productos') p
      where p ->> 'producto_id' = current_setting('prueba.aceite') $$,
  $$ values ('29.000'::text, '2.455294'::text, '71.203530'::text) $$,
  'K9. Saldo final: 29 u, promedio $2,455294, valor $71,203530');

-- =============================================================================
-- Reglas de ajustes y conteos (Dueño de A)
-- =============================================================================
select is(public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 5, 2)
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R1. No hay segunda apertura para un producto con movimientos');

select is(public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'MERMA', -30, null, 'Prueba')
    -> 'error' ->> 'codigo', 'STOCK_INSUFICIENTE',
  'R2. No se puede sacar más de lo que hay');

select is((select cantidad from public.existencias
            where producto_id = current_setting('prueba.aceite')::uuid), 29::numeric(14,3),
  'R3. Un intento rechazado no cambia el stock');

select is(public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'AJUSTE', 1)
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R4. Un ajuste necesita motivo');

select is(public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'MERMA', 1, null, 'Prueba')
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R5. Una merma con cantidad positiva se rechaza');

select is(public.ajustar_inventario(current_setting('prueba.fosforos')::uuid, 'AJUSTE', 1, null, 'Encontrado')
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R6. Una entrada sin costo se rechaza si el producto nunca tuvo costo');

select set_config('prueba.mov_queso', coalesce(public.ajustar_inventario(
  current_setting('prueba.queso')::uuid, 'APERTURA', 5.2505, 4, null,
  'cccccccc-0000-0000-0000-000000000001') -> 'data' ->> 'movimiento_id', ''), true);
select is((select cantidad from public.existencias
            where producto_id = current_setting('prueba.queso')::uuid), 5.251::numeric(14,3),
  'R7. La cantidad se redondea a 3 decimales, la mitad hacia arriba (5,2505 → 5,251)');

select results_eq(
  $$ select r -> 'data' ->> 'movimiento_id', r -> 'data' ->> 'repetido'
       from (select public.ajustar_inventario(current_setting('prueba.queso')::uuid, 'APERTURA',
                    5.2505, 4, null, 'cccccccc-0000-0000-0000-000000000001') r) x $$,
  $$ values (current_setting('prueba.mov_queso'), 'true') $$,
  'R8. Reenviar con la misma clave de idempotencia devuelve el mismo movimiento');

select is((select count(*)::int from public.movimientos_inventario
            where producto_id = current_setting('prueba.queso')::uuid), 1,
  'R9. El reintento no duplica el movimiento');

select is(public.confirmar_conteo(current_setting('prueba.conteo')::uuid) -> 'data' ->> 'repetido', 'true',
  'R10. Confirmar dos veces el mismo conteo no hace nada');

select is(public.guardar_conteo(current_setting('prueba.conteo')::uuid,
    jsonb_build_array(jsonb_build_object('producto_id', current_setting('prueba.aceite'),
                                         'cantidad_contada', 1)))
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R11. Un conteo confirmado ya no se edita');

select is(public.guardar_conteo(null,
    jsonb_build_array(jsonb_build_object('producto_id', current_setting('prueba.aceite'),
                                         'cantidad_contada', -1)))
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R12. Un conteo no acepta cantidades negativas');

select set_config('prueba.conteo2', coalesce(public.guardar_conteo(null,
  jsonb_build_array(jsonb_build_object('producto_id', current_setting('prueba.queso'),
                                       'cantidad_contada', 6))) -> 'data' ->> 'conteo_id', ''), true);
select public.confirmar_conteo(current_setting('prueba.conteo2')::uuid);
select results_eq(
  $$ select cantidad::numeric, valor::numeric, saldo_valor::numeric
       from public.movimientos_inventario
      where producto_id = current_setting('prueba.queso')::uuid and tipo = 'CONTEO' $$,
  $$ values (0.749::numeric, 2.996::numeric, 24::numeric) $$,
  'R13. Un sobrante en el conteo entra al costo promedio vigente');

select is(public.guardar_producto(current_setting('prueba.aceite')::uuid, '{"unidad_base":"KG"}')
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R14. No se cambia la unidad base de un producto con movimientos');

select public.guardar_producto(current_setting('prueba.aceite')::uuid, '{"tarifa_iva":0}');
select is((select antes ->> 'tarifa_iva' from public.auditoria
            where accion = 'PRODUCTO_EDITADO' and registro_id = current_setting('prueba.aceite')::uuid),
  '15.00',
  'R15. Cambiar la tarifa de IVA queda en auditoría');

select is(public.eliminar_categoria(current_setting('prueba.cat')::uuid) -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS',
  'R16. No se borra una categoría con productos');

select is(public.inventario_valorizado() -> 'data' ->> 'valor_total', '95.203530',
  'R17. Stock valorizado de la empresa: $71,203530 + $24,000000');

select throws_ok(
  $$ insert into public.existencias (empresa_id, producto_id, cantidad)
     values ('aaaaaaaa-0000-0000-0000-000000000000', current_setting('prueba.fosforos')::uuid, 100) $$,
  '42501', null,
  'R18. El Dueño no puede escribir existencias directamente');

select throws_ok(
  $$ update public.productos set tarifa_iva = 5 $$,
  '42501', null,
  'R19. El Dueño no puede editar productos directamente');

select throws_ok(
  $$ select privado.registrar_movimiento('aaaaaaaa-0000-0000-0000-000000000000',
       current_setting('prueba.aceite')::uuid, 'COMPRA', 100, 0) $$,
  '42501', null,
  'R20. El navegador no puede llamar al motor privado de inventario');

reset role;

-- =============================================================================
-- Vendedor de A: ve productos y stock, no costos
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);

select is((select count(*)::int from public.productos), 3,
  'V1. El Vendedor ve los productos de su empresa');

select is((select sum(cantidad) from public.existencias), 35::numeric,
  'V2. El Vendedor ve las cantidades en stock');

select throws_ok(
  $$ select valor_total from public.existencias $$,
  '42501', null,
  'V3. El Vendedor no puede leer el valor del inventario');

select is_empty(
  $$ select 1 from public.movimientos_inventario $$,
  'V4. El Vendedor no ve el kardex (tiene costos)');

select is_empty(
  $$ select 1 from public.conteos $$,
  'V5. El Vendedor no ve los conteos');

select is(public.inventario_valorizado() -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V6. El Vendedor no obtiene el stock valorizado');

select is(public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'MERMA', -1, null, 'x')
    -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V7. El Vendedor no hace ajustes ni mermas');

select is(public.guardar_producto(null, '{"nombre":"Intruso","tarifa_iva":15}') -> 'error' ->> 'codigo',
  'SIN_PERMISO',
  'V8. El Vendedor no crea productos');

select is(public.guardar_conteo(null,
    jsonb_build_array(jsonb_build_object('producto_id', current_setting('prueba.aceite'),
                                         'cantidad_contada', 1)))
    -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V9. El Vendedor no registra conteos');

reset role;
update public.empresas set vendedor_ve_costos = true where id = 'aaaaaaaa-0000-0000-0000-000000000000';
set local role authenticated;

select is((select count(*)::int from public.movimientos_inventario), 8,
  'V10. Si la empresa lo permite, el Vendedor ve el kardex (D-015)');

reset role;
update public.empresas set vendedor_ve_costos = false where id = 'aaaaaaaa-0000-0000-0000-000000000000';

-- =============================================================================
-- Dueño de B no toca nada de A
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);

select is_empty(
  $$ select 1 from public.productos $$,
  'B1. El Dueño de B no ve los productos de A');

select is(public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'MERMA', -1, null, 'x')
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'B2. El Dueño de B no puede ajustar el stock de A');

select is(public.guardar_presentacion(null, jsonb_build_object(
    'producto_id', current_setting('prueba.aceite'), 'nombre', 'Intrusa', 'factor', 1))
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'B3. El Dueño de B no puede agregar presentaciones a productos de A');

select is(public.guardar_conteo(null,
    jsonb_build_array(jsonb_build_object('producto_id', current_setting('prueba.aceite'),
                                         'cantidad_contada', 0)))
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'B4. El Dueño de B no puede contar productos de A');

select is(public.guardar_producto(current_setting('prueba.aceite')::uuid, '{"nombre":"Robado"}')
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'B5. El Dueño de B no puede editar productos de A');

reset role;

-- =============================================================================
-- Visitante sin sesión
-- =============================================================================
set local role anon;
select set_config('request.jwt.claims', '', true);

select throws_ok(
  $$ select * from public.productos $$,
  '42501', null,
  'N1. Visitante sin sesión no lee productos');

select throws_ok(
  $$ select public.ajustar_inventario(gen_random_uuid(), 'AJUSTE', 1, 1, 'x') $$,
  '42501', null,
  'N2. Visitante sin sesión no ejecuta funciones de inventario');

reset role;

-- =============================================================================
-- Integridad del libro (como servidor)
-- =============================================================================
select is_empty(
  $$ select x.producto_id
       from public.existencias x
       left join (select producto_id, sum(cantidad) c, sum(valor) v
                    from public.movimientos_inventario group by producto_id) m
         on m.producto_id = x.producto_id
      where x.cantidad <> coalesce(m.c, 0) or x.valor_total <> coalesce(m.v, 0) $$,
  'L1. Existencias coincide con la suma del libro en cada producto');

select throws_ok(
  $$ update public.movimientos_inventario set cantidad = 100 $$,
  'P0001', null,
  'L2. Un movimiento no se puede modificar ni con privilegios de servidor');

select throws_ok(
  $$ delete from public.movimientos_inventario $$,
  'P0001', null,
  'L3. Un movimiento no se puede borrar ni con privilegios de servidor');

select throws_ok(
  $$ update public.conteos set nota = 'cambiado' where id = current_setting('prueba.conteo')::uuid $$,
  'P0001', null,
  'L4. Un conteo confirmado no se puede modificar');

select throws_ok(
  $$ delete from public.conteo_detalles where conteo_id = current_setting('prueba.conteo')::uuid $$,
  'P0001', null,
  'L5. Las líneas de un conteo confirmado no se pueden borrar');

select * from finish();
rollback;
