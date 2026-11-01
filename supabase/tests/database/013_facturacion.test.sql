-- =============================================================================
-- Pruebas de facturación electrónica (D-053)
--   * configuración, permisos y condiciones para emitir
--   * XML con la estructura del SRI: totales, IVA, cliente, pagos, escape
--   * clave de acceso y numeración sin saltos ni repetidos; pruebas ≠ producción
--   * reintentos, devolución, autorización inmutable
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(31);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a001', 'dueno.a@prueba.test'),
  ('00000000-0000-0000-0000-00000000a002', 'vendedor.a@prueba.test'),
  ('00000000-0000-0000-0000-00000000a003', 'vendedor2.a@prueba.test');

insert into public.empresas (id, ruc, razon_social, nombre_comercial) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '0900000000001', 'ROSA & HIJOS', 'Doña Rosa');

insert into public.perfiles (id, nombre) values
  ('00000000-0000-0000-0000-00000000a001', 'Dueño A'),
  ('00000000-0000-0000-0000-00000000a002', 'Vendedor A'),
  ('00000000-0000-0000-0000-00000000a003', 'Vendedor B');

insert into public.membresias (empresa_id, usuario_id, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a001', 'DUENO'),
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a002', 'VENDEDOR'),
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a003', 'VENDEDOR');

create function pg_temp.venta(p_lineas jsonb, p_monto numeric, p_tipo text default 'FACTURA', p_cliente uuid default null)
returns uuid language sql as $$
  select (public.registrar_venta(p_lineas,
    jsonb_build_array(jsonb_build_object('medio', 'TRANSFERENCIA', 'monto', p_monto)),
    p_cliente, p_tipo, gen_random_uuid()) -> 'data' ->> 'venta_id')::uuid
$$;
grant execute on function pg_temp.venta(jsonb, numeric, text, uuid) to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite <1L>","codigo_iva":"4","precio_venta":3.45,"codigo_principal":"ACE-1","codigo_auxiliar":"786"}') -> 'data' ->> 'id', true);
select set_config('prueba.aceite_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid), true);
select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 50, 2);
select set_config('prueba.recarga', public.guardar_producto(null,
  '{"nombre":"Recarga","codigo_iva":"6","precio_venta":1,"controla_stock":false}') -> 'data' ->> 'id', true);
select set_config('prueba.recarga_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.recarga')::uuid), true);
select set_config('prueba.cliente', public.guardar_cliente(null,
  '{"nombre":"María & Cía","tipo_identificacion":"CEDULA","identificacion":"0912345678","correo":"maria@correo.test","direccion":"Calle 1"}')
  -> 'data' ->> 'id', true);

select set_config('prueba.l1', jsonb_build_array(
  jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 2),
  jsonb_build_object('presentacion_id', current_setting('prueba.recarga_u'), 'cantidad', 1))::text, true);
select set_config('prueba.v1', pg_temp.venta(current_setting('prueba.l1')::jsonb, 7.90, 'FACTURA', current_setting('prueba.cliente')::uuid)::text, true);

-- =============================================================================
-- Condiciones
-- =============================================================================
select is(public.preparar_factura(current_setting('prueba.v1')::uuid) -> 'error' ->> 'mensaje',
  'La facturación electrónica no está activa: actívala en Mi negocio', 'F1. Apagada por defecto');

select public.guardar_facturacion('{"facturacion_activa":true}');
select is(public.preparar_factura(current_setting('prueba.v1')::uuid) -> 'error' ->> 'mensaje',
  'Completa la razón social y la dirección en Mi negocio', 'F2. Sin dirección no se emite');
select public.guardar_mi_negocio('{"direccion":"Av. Principal 123"}');

select set_config('prueba.nota', pg_temp.venta(jsonb_build_array(jsonb_build_object(
  'presentacion_id', current_setting('prueba.recarga_u'), 'cantidad', 1)), 1, 'NOTA_VENTA')::text, true);
select is(public.preparar_factura(current_setting('prueba.nota')::uuid) -> 'error' ->> 'mensaje',
  'Esta venta no se registró como factura', 'F3. Una nota de venta no se factura');

select is(public.guardar_facturacion('{"punto_emision":"12"}') -> 'error' ->> 'mensaje',
  'El punto de emisión lleva 3 dígitos', 'F4. Punto de emisión de 3 dígitos');
