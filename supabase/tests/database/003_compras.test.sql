-- =============================================================================
-- Pruebas de proveedores y compras (Fase 7)
--   * cálculo: compra del kardex del aceite (Fase 3), HU-01 (Fase 1),
--     descuento antes del IVA, IVA como costo o no, libra → kilo
--   * reglas: respaldo, documento repetido, idempotencia, fecha, todo o nada
--   * anulación al costo promedio y su límite cuando ya se vendió
--   * compras inmutables, permisos y aislamiento
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(46);

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
-- Dueño de A: catálogo de prueba y proveedores
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite 1 L","tarifa_iva":15}') -> 'data' ->> 'id', true);
select set_config('prueba.caja12', public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.aceite'), 'nombre', 'Caja 12', 'factor', 12)) -> 'data' ->> 'id', true);
select set_config('prueba.galletas', public.guardar_producto(null,
  '{"nombre":"Galletas","tarifa_iva":0}') -> 'data' ->> 'id', true);
select set_config('prueba.caja24', public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.galletas'), 'nombre', 'Caja 24', 'factor', 24)) -> 'data' ->> 'id', true);
select set_config('prueba.queso', public.guardar_producto(null,
  '{"nombre":"Queso","unidad_base":"KG","tarifa_iva":0}') -> 'data' ->> 'id', true);
select set_config('prueba.libra', public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.queso'), 'nombre', 'Libra', 'factor', 0.453592)) -> 'data' ->> 'id', true);
select set_config('prueba.display', public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.aceite'), 'nombre', 'Display', 'factor', 6,
  'se_compra', false)) -> 'data' ->> 'id', true);

select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 10, 2);
select public.ajustar_inventario(current_setting('prueba.galletas')::uuid, 'APERTURA', 10, 0.50);

select set_config('prueba.prov', coalesce(public.guardar_proveedor(null,
  '{"tipo_identificacion":"RUC","identificacion":"1790000000001","nombre":"Distribuidora Norte"}')
  -> 'data' ->> 'id', ''), true);
select isnt(nullif(current_setting('prueba.prov'), ''), null,
  'P1. El Dueño registra un proveedor con RUC');

select is(public.guardar_proveedor(null,
    '{"tipo_identificacion":"RUC","identificacion":"179000000000","nombre":"Corto"}') -> 'error' ->> 'mensaje',
  'El RUC tiene 13 dígitos y la cédula 10',
  'P2. Un RUC de 12 dígitos se rechaza con un mensaje claro');

select is(public.guardar_proveedor(null,
    '{"tipo_identificacion":"RUC","identificacion":"1790000000001","nombre":"Repetido"}') -> 'error' ->> 'codigo',
  'DUPLICADO',
  'P3. No se repite la identificación de un proveedor');

select is(public.guardar_proveedor(null,
    '{"tipo_identificacion":"CEDULA","identificacion":"0912345678","nombre":"Don Pepe"}') ->> 'ok',
  'true',
  'P4. Un proveedor persona natural se registra con cédula');

-- =============================================================================
-- Cálculo (sin guardar)
-- =============================================================================
select results_eq(
  $$ select r -> 'data' ->> 'subtotal', r -> 'data' ->> 'iva', r -> 'data' ->> 'total',
            r -> 'data' -> 'lineas' -> 0 ->> 'cantidad_base', r -> 'data' -> 'lineas' -> 0 ->> 'costo_unitario_base'
       from (select public.calcular_compra(jsonb_build_array(jsonb_build_object(
               'presentacion_id', current_setting('prueba.caja12'), 'cantidad', 2, 'costo_unitario', 27.60))) r) x $$,
  $$ values ('55.20', '8.28', '63.48', '24.000', '2.645000') $$,
  'C1. Fase 3: 2 cajas de 12 a $27,60 + IVA 15 % = $63,48; costo por unidad $2,645');

select is((select count(*)::int from public.compras), 0,
  'C2. Calcular no guarda nada');

select results_eq(
  $$ select r -> 'data' ->> 'subtotal', r -> 'data' ->> 'descuento', r -> 'data' ->> 'iva',
            r -> 'data' ->> 'total', r -> 'data' -> 'lineas' -> 0 ->> 'costo_unitario_base'
       from (select public.calcular_compra(jsonb_build_array(jsonb_build_object(
               'presentacion_id', current_setting('prueba.caja12'), 'cantidad', 1,
               'costo_unitario', 27.60, 'descuento', 2.60))) r) x $$,
  $$ values ('27.60', '2.60', '3.75', '28.75', '2.395833') $$,
  'C3. El descuento se resta antes del IVA: (27,60 − 2,60) × 15 % = 3,75');

