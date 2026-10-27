-- =============================================================================
-- Pruebas de clientes, ventas, anulaciones y devoluciones (Fase 8)
--   * cálculo con IVA incluido: aceite de la Fase 3, queso por kilo y por
--     libra (HU-02), descuento, precios sin IVA
--   * stock, idempotencia (HU-02), pagos, reglas del comprobante
--   * Vendedor: vende, no ve costos, no anula (solo pide), tope de descuento
--   * devoluciones parciales que cuadran, anulación (HU-03), inmutabilidad
--   * aislamiento entre empresas
-- La prueba de dos ventas simultáneas está en supabase/tests/concurrencia/.
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(63);

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
-- Catálogo y stock del Dueño de A: el aceite queda como en la Fase 3
-- (34 u, promedio $2,455294) y el queso con 10 kg a $4,00.
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite 1 L","tarifa_iva":15,"precio_venta":3.45}') -> 'data' ->> 'id', true);
select set_config('prueba.aceite_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid), true);
select set_config('prueba.caja12', public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.aceite'), 'nombre', 'Caja 12', 'factor', 12)) -> 'data' ->> 'id', true);
select set_config('prueba.queso', public.guardar_producto(null,
  '{"nombre":"Queso","unidad_base":"KG","tarifa_iva":0,"precio_venta":6.00}') -> 'data' ->> 'id', true);
select set_config('prueba.queso_kg', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.queso')::uuid), true);
select set_config('prueba.libra', public.guardar_presentacion(null, jsonb_build_object(
  'producto_id', current_setting('prueba.queso'), 'nombre', 'Libra', 'factor', 0.453592,
  'precio_venta', 2.75)) -> 'data' ->> 'id', true);

select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 10, 2);
select public.ajustar_inventario(current_setting('prueba.queso')::uuid, 'APERTURA', 10, 4);
reset role;
select privado.registrar_movimiento('aaaaaaaa-0000-0000-0000-000000000000',
  current_setting('prueba.aceite')::uuid, 'COMPRA', 24, 2.645);

-- =============================================================================
-- Clientes
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);

select set_config('prueba.cliente', coalesce(public.guardar_cliente(null,
  '{"tipo_identificacion":"CEDULA","identificacion":"0912345678","nombre":"María Pérez"}') -> 'data' ->> 'id', ''), true);
select isnt(nullif(current_setting('prueba.cliente'), ''), null,
  'K1. El Vendedor registra un cliente con cédula');

select is(public.guardar_cliente(current_setting('prueba.cliente')::uuid, '{"fiado_permitido":true}')
    -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'K2. El Vendedor no autoriza fiado');

select is(public.guardar_cliente(null, '{"tipo_identificacion":"CEDULA","identificacion":"123","nombre":"X"}')
    -> 'error' ->> 'mensaje', 'El RUC tiene 13 dígitos y la cédula 10',
  'K3. Una cédula mal escrita se rechaza con un mensaje claro');

select is(public.guardar_cliente(null, '{"nombre":"Vecino sin cédula"}') ->> 'ok', 'true',
  'K4. Un cliente puede no tener identificación');

-- =============================================================================
-- Cálculo (sin guardar), como Vendedor
-- =============================================================================
select results_eq(
  $$ select r -> 'data' ->> 'subtotal', r -> 'data' ->> 'iva', r -> 'data' ->> 'total'
       from (select public.calcular_venta(jsonb_build_array(jsonb_build_object(
               'presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 3))) r) x $$,
  $$ values ('9.00', '1.35', '10.35') $$,
  'C1. Fase 3: 3 aceites a $3,45 con IVA = $9,00 + $1,35');

select is(public.calcular_venta(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.queso_kg'), 'cantidad', 1.25))) -> 'data' ->> 'total', '7.50',
  'C2. HU-02: 1,250 kg de queso a $6,00/kg cobra $7,50');

select is(public.calcular_venta(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.libra'), 'cantidad', 2))) -> 'data' ->> 'total', '5.50',
  'C3. 2 libras de queso a $2,75 cobran $5,50');

select is(public.calcular_venta(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.caja12'), 'cantidad', 1))) -> 'error' ->> 'mensaje',
  'Aceite 1 L — Caja 12 no tiene precio de venta',
  'C4. Una presentación sin precio no se vende');

select is(public.calcular_venta(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1, 'descuento', 0.10)))
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'C5. El Vendedor no da descuento si el tope es 0 % (Fase 4)');

-- =============================================================================
-- Registro como Vendedor
-- =============================================================================
select set_config('prueba.venta1', coalesce(public.registrar_venta(
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 3)),
  null, null, null, 'dddddddd-0000-0000-0000-000000000001') -> 'data' ->> 'venta_id', ''), true);
select isnt(nullif(current_setting('prueba.venta1'), ''), null,
  'R1. El Vendedor registra la venta de 3 aceites, pagada en efectivo');

select is((select cantidad from public.existencias where producto_id = current_setting('prueba.aceite')::uuid),
  31::numeric(14,3),
  'R2. El stock del aceite baja de 34 a 31');

select results_eq(
  $$ select medio, monto::numeric from public.venta_pagos where venta_id = current_setting('prueba.venta1')::uuid $$,
  $$ values ('EFECTIVO'::text, 10.35::numeric) $$,
  'R3. Sin pagos indicados, se cobra todo en efectivo');

select is(public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 3)),
    null, null, null, 'dddddddd-0000-0000-0000-000000000001') -> 'data' ->> 'repetido', 'true',
  'R4. HU-02: tocar dos veces «Cobrar» devuelve la misma venta');

select is((select cantidad from public.existencias where producto_id = current_setting('prueba.aceite')::uuid),
  31::numeric(14,3),
  'R5. El segundo toque no descuenta stock otra vez');

select results_eq(
  $$ select r -> 'error' ->> 'codigo', r -> 'error' ->> 'mensaje'
       from (select public.registrar_venta(
               jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 40)),
               null, null, null, gen_random_uuid()) r) x $$,
  $$ values ('STOCK_INSUFICIENTE', 'No hay stock suficiente de Aceite 1 L (quedan 31)') $$,
  'R6. Sin stock suficiente se bloquea y dice cuánto queda (D-004)');

