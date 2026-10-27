-- =============================================================================
-- Pruebas de datos del SRI en el producto e IVA de ventas por fecha
--   * código principal y auxiliar, información adicional; tarifas del SRI
--     (0 %, 5 %, 15 %, No objeto, Exento) y su código
--   * IVA de ventas por fecha: 0 % mientras rija, sin tocar la tarifa del
--     producto ni las ventas pasadas; cambios futuros; permisos
--   * facturas del SRI asociadas por código principal o auxiliar
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(34);

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

-- Factura XML mínima como las del SRI (todas las líneas con IVA 0 %).
-- lineas: [{"codigo","descripcion","cantidad","precio"}]
create function pg_temp.factura(p_secuencial int, p_fecha date, p_lineas jsonb)
returns text
language plpgsql
as $$
declare
  v_base_clave text := to_char(p_fecha, 'DDMMYYYY') || '01' || '0900000000001' || '2' || '001001'
                       || lpad(p_secuencial::text, 9, '0') || '12345678' || '1';
  v_clave text := v_base_clave || privado.digito_clave_acceso(v_base_clave);
  v_detalles text := '';
  v_base_tot numeric := 0;
  v_l jsonb;
  v_base numeric;
begin
  for v_l in select * from jsonb_array_elements(p_lineas) loop
    v_base := round((v_l ->> 'cantidad')::numeric * (v_l ->> 'precio')::numeric, 2);
    v_base_tot := v_base_tot + v_base;
    v_detalles := v_detalles || format(
      '<detalle><codigoPrincipal>%s</codigoPrincipal><descripcion>%s</descripcion><cantidad>%s</cantidad>'
      '<precioUnitario>%s</precioUnitario><descuento>0.00</descuento><precioTotalSinImpuesto>%s</precioTotalSinImpuesto>'
      '<impuestos><impuesto><codigo>2</codigo><codigoPorcentaje>0</codigoPorcentaje><tarifa>0</tarifa>'
      '<baseImponible>%s</baseImponible><valor>0.00</valor></impuesto></impuestos></detalle>',
      v_l ->> 'codigo', v_l ->> 'descripcion', v_l ->> 'cantidad', v_l ->> 'precio', v_base, v_base);
  end loop;

  return format(
    '<?xml version="1.0" encoding="UTF-8"?><factura id="comprobante" version="1.1.0"><infoTributaria>'
    '<ambiente>2</ambiente><tipoEmision>1</tipoEmision><razonSocial>Bodega A</razonSocial><ruc>0900000000001</ruc>'
    '<claveAcceso>%s</claveAcceso><codDoc>01</codDoc><estab>001</estab><ptoEmi>001</ptoEmi>'
    '<secuencial>%s</secuencial><dirMatriz>Centro</dirMatriz></infoTributaria><infoFactura>'
    '<fechaEmision>%s</fechaEmision><tipoIdentificacionComprador>07</tipoIdentificacionComprador>'
    '<razonSocialComprador>CONSUMIDOR FINAL</razonSocialComprador><identificacionComprador>9999999999999</identificacionComprador>'
    '<totalSinImpuestos>%s</totalSinImpuestos><totalDescuento>0.00</totalDescuento>'
    '<totalConImpuestos><totalImpuesto><codigo>2</codigo><codigoPorcentaje>0</codigoPorcentaje>'
    '<baseImponible>%s</baseImponible><valor>0.00</valor></totalImpuesto></totalConImpuestos>'
    '<propina>0.00</propina><importeTotal>%s</importeTotal><moneda>DOLAR</moneda>'
    '<pagos><pago><formaPago>01</formaPago><total>%s</total></pago></pagos></infoFactura>'
    '<detalles>%s</detalles></factura>',
    v_clave, lpad(p_secuencial::text, 9, '0'), to_char(p_fecha, 'DD/MM/YYYY'),
    v_base_tot, v_base_tot, v_base_tot, v_base_tot, v_detalles);
end;
$$;