select public.guardar_facturacion('{"punto_emision":"101"}');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.guardar_facturacion('{"ambiente_sri":"2"}') -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'F5. El Vendedor no cambia la configuración');
select is(public.preparar_factura(current_setting('prueba.v1')::uuid) -> 'error' ->> 'mensaje', 'La venta no existe',
  'F6. El Vendedor no factura ventas ajenas');
select set_config('prueba.v2', pg_temp.venta(jsonb_build_array(jsonb_build_object(
  'presentacion_id', current_setting('prueba.recarga_u'), 'cantidad', 1)), 1)::text, true);
select is(public.preparar_factura(current_setting('prueba.v2')::uuid) -> 'data' ->> 'numero', '001-101-000000001',
  'F7. El Vendedor factura su venta, con el primer número');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

-- =============================================================================
-- XML y clave
-- =============================================================================
select set_config('prueba.r1', public.preparar_factura(current_setting('prueba.v1')::uuid)::text, true);
select set_config('prueba.xml', current_setting('prueba.r1')::jsonb -> 'data' ->> 'xml', true);
select set_config('prueba.clave', current_setting('prueba.r1')::jsonb -> 'data' ->> 'clave_acceso', true);

select is(current_setting('prueba.r1')::jsonb -> 'data' ->> 'numero', '001-101-000000002', 'X1. Número siguiente');
select ok(xml_is_well_formed_document(current_setting('prueba.xml')), 'X2. El XML está bien formado');
select ok(current_setting('prueba.xml') !~ '\n', 'X3. Va en una sola línea, listo para firmar');
select ok(current_setting('prueba.clave') ~ '^[0-9]{49}$', 'X4. La clave tiene 49 dígitos');

reset role;
select is(right(current_setting('prueba.clave'), 1), privado.digito_clave_acceso(left(current_setting('prueba.clave'), 48))::text,
  'X5. El dígito verificador es correcto');
select is(substr(current_setting('prueba.clave'), 9, 15), '010900000000001', 'X6. Tipo de comprobante y RUC en la clave');
select is(substr(current_setting('prueba.clave'), 24, 16), '1001101000000002', 'X7. Ambiente de pruebas, punto y secuencial en la clave');

-- Se relee con el mismo lector de las facturas importadas.
create function pg_temp.valor(p_ruta text) returns text language sql as $$
  select privado.xml_texto(current_setting('prueba.xml')::xml, p_ruta)
$$;
select results_eq(
  $$ select pg_temp.valor('/factura/infoTributaria/razonSocial'), pg_temp.valor('/factura/infoTributaria/ambiente'),
            pg_temp.valor('/factura/infoTributaria/contribuyenteRimpe'), pg_temp.valor('/factura/infoFactura/obligadoContabilidad') $$,
  $$ values ('ROSA & HIJOS'::text, '1'::text, 'CONTRIBUYENTE NEGOCIO POPULAR - RÉGIMEN RIMPE'::text, 'NO'::text) $$,
  'X8. Emisor, ambiente y leyenda RIMPE (con & escapado)');
select results_eq(
  $$ select pg_temp.valor('/factura/infoFactura/tipoIdentificacionComprador'), pg_temp.valor('/factura/infoFactura/identificacionComprador'),
            pg_temp.valor('/factura/infoFactura/razonSocialComprador'), pg_temp.valor('/factura/infoFactura/direccionComprador') $$,
  $$ values ('05'::text, '0912345678'::text, 'María & Cía'::text, 'Calle 1'::text) $$,
  'X9. Comprador con cédula');
select results_eq(
  $$ select pg_temp.valor('/factura/infoFactura/totalSinImpuestos'), pg_temp.valor('/factura/infoFactura/importeTotal'),
            pg_temp.valor('/factura/infoFactura/pagos/pago/formaPago'), pg_temp.valor('/factura/infoFactura/pagos/pago/total') $$,
  $$ values ('7.00'::text, '7.90'::text, '20'::text, '7.90'::text) $$,
  'X10. Totales y pago por transferencia');
select results_eq(
  $$ select (xpath('/*/codigoPorcentaje/text()', t))[1]::text, (xpath('/*/baseImponible/text()', t))[1]::text, (xpath('/*/valor/text()', t))[1]::text
       from unnest(xpath('/factura/infoFactura/totalConImpuestos/totalImpuesto', current_setting('prueba.xml')::xml)) t $$,
  $$ values ('4'::text, '6.00'::text, '0.90'::text), ('6', '1.00', '0.00') $$,
  'X11. Impuestos agrupados: 15 % y No objeto por separado');