select is(public.registrar_venta(
    jsonb_build_array(
      jsonb_build_object('presentacion_id', current_setting('prueba.queso_kg'), 'cantidad', 1),
      jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 40)),
    null, null, null, gen_random_uuid()) -> 'error' ->> 'codigo', 'STOCK_INSUFICIENTE',
  'R7. Si una línea no tiene stock, se rechaza toda la venta');

select is((select cantidad from public.existencias where producto_id = current_setting('prueba.queso')::uuid),
  10::numeric(14,3),
  'R8. La venta rechazada no descontó el queso de la otra línea');

select is(public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1)),
    '[{"medio":"EFECTIVO","monto":3.00}]', null, null, gen_random_uuid()) -> 'error' ->> 'mensaje',
  'Los pagos no suman el total de la venta',
  'R9. Los pagos deben sumar el total');

select set_config('prueba.venta_mixta', coalesce(public.registrar_venta(
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.queso_kg'), 'cantidad', 1.25)),
  '[{"medio":"EFECTIVO","monto":5},{"medio":"TRANSFERENCIA","monto":2.50}]', null, null, gen_random_uuid())
  -> 'data' ->> 'venta_id', ''), true);
select is((select count(*)::int from public.venta_pagos where venta_id = nullif(current_setting('prueba.venta_mixta'), '')::uuid), 2,
  'R10. Una venta se paga con efectivo y transferencia');

select is(public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1)),
    '[{"medio":"FIADO","monto":3.45}]', current_setting('prueba.cliente')::uuid, null, gen_random_uuid())
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R11. El fiado todavía no se acepta (llega con la Fase 9)');

select is(public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 16)),
    null, null, 'FACTURA', gen_random_uuid()) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'R12. Una factura de $55,20 sin cliente identificado se rechaza (Decreto 586)');

select is(public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 16)),
    null, current_setting('prueba.cliente')::uuid, 'FACTURA', gen_random_uuid()) ->> 'ok', 'true',
  'R13. La misma factura con cliente identificado se registra');

select is(public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1)),
    null, null, 'NINGUNO_PERMITIDO', gen_random_uuid()) -> 'error' ->> 'mensaje',
  'Esta venta necesita comprobante',
  'R14. Sin configuración del contador, toda venta lleva comprobante (D-005)');