select set_config('prueba.hoy', (now() at time zone 'America/Guayaquil')::date::text, false);
select set_config('prueba.x1', pg_temp.factura(201, '2026-10-01',
  '[{"codigo":"0065","descripcion":"Galletas","cantidad":"2","precio":"0.50"},
    {"codigo":"7861000000017","descripcion":"Galletas","cantidad":"1","precio":"0.50"},
    {"codigo":"REC128","descripcion":"Recarga","cantidad":"1","precio":"1.00"}]'), false);

-- Ayuda: venta de una presentación por transferencia (no necesita caja).
create function pg_temp.venta(p_pres text, p_monto numeric)
returns jsonb language sql as $$
  select public.registrar_venta(
    jsonb_build_array(jsonb_build_object('presentacion_id', p_pres, 'cantidad', 1)),
    jsonb_build_array(jsonb_build_object('medio', 'TRANSFERENCIA', 'monto', p_monto)),
    null, null, gen_random_uuid())
$$;
grant execute on function pg_temp.venta(text, numeric) to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

-- =============================================================================
-- Datos del SRI en el producto
-- =============================================================================
select set_config('prueba.aceite', coalesce(public.guardar_producto(null,
  '{"nombre":"Aceite 1 L","codigo_iva":"4","precio_venta":3.45,
    "codigo_principal":"  ACE-001 ","codigo_auxiliar":"7861001234567","informacion_adicional":"Botella plástica"}')
  -> 'data' ->> 'id', ''), true);
select results_eq(
  $$ select tarifa_iva, codigo_iva, codigo_principal, codigo_auxiliar, informacion_adicional
       from public.productos where id = nullif(current_setting('prueba.aceite'), '')::uuid $$,
  $$ values (15::numeric(5,2), '4'::text, 'ACE-001'::text, '7861001234567'::text, 'Botella plástica'::text) $$,
  'P1. Se guardan los datos del SRI; el código 4 es la tarifa 15 % y los códigos se recortan');
select set_config('prueba.aceite_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid), true);

select set_config('prueba.recarga', public.guardar_producto(null,
  '{"nombre":"Recarga","codigo_iva":"6","precio_venta":1.00,"codigo_principal":"REC128"}') -> 'data' ->> 'id', true);
select results_eq(
  $$ select tarifa_iva, codigo_iva from public.productos where id = current_setting('prueba.recarga')::uuid $$,
  $$ values (0::numeric(5,2), '6'::text) $$,
  'P2. No objeto de impuesto: tarifa 0, código 6');

select set_config('prueba.leche', public.guardar_producto(null,
  '{"nombre":"Leche","codigo_iva":"7","precio_venta":1.00}') -> 'data' ->> 'id', true);
select set_config('prueba.leche_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.leche')::uuid), true);
select results_eq(
  $$ select tarifa_iva, codigo_iva from public.productos where id = current_setting('prueba.leche')::uuid $$,
  $$ values (0::numeric(5,2), '7'::text) $$,
  'P3. Exento de IVA: tarifa 0, código 7');

select set_config('prueba.pan', public.guardar_producto(null,
  '{"nombre":"Pan","tarifa_iva":5,"precio_venta":0.20}') -> 'data' ->> 'id', true);
select is((select codigo_iva from public.productos where id = current_setting('prueba.pan')::uuid), '5',
  'P4. Quien manda solo la tarifa (5 %) recibe su código');

select is(public.guardar_producto(null, '{"nombre":"Otro","codigo_iva":"0","precio_venta":1,"codigo_principal":"ACE-001"}')
    -> 'error' ->> 'mensaje', 'El código principal ya está en uso',
  'P5. El código principal no se repite en la bodega');

select is(public.guardar_producto(null,
    '{"nombre":"Otro","codigo_iva":"0","precio_venta":1,"codigo_principal":"12345678901234567890123456"}')
    -> 'error' -> 'detalle' ->> 'restriccion', 'productos_codigo_principal_largo',
  'P6. El código principal tiene hasta 25 caracteres');

select is(public.guardar_producto(null, '{"nombre":"Otro","codigo_iva":"9","precio_venta":1}') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS',
  'P7. Un código de IVA que no existe se rechaza');

select public.guardar_producto(current_setting('prueba.pan')::uuid, '{"codigo_iva":"7"}');
select results_eq(
  $$ select tarifa_iva, codigo_iva from public.productos where id = current_setting('prueba.pan')::uuid $$,
  $$ values (0::numeric(5,2), '7'::text) $$,
  'P8. Al cambiar el código de IVA cambia la tarifa');