select results_eq(
  $$ select (xpath('/*/codigoPrincipal/text()', d))[1]::text, (xpath('/*/codigoAuxiliar/text()', d))[1]::text,
            (xpath('/*/cantidad/text()', d))[1]::text, (xpath('/*/precioUnitario/text()', d))[1]::text,
            (xpath('/*/precioTotalSinImpuesto/text()', d))[1]::text
       from unnest(xpath('/factura/detalles/detalle', current_setting('prueba.xml')::xml)) d limit 1 $$,
  $$ values ('ACE-1'::text, '786'::text, '2.000000'::text, '3.000000'::text, '6.00'::text) $$,
  'X12. Línea: códigos, cantidad, precio sin IVA y total');
select ok(current_setting('prueba.xml') like '%Aceite &lt;1L&gt;%', 'X13. El texto se escapa');
select ok(current_setting('prueba.xml') not like '%<direccionComprador></direccionComprador>%', 'X14. Sin etiquetas vacías');
set local role authenticated;

-- =============================================================================
-- Reintentos y estados
-- =============================================================================
select is(public.preparar_factura(current_setting('prueba.v1')::uuid) -> 'data' ->> 'clave_acceso', current_setting('prueba.clave'),
  'E1. Repetir no gasta otro número');

select set_config('prueba.f1', current_setting('prueba.r1')::jsonb -> 'data' ->> 'id', true);
select throws_ok($$ select public.registrar_resultado_factura(current_setting('prueba.f1')::uuid, '{"estado":"AUTORIZADA"}') $$,
  '42501', null, 'E2. El navegador no registra una autorización');

reset role;
select public.registrar_resultado_factura(current_setting('prueba.f1')::uuid,
  '{"estado":"DEVUELTA","xml_firmado":"<firmado/>","mensajes":[{"identificador":"35"}]}');
set local role authenticated;
select results_eq(
  $$ select r -> 'data' ->> 'estado', r -> 'data' ->> 'xml_firmado', r -> 'data' ->> 'clave_acceso'
       from (select public.preparar_factura(current_setting('prueba.v1')::uuid) r) x $$,
  $$ values ('PENDIENTE'::text, null::text, current_setting('prueba.clave')) $$,
  'E3. Una devuelta se regenera con la misma clave y sin firma vieja');

reset role;
select public.registrar_resultado_factura(current_setting('prueba.f1')::uuid,
  '{"estado":"AUTORIZADA","numero_autorizacion":"123","fecha_autorizacion":"2026-10-31T10:00:00-05:00"}');
select throws_ok($$ select public.registrar_resultado_factura(current_setting('prueba.f1')::uuid, '{"estado":"DEVUELTA"}') $$,
  'P0001', 'Una factura electrónica no se cambia ni se borra', 'E4. Una autorizada no cambia');
select throws_ok($$ delete from public.facturas_electronicas where id = current_setting('prueba.f1')::uuid $$,
  'P0001', 'Una factura electrónica no se cambia ni se borra', 'E5. Una autorizada no se borra');
set local role authenticated;
select is(public.preparar_factura(current_setting('prueba.v1')::uuid) -> 'data' ->> 'estado', 'AUTORIZADA',
  'E6. Pedirla otra vez devuelve la autorizada');

-- Producción: su propia numeración, desde el último número del portal
select is(public.guardar_facturacion('{"ultimo_secuencial":1}') -> 'error' ->> 'mensaje', 'Ya hay facturas con un número mayor',
  'N1. El número no retrocede');
select public.guardar_facturacion('{"ambiente_sri":"2","ultimo_secuencial":1529}');
select set_config('prueba.v3', pg_temp.venta(jsonb_build_array(jsonb_build_object(
  'presentacion_id', current_setting('prueba.recarga_u'), 'cantidad', 1)), 1)::text, true);
select is(public.preparar_factura(current_setting('prueba.v3')::uuid) -> 'data' ->> 'numero', '001-101-000001530',
  'N2. Producción sigue desde el último número indicado');

select is((public.mi_contexto() -> 'data' ->> 'ambiente_sri'), '2', 'N3. La sesión sabe en qué ambiente está');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a003","role":"authenticated"}', true);
select is((select count(*)::int from public.facturas_electronicas), 0, 'N4. Otro Vendedor no ve facturas ajenas');

select * from finish();
rollback;