-- =============================================================================
-- Lo que ve y no hace el Vendedor
-- =============================================================================
select is((select count(*)::int from public.ventas), 3,
  'V1. El Vendedor ve sus ventas');

select throws_ok($$ select costo_total from public.ventas $$, '42501', null,
  'V2. El Vendedor no lee el costo de una venta');

select throws_ok($$ select costo_unitario from public.venta_detalles $$, '42501', null,
  'V3. El Vendedor no lee el costo de una línea');

select is(public.costos_venta(current_setting('prueba.venta1')::uuid) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V4. El Vendedor no pide la utilidad de una venta');

select is(public.anular_venta(current_setting('prueba.venta1')::uuid, 'Error') -> 'error' ->> 'codigo',
  'SIN_PERMISO',
  'V5. HU-03: el Vendedor no puede anular');

select is(public.solicitar_anulacion_venta(current_setting('prueba.venta1')::uuid, 'Cobré de más') ->> 'ok', 'true',
  'V6. HU-03: el Vendedor solicita la anulación');

select is(public.registrar_devolucion(current_setting('prueba.venta1')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id',
      (select id from public.venta_detalles where venta_id = current_setting('prueba.venta1')::uuid), 'cantidad', 1)),
    'x', null, gen_random_uuid()) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V7. El Vendedor no registra devoluciones (Fase 4)');

reset role;

-- =============================================================================
-- Dueño de A: costos, descuentos, devoluciones y anulación
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select is((select count(*)::int from public.ventas), 3,
  'D1. El Dueño ve todas las ventas, también las del Vendedor');

select results_eq(
  $$ select r -> 'data' ->> 'costo_total', r -> 'data' ->> 'utilidad'
       from (select public.costos_venta(current_setting('prueba.venta1')::uuid) r) x $$,
  $$ values ('7.365882', '1.634118') $$,
  'D2. Fase 3: costo $7,365882 y utilidad $1,634118 sobre $9,00');

select is((select solicitud_anulacion from public.ventas where id = current_setting('prueba.venta1')::uuid),
  'Cobré de más',
  'D3. El Dueño ve la solicitud de anulación');