select is(public.calcular_compra(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.libra'), 'cantidad', 3, 'costo_unitario', 2)))
    -> 'data' -> 'lineas' -> 0 ->> 'cantidad_base', '1.361',
  'C4. 3 libras entran como 1,361 kg (0,453592 × 3 redondeado a 3 decimales)');

reset role;
update public.empresas set iva_compras_es_costo = false where id = 'aaaaaaaa-0000-0000-0000-000000000000';
set local role authenticated;

select is(public.calcular_compra(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.caja12'), 'cantidad', 2, 'costo_unitario', 27.60)))
    -> 'data' -> 'lineas' -> 0 ->> 'costo_unitario_base', '2.300000',
  'C5. Si el IVA de compras no es costo, la unidad cuesta $2,30 sin IVA');

reset role;
update public.empresas set iva_compras_es_costo = true where id = 'aaaaaaaa-0000-0000-0000-000000000000';
set local role authenticated;

select is(public.calcular_compra(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.display'), 'cantidad', 1, 'costo_unitario', 10)))
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'C6. No se compra en una presentación marcada como «no se compra»');

select results_eq(
  $$ select r -> 'error' ->> 'codigo', r -> 'error' -> 'detalle' ->> 'linea'
       from (select public.calcular_compra(jsonb_build_array(
               jsonb_build_object('presentacion_id', current_setting('prueba.caja12'), 'cantidad', 1, 'costo_unitario', 10),
               jsonb_build_object('presentacion_id', current_setting('prueba.caja12'), 'cantidad', 1, 'costo_unitario', 10,
                                  'descuento', 11))) r) x $$,
  $$ values ('DATOS_INVALIDOS', '2') $$,
  'C7. Un descuento mayor que el subtotal se rechaza indicando la línea');

-- =============================================================================
-- Registro
-- =============================================================================
select set_config('prueba.compra1', coalesce(public.registrar_compra(
  current_setting('prueba.prov')::uuid, true, '1-1-123', null,
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.caja12'),
                                       'cantidad', 2, 'costo_unitario', 27.60)),
  'cccccccc-0000-0000-0000-000000000001') -> 'data' ->> 'compra_id', ''), true);
select isnt(nullif(current_setting('prueba.compra1'), ''), null,
  'R1. Se registra la compra del aceite con respaldo');

select results_eq(
  $$ select tipo, cantidad::numeric, costo_unitario::numeric, saldo_cantidad::numeric, saldo_valor::numeric
       from public.movimientos_inventario
      where origen_id = current_setting('prueba.compra1')::uuid $$,
  $$ values ('COMPRA'::text, 24::numeric, 2.645::numeric, 34::numeric, 83.48::numeric) $$,
  'R2. La compra entra 24 u a $2,645: stock 34, valor $83,48 (Fase 3, fila 2)');

select results_eq(
  $$ select numero_documento, subtotal::numeric, iva::numeric, total::numeric, iva_es_costo
       from public.compras where id = current_setting('prueba.compra1')::uuid $$,
  $$ values ('001-001-000000123'::text, 55.20::numeric, 8.28::numeric, 63.48::numeric, true) $$,
  'R3. Se guardan los totales y el número de documento normalizado');

select results_eq(
  $$ select cantidad::numeric, cantidad_base::numeric, costo_unitario_base::numeric, tarifa_iva::numeric
       from public.compra_detalles where compra_id = current_setting('prueba.compra1')::uuid $$,
  $$ values (2::numeric, 24::numeric, 2.645::numeric, 15::numeric) $$,
  'R4. La línea guarda cantidad en cajas y en unidades, costo por unidad y tarifa');

select is(public.registrar_compra(
    current_setting('prueba.prov')::uuid, true, '1-1-123', null,
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.caja12'),
                                         'cantidad', 2, 'costo_unitario', 27.60)),
    'cccccccc-0000-0000-0000-000000000001') -> 'data' ->> 'repetido', 'true',
  'R5. Reenviar con la misma clave devuelve la misma compra');