select public.guardar_producto(current_setting('prueba.pan')::uuid, '{"tarifa_iva":15}');
select results_eq(
  $$ select tarifa_iva, codigo_iva from public.productos where id = current_setting('prueba.pan')::uuid $$,
  $$ values (15::numeric(5,2), '4'::text) $$,
  'P9. Al cambiar solo la tarifa cambia el código');

select public.guardar_producto(current_setting('prueba.aceite')::uuid, '{"informacion_adicional":"  "}');
select is((select informacion_adicional from public.productos where id = current_setting('prueba.aceite')::uuid), null,
  'P10. Un texto en blanco borra la información adicional');

select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 20, 2);
select public.ajustar_inventario(current_setting('prueba.leche')::uuid, 'APERTURA', 20, 0.8);

-- =============================================================================
-- IVA de ventas por fecha
-- =============================================================================
select set_config('prueba.v1', pg_temp.venta(current_setting('prueba.aceite_u'), 3.45) -> 'data' ->> 'venta_id', true);
select results_eq(
  $$ select tarifa_iva, codigo_iva, subtotal - descuento, iva, total from public.venta_detalles
      where venta_id = current_setting('prueba.v1')::uuid $$,
  $$ values (15::numeric(5,2), '4'::text, 3.00::numeric, 0.45::numeric(12,2), 3.45::numeric(12,2)) $$,
  'V1. Sin configuración se cobra la tarifa del producto');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.fijar_iva_ventas(current_setting('prueba.hoy')::date, true) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'V2. El Vendedor no cambia el IVA de las ventas');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);
select is(public.fijar_iva_ventas(current_setting('prueba.hoy')::date - 1, true) -> 'error' ->> 'mensaje',
  'La fecha no puede ser anterior a hoy: las ventas pasadas no cambian',
  'V3. No se fija una fecha pasada');

select set_config('prueba.p_hoy', coalesce(public.fijar_iva_ventas(current_setting('prueba.hoy')::date, true,
  'Resolución del SRI') -> 'data' ->> 'id', ''), true);
select isnt(nullif(current_setting('prueba.p_hoy'), ''), null, 'V4. El Dueño fija «desde hoy, IVA 0 %»');

select set_config('prueba.v2', coalesce(pg_temp.venta(current_setting('prueba.aceite_u'), 3.45) -> 'data' ->> 'venta_id', ''), true);
select results_eq(
  $$ select tarifa_iva, codigo_iva, subtotal - descuento, iva, total from public.venta_detalles
      where venta_id = nullif(current_setting('prueba.v2'), '')::uuid $$,
  $$ values (0::numeric(5,2), '0'::text, 3.45::numeric, 0::numeric(12,2), 3.45::numeric(12,2)) $$,
  'V5. Mientras rige, la venta sale con IVA 0 %: el cliente paga lo mismo y todo es base');

select results_eq(
  $$ select subtotal, iva, total from public.ventas where id = nullif(current_setting('prueba.v2'), '')::uuid $$,
  $$ values (3.45::numeric(12,2), 0::numeric(12,2), 3.45::numeric(12,2)) $$,
  'V6. La cabecera de la venta también va sin IVA');

select is((select tarifa_iva from public.productos where id = current_setting('prueba.aceite')::uuid), 15::numeric(5,2),
  'V7. La tarifa del producto se conserva');

select is((select iva from public.ventas where id = current_setting('prueba.v1')::uuid), 0.45::numeric(12,2),
  'V8. Las ventas anteriores no cambian');

select set_config('prueba.v3', coalesce(pg_temp.venta(current_setting('prueba.leche_u'), 1.00) -> 'data' ->> 'venta_id', ''), true);
select is((select codigo_iva from public.venta_detalles where venta_id = nullif(current_setting('prueba.v3'), '')::uuid),
  '7', 'V9. Un producto exento sigue saliendo como exento');

select is((public.calcular_venta(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 2))) -> 'data' ->> 'iva')::numeric, 0::numeric,
  'V10. El cálculo previo de «Vender» también va sin IVA');

-- Corregir el mismo día: vuelve a cobrarse la tarifa
select is(public.fijar_iva_ventas(current_setting('prueba.hoy')::date, false) -> 'data' ->> 'id',
  current_setting('prueba.p_hoy'), 'V11. Fijar la misma fecha corrige esa fila');