select results_eq(
  $$ select r -> 'data' ->> 'subtotal', r -> 'data' ->> 'descuento', r -> 'data' ->> 'iva', r -> 'data' ->> 'total'
       from (select public.calcular_venta(jsonb_build_array(jsonb_build_object(
               'presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1, 'descuento', 0.45))) r) x $$,
  $$ values ('3.00', '0.39', '0.39', '3.00') $$,
  'D4. El Dueño descuenta $0,45 de $3,45: paga $3,00, base $2,61 e IVA $0,39');

reset role;
update public.empresas set precios_incluyen_iva = false where id = 'aaaaaaaa-0000-0000-0000-000000000000';
set local role authenticated;

select results_eq(
  $$ select r -> 'data' ->> 'iva', r -> 'data' ->> 'total'
       from (select public.calcular_venta(jsonb_build_array(jsonb_build_object(
               'presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1))) r) x $$,
  $$ values ('0.52', '3.97') $$,
  'D5. Si los precios no incluyen IVA: $3,45 + 15 % = $3,97');

reset role;
update public.empresas set precios_incluyen_iva = true where id = 'aaaaaaaa-0000-0000-0000-000000000000';
set local role authenticated;

select set_config('prueba.linea1', (select id::text from public.venta_detalles
  where venta_id = current_setting('prueba.venta1')::uuid), true);

select is(public.registrar_devolucion(current_setting('prueba.venta1')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id', current_setting('prueba.linea1'), 'cantidad', 4)),
    'Prueba', null, gen_random_uuid()) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'D6. Fase 3: no se devuelven 4 u de una venta de 3');

select set_config('prueba.dev1', coalesce(public.registrar_devolucion(current_setting('prueba.venta1')::uuid,
  jsonb_build_array(jsonb_build_object('venta_detalle_id', current_setting('prueba.linea1'), 'cantidad', 1)),
  'Botella abierta', null, 'eeeeeeee-0000-0000-0000-000000000001') -> 'data' ->> 'total', ''), true);
select is(current_setting('prueba.dev1'), '3.45',
  'D7. Devolver 1 de 3 aceites reintegra $3,45');

select results_eq(
  $$ select tipo, cantidad::numeric, costo_unitario::numeric
       from public.movimientos_inventario
      where producto_id = current_setting('prueba.aceite')::uuid and tipo = 'DEVOLUCION_VENTA' $$,
  $$ values ('DEVOLUCION_VENTA'::text, 1::numeric, 2.455294::numeric) $$,
  'D8. Fase 3, fila 5: la unidad vuelve al costo con que salió');

select is(public.registrar_devolucion(current_setting('prueba.venta1')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id', current_setting('prueba.linea1'), 'cantidad', 1)),
    'Botella abierta', null, 'eeeeeeee-0000-0000-0000-000000000001') -> 'data' ->> 'repetido', 'true',
  'D9. Reenviar la devolución con la misma clave no la duplica');

select is(public.registrar_devolucion(current_setting('prueba.venta1')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id', current_setting('prueba.linea1'), 'cantidad', 3)),
    'Prueba', null, gen_random_uuid()) -> 'error' ->> 'mensaje',
  'No se puede devolver más de lo vendido (quedan 2)',
  'D10. Después de devolver 1, solo quedan 2 por devolver');

select is(public.registrar_devolucion(current_setting('prueba.venta1')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id', current_setting('prueba.linea1'), 'cantidad', 2)),
    'Resto', null, gen_random_uuid()) -> 'data' ->> 'total', '6.90',
  'D11. Devolver las 2 restantes reintegra $6,90');

select results_eq(
  $$ select sum(total)::numeric, sum(subtotal)::numeric, sum(cantidad_base)::numeric
       from public.devolucion_detalles where venta_detalle_id = current_setting('prueba.linea1')::uuid $$,
  $$ values (10.35::numeric, 9.00::numeric, 3::numeric) $$,
  'D12. Las devoluciones suman exactamente la venta: $10,35, base $9,00, 3 u');

select is(public.anular_venta(current_setting('prueba.venta1')::uuid, 'Error') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS',
  'D13. Una venta con devoluciones no se anula');

select is(public.registrar_devolucion(current_setting('prueba.venta_mixta')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id',
      (select id from public.venta_detalles where venta_id = current_setting('prueba.venta_mixta')::uuid), 'cantidad', 1)),
    'x', 'ABONO_FIADO', gen_random_uuid()) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'D14. El reintegro como abono a fiado llega con la Fase 9');

-- $10,00 entre 3 unidades no da exacto: 3,33 + 3,33 + 3,34.
select set_config('prueba.venta10', public.registrar_venta(
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 3,
                                       'descuento', 0.35)),
  null, null, null, gen_random_uuid()) -> 'data' ->> 'venta_id', true);
select set_config('prueba.linea10', (select id::text from public.venta_detalles
  where venta_id = current_setting('prueba.venta10')::uuid), true);
select public.registrar_devolucion(current_setting('prueba.venta10')::uuid,
  jsonb_build_array(jsonb_build_object('venta_detalle_id', current_setting('prueba.linea10'), 'cantidad', 1)),
  'Una', null, gen_random_uuid())
  from generate_series(1, 3);
select results_eq(
  $$ select array_agg(d.total::numeric order by d.total), sum(d.total)::numeric
       from public.devolucion_detalles d
      where d.venta_detalle_id = current_setting('prueba.linea10')::uuid $$,
  $$ values (array[3.33, 3.33, 3.34]::numeric[], 10.00::numeric) $$,
  'D15. Tres devoluciones de 1 u de una venta de $10,00 suman $10,00, no $9,99');

select is(public.anular_venta(current_setting('prueba.venta_mixta')::uuid, '  ') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS',
  'A1. Anular necesita motivo');

select is(public.anular_venta(current_setting('prueba.venta_mixta')::uuid, 'Cliente se arrepintió') ->> 'ok', 'true',
  'A2. HU-03: el Dueño anula la venta del queso');

select results_eq(
  $$ select tipo, cantidad::numeric, costo_unitario::numeric
       from public.movimientos_inventario
      where origen_id = current_setting('prueba.venta_mixta')::uuid and tipo = 'ANULACION_VENTA' $$,
  $$ values ('ANULACION_VENTA'::text, 1.25::numeric, 4::numeric) $$,
  'A3. HU-03: el stock vuelve con un movimiento que referencia la venta, al costo con que salió');

select results_eq(
  $$ select estado, motivo_anulacion, anulada_por from public.ventas where id = current_setting('prueba.venta_mixta')::uuid $$,
  $$ values ('ANULADA'::text, 'Cliente se arrepintió'::text, '00000000-0000-0000-0000-00000000a001'::uuid) $$,
  'A4. HU-03: la venta queda ANULADA con motivo y usuario');

select is(public.anular_venta(current_setting('prueba.venta_mixta')::uuid, 'Otra vez') -> 'data' ->> 'repetido', 'true',
  'A5. Anular dos veces no hace nada');

select is(public.registrar_devolucion(current_setting('prueba.venta_mixta')::uuid,
    jsonb_build_array(jsonb_build_object('venta_detalle_id',
      (select id from public.venta_detalles where venta_id = current_setting('prueba.venta_mixta')::uuid), 'cantidad', 1)),
    'x', null, gen_random_uuid()) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'A6. No se devuelve una venta anulada');

select throws_ok(
  $$ insert into public.ventas (id, empresa_id, fecha, tipo_comprobante, subtotal, descuento, iva, total,
                                costo_total, precios_incluyen_iva, clave_idempotencia)
     values (gen_random_uuid(), 'aaaaaaaa-0000-0000-0000-000000000000', current_date, 'NOTA_VENTA',
             1, 0, 0, 1, 0, true, gen_random_uuid()) $$,
  '42501', null,
  'A7. El Dueño no puede insertar ventas directamente');

reset role;

-- =============================================================================
-- Inmutabilidad (como servidor)
-- =============================================================================
select throws_ok(
  $$ update public.ventas set total = 1 where id = current_setting('prueba.venta1')::uuid $$,
  'P0001', null,
  'I1. Una venta confirmada no se edita ni con privilegios de servidor');

select throws_ok(
  $$ delete from public.ventas where id = current_setting('prueba.venta1')::uuid $$,
  'P0001', null,
  'I2. Una venta no se borra');

select throws_ok(
  $$ update public.ventas set estado = 'CONFIRMADA', motivo_anulacion = null, anulada_en = null
      where id = current_setting('prueba.venta_mixta')::uuid $$,
  'P0001', null,
  'I3. Una venta anulada no vuelve a confirmarse');

select throws_ok(
  $$ update public.venta_detalles set cantidad = 100 $$,
  'P0001', null,
  'I4. Las líneas de una venta no se editan');

select throws_ok(
  $$ delete from public.devoluciones $$,
  'P0001', null,
  'I5. Las devoluciones no se borran');

select is_empty(
  $$ select x.producto_id
       from public.existencias x
       left join (select producto_id, sum(cantidad) c, sum(valor) v
                    from public.movimientos_inventario group by producto_id) m
         on m.producto_id = x.producto_id
      where x.cantidad <> coalesce(m.c, 0) or x.valor_total <> coalesce(m.v, 0) $$,
  'I6. Después de ventas, devoluciones y anulaciones, existencias coincide con el libro');

select is((select costo_total from public.ventas where id = current_setting('prueba.venta1')::uuid),
  7.365882::numeric(16,6),
  'I7. La venta guarda su costo total para los reportes');

-- =============================================================================
-- Dueño de B y visitante
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);

select is_empty($$ select 1 from public.ventas union all select 1 from public.clientes $$,
  'B1. El Dueño de B no ve ventas ni clientes de A');

select is(public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1)),
    null, null, null, gen_random_uuid()) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'B2. El Dueño de B no vende productos de A');

select is(public.anular_venta(current_setting('prueba.venta1')::uuid, 'Intruso') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS',
  'B3. El Dueño de B no anula ventas de A');

reset role;

set local role anon;
select set_config('request.jwt.claims', '', true);
select throws_ok(
  $$ select public.registrar_venta('[]', null, null, null, gen_random_uuid()) $$,
  '42501', null,
  'N1. Visitante sin sesión no registra ventas');
reset role;

select * from finish();
rollback;