select is((select count(*)::int from public.compras), 1,
  'R6. El reintento no duplica la compra');

select is(public.registrar_compra(
    current_setting('prueba.prov')::uuid, true, '001-001-000000123', null,
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.caja12'),
                                         'cantidad', 1, 'costo_unitario', 27.60)),
    'cccccccc-0000-0000-0000-000000000002') -> 'error' ->> 'codigo', 'DUPLICADO',
  'R7. El mismo documento del mismo proveedor no se registra dos veces');

select is(public.registrar_compra(
    current_setting('prueba.prov')::uuid, true, '  ', null,
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.caja12'),
                                         'cantidad', 1, 'costo_unitario', 27.60)),
    'cccccccc-0000-0000-0000-000000000003') -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R8. Una compra con respaldo necesita número de documento (HU-01)');

select set_config('prueba.compra2', coalesce(public.registrar_compra(
  null, false, null, '2026-10-01',
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.caja24'),
                                       'cantidad', 1, 'costo_unitario', 14.40)),
  'cccccccc-0000-0000-0000-000000000004') -> 'data' ->> 'compra_id', ''), true);
select isnt(nullif(current_setting('prueba.compra2'), ''), null,
  'R9. Una compra sin respaldo se registra sin proveedor ni documento');

select is((public.inventario_valorizado() -> 'data' -> 'productos') @> jsonb_build_array(jsonb_build_object(
    'producto_id', current_setting('prueba.galletas'), 'cantidad', '34.000', 'costo_promedio', '0.570588')),
  true,
  'R10. HU-01: 10 u a $0,50 + 24 u a $14,40 → 34 u a $0,570588');

select is((select fecha from public.movimientos_inventario
            where origen_id = current_setting('prueba.compra2')::uuid), '2026-10-01'::date,
  'R11. El movimiento lleva la fecha del documento de compra');

select is(public.registrar_compra(
    null, false, null, current_date + 30,
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.caja24'),
                                         'cantidad', 1, 'costo_unitario', 14.40)),
    'cccccccc-0000-0000-0000-000000000005') -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R12. No se registra una compra con fecha futura');

select is(public.registrar_compra(
    null, false, null, null,
    jsonb_build_array(
      jsonb_build_object('presentacion_id', current_setting('prueba.caja24'), 'cantidad', 1, 'costo_unitario', 14.40),
      jsonb_build_object('presentacion_id', current_setting('prueba.display'), 'cantidad', 1, 'costo_unitario', 1)),
    'cccccccc-0000-0000-0000-000000000006') -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R13. Si una línea es inválida, la compra se rechaza');

select results_eq(
  $$ select (select count(*)::int from public.compras),
            (select cantidad from public.existencias where producto_id = current_setting('prueba.galletas')::uuid) $$,
  $$ values (2, 34::numeric(14,3)) $$,
  'R14. Una compra rechazada no deja nada guardado (ni compra ni stock)');

-- =============================================================================
-- Anulación
-- =============================================================================
select is(public.anular_compra(current_setting('prueba.compra1')::uuid, ' ') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS',
  'A1. Anular necesita motivo');

select is(public.anular_compra(current_setting('prueba.compra1')::uuid, 'Factura equivocada') ->> 'ok', 'true',
  'A2. El Dueño anula la compra del aceite');

select results_eq(
  $$ select tipo, cantidad::numeric, saldo_cantidad::numeric, saldo_valor::numeric
       from public.movimientos_inventario
      where origen_id = current_setting('prueba.compra1')::uuid and tipo = 'ANULACION_COMPRA' $$,
  $$ values ('ANULACION_COMPRA'::text, -24::numeric, 10::numeric, 24.552941::numeric) $$,
  'A3. La anulación saca 24 u al costo promedio vigente (D-023)');

select results_eq(
  $$ select estado, motivo_anulacion from public.compras where id = current_setting('prueba.compra1')::uuid $$,
  $$ values ('ANULADA'::text, 'Factura equivocada'::text) $$,
  'A4. La compra queda ANULADA con su motivo');

select is(public.anular_compra(current_setting('prueba.compra1')::uuid, 'Otra vez') -> 'data' ->> 'repetido', 'true',
  'A5. Anular dos veces no hace nada');

select set_config('prueba.compra3', coalesce(public.registrar_compra(
  current_setting('prueba.prov')::uuid, true, '001-001-000000123', null,
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.caja12'),
                                       'cantidad', 2, 'costo_unitario', 27.60)),
  'cccccccc-0000-0000-0000-000000000007') -> 'data' ->> 'compra_id', ''), true);