select set_config('prueba.v4', coalesce(pg_temp.venta(current_setting('prueba.aceite_u'), 3.45) -> 'data' ->> 'venta_id', ''), true);
select is((select iva from public.ventas where id = nullif(current_setting('prueba.v4'), '')::uuid), 0.45::numeric(12,2),
  'V12. Sin IVA 0 % vigente, se vuelve a cobrar la tarifa del producto');

-- Cambio futuro
select public.fijar_iva_ventas(current_setting('prueba.hoy')::date, true);
select set_config('prueba.p_futuro', public.fijar_iva_ventas(current_setting('prueba.hoy')::date + 30, false)
  -> 'data' ->> 'id', true);
reset role;
select results_eq(
  $$ select privado.iva_cero_en('aaaaaaaa-0000-0000-0000-000000000000', d)
       from unnest(array[current_setting('prueba.hoy')::date - 1, current_setting('prueba.hoy')::date,
                         current_setting('prueba.hoy')::date + 29, current_setting('prueba.hoy')::date + 30]) d $$,
  $$ values (false), (true), (true), (false) $$,
  'V13. Cada fila rige desde su fecha hasta la siguiente');
set local role authenticated;

select is(public.quitar_iva_ventas(current_setting('prueba.p_hoy')::uuid) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'V14. El cambio de hoy no se quita (ya puede tener ventas)');
select is(public.quitar_iva_ventas(current_setting('prueba.p_futuro')::uuid) ->> 'ok', 'true',
  'V15. Un cambio que todavía no empieza se quita');
select is((select count(*)::int from public.iva_ventas_periodos), 1, 'V16. Queda solo el de hoy');

select is((select count(*)::int from public.auditoria where tabla = 'iva_ventas_periodos'), 5,
  'V17. Cada cambio queda en la auditoría');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is((select count(*)::int from public.iva_ventas_periodos), 1,
  'V18. El Vendedor ve el IVA vigente (para el aviso en «Vender»)');
select ok(has_column_privilege('authenticated', 'public.venta_detalles', 'codigo_iva', 'select'),
  'V19. El código de IVA de las líneas se puede leer');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);
select is((select count(*)::int from public.iva_ventas_periodos), 0, 'V20. Otra bodega no ve la configuración');
select ok((public.guardar_producto(null, '{"nombre":"Aceite","codigo_iva":"4","precio_venta":3.45,"codigo_principal":"ACE-001"}')
    ->> 'ok')::boolean,
  'P11. Otra bodega puede usar el mismo código principal');
select set_config('prueba.b_pres', (select r.id::text from public.presentaciones r
  join public.productos p on p.id = r.producto_id where p.empresa_id = 'bbbbbbbb-0000-0000-0000-000000000000'), true);
select is((public.calcular_venta(jsonb_build_array(jsonb_build_object(
    'presentacion_id', current_setting('prueba.b_pres'), 'cantidad', 1))) -> 'data' ->> 'iva')::numeric, 0.45::numeric,
  'V21. El IVA 0 % de una bodega no afecta a otra');

-- =============================================================================
-- Facturas del SRI: asociación por código principal o auxiliar
-- =============================================================================
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);
select public.guardar_producto(current_setting('prueba.aceite')::uuid,
  '{"codigo_principal":"0065","codigo_auxiliar":"7861000000017"}');
select public.guardar_producto(current_setting('prueba.recarga')::uuid, '{"activo":false}');
select set_config('prueba.c1', coalesce(public.importar_comprobante(current_setting('prueba.x1')) -> 'data' ->> 'comprobante_id', ''), true);
select results_eq(
  $$ select codigo, presentacion_id::text from public.comprobante_lineas
      where comprobante_id = nullif(current_setting('prueba.c1'), '')::uuid order by orden $$,
  $$ values ('0065'::text, current_setting('prueba.aceite_u')),
            ('7861000000017', current_setting('prueba.aceite_u')),
            ('REC128', null) $$,
  'C1. Se asocian por código principal y auxiliar; un producto inactivo no se asocia');

select is(public.importar_comprobante(current_setting('prueba.x1')) -> 'data' ->> 'repetido', 'true',
  'C2. Importar otra vez sigue sin duplicar');

select * from finish();
rollback;