select isnt(nullif(current_setting('prueba.compra3'), ''), null,
  'A6. Un documento anulado se puede registrar de nuevo');

reset role;
select privado.registrar_movimiento('aaaaaaaa-0000-0000-0000-000000000000',
  current_setting('prueba.aceite')::uuid, 'VENTA', -30);
set local role authenticated;

select is(public.anular_compra(current_setting('prueba.compra3')::uuid, 'Error') -> 'error' ->> 'codigo',
  'STOCK_INSUFICIENTE',
  'A7. No se anula una compra cuyas unidades ya se vendieron');

select results_eq(
  $$ select (select estado from public.compras where id = current_setting('prueba.compra3')::uuid),
            (select cantidad from public.existencias where producto_id = current_setting('prueba.aceite')::uuid) $$,
  $$ values ('CONFIRMADA'::text, 4::numeric(14,3)) $$,
  'A8. La anulación rechazada no cambia ni la compra ni el stock');

select throws_ok(
  $$ insert into public.compras (empresa_id, fecha, con_respaldo, subtotal, descuento, iva, total, iva_es_costo, clave_idempotencia)
     values ('aaaaaaaa-0000-0000-0000-000000000000', current_date, false, 1, 0, 0, 1, true, gen_random_uuid()) $$,
  '42501', null,
  'A9. El Dueño no puede insertar compras directamente');

reset role;

-- =============================================================================
-- Compras inmutables (como servidor)
-- =============================================================================
select throws_ok(
  $$ update public.compras set total = 1 where id = current_setting('prueba.compra3')::uuid $$,
  'P0001', null,
  'I1. Una compra confirmada no se edita ni con privilegios de servidor');

select throws_ok(
  $$ delete from public.compras where id = current_setting('prueba.compra2')::uuid $$,
  'P0001', null,
  'I2. Una compra no se borra');

select throws_ok(
  $$ update public.compra_detalles set cantidad = 100 $$,
  'P0001', null,
  'I3. Las líneas de una compra no se editan');

select throws_ok(
  $$ update public.compras set estado = 'CONFIRMADA', motivo_anulacion = null, anulada_en = null
      where id = current_setting('prueba.compra1')::uuid $$,
  'P0001', null,
  'I4. Una compra anulada no vuelve a confirmarse');

select is_empty(
  $$ select x.producto_id
       from public.existencias x
       left join (select producto_id, sum(cantidad) c, sum(valor) v
                    from public.movimientos_inventario group by producto_id) m
         on m.producto_id = x.producto_id
      where x.cantidad <> coalesce(m.c, 0) or x.valor_total <> coalesce(m.v, 0) $$,
  'I5. Después de compras y anulaciones, existencias coincide con el libro');

-- =============================================================================
-- Vendedor de A
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);

select is_empty($$ select 1 from public.compras union all select 1 from public.proveedores $$,
  'V1. El Vendedor no ve compras ni proveedores');

select is(public.registrar_compra(null, false, null, null,
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.caja12'),
                                         'cantidad', 1, 'costo_unitario', 1)),
    gen_random_uuid()) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V2. El Vendedor no registra compras');

select is(public.calcular_compra('[]') -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V3. El Vendedor no usa la calculadora de compras (muestra costos)');

reset role;

-- =============================================================================
-- Dueño de B no toca nada de A
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);

select is(public.registrar_compra(null, false, null, null,
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.caja12'),
                                         'cantidad', 1, 'costo_unitario', 1)),
    gen_random_uuid()) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'B1. El Dueño de B no compra presentaciones de A');

select is(public.anular_compra(current_setting('prueba.compra3')::uuid, 'Intruso') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS',
  'B2. El Dueño de B no anula compras de A');

select is(public.guardar_proveedor(current_setting('prueba.prov')::uuid, '{"nombre":"Robado"}')
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'B3. El Dueño de B no edita proveedores de A');

reset role;

set local role anon;
select set_config('request.jwt.claims', '', true);
select throws_ok(
  $$ select public.registrar_compra(null, false, null, null, '[]', gen_random_uuid()) $$,
  '42501', null,
  'N1. Visitante sin sesión no registra compras');
reset role;

select * from finish();
rollback;
