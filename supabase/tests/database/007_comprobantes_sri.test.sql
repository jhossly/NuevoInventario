-- =============================================================================
-- Pruebas de importación de facturas del SRI (Fase 11)
--   * lectura: sobre de autorización con CDATA y factura sola; repetida
--   * rechazos: otro RUC, ambiente de pruebas, clave inválida, no autorizada,
--     DOCTYPE, texto que no es XML
--   * IVA por línea que no cuadra por centavos con el de la cabecera
--   * asociación por código de barras y memoria de códigos
--   * crear la venta desde el XML (montos exactos, stock, cliente, pagos)
--   * vincular a una venta registrada a mano (D-012) y no duplicar
--   * descartar, inmutabilidad, permisos y aislamiento
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(39);

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

-- -----------------------------------------------------------------------------
-- Generador de facturas XML como las del SRI (se arman como servidor, que
-- puede usar el cálculo del dígito verificador).
-- lineas: [{"codigo","descripcion","cantidad","precio","descuento"?,"tarifa"}]
-- -----------------------------------------------------------------------------
create function pg_temp.factura(
  p_secuencial int, p_fecha date, p_lineas jsonb,
  p_sobre boolean default true, p_ruc text default '0900000000001', p_ambiente text default '2',
  p_comprador jsonb default '{"tipo":"07","id":"9999999999999","nombre":"CONSUMIDOR FINAL"}',
  p_forma_pago text default '01', p_estado text default 'AUTORIZADO')
returns text
language plpgsql
as $$
declare
  v_base_clave text := to_char(p_fecha, 'DDMMYYYY') || '01' || p_ruc || p_ambiente || '001001'
                       || lpad(p_secuencial::text, 9, '0') || '12345678' || '1';
  v_clave text := v_base_clave || privado.digito_clave_acceso(v_base_clave);
  v_detalles text := '';
  v_impuestos text := '';
  v_base_tot numeric := 0;
  v_desc_tot numeric := 0;
  v_iva_tot numeric := 0;
  v_l jsonb;
  v_base numeric;
  v_iva numeric;
  t record;
  v_factura text;
begin
  for v_l in select * from jsonb_array_elements(p_lineas) loop
    v_base := round((v_l ->> 'cantidad')::numeric * (v_l ->> 'precio')::numeric - coalesce((v_l ->> 'descuento')::numeric, 0), 2);
    v_iva  := round(v_base * (v_l ->> 'tarifa')::numeric / 100, 2);
    v_base_tot := v_base_tot + v_base;
    v_desc_tot := v_desc_tot + coalesce((v_l ->> 'descuento')::numeric, 0);
    v_detalles := v_detalles || format(
      '<detalle><codigoPrincipal>%s</codigoPrincipal><descripcion>%s</descripcion><cantidad>%s</cantidad>'
      '<precioUnitario>%s</precioUnitario><descuento>%s</descuento><precioTotalSinImpuesto>%s</precioTotalSinImpuesto>'
      '<impuestos><impuesto><codigo>2</codigo><codigoPorcentaje>%s</codigoPorcentaje><tarifa>%s</tarifa>'
      '<baseImponible>%s</baseImponible><valor>%s</valor></impuesto></impuestos></detalle>',
      v_l ->> 'codigo', v_l ->> 'descripcion', v_l ->> 'cantidad', v_l ->> 'precio',
      coalesce(v_l ->> 'descuento', '0.00'), v_base, case when (v_l ->> 'tarifa')::numeric = 0 then '0' else '4' end,
      v_l ->> 'tarifa', v_base, v_iva);
  end loop;
  -- Como el SRI: el IVA de la cabecera se calcula sobre la base total por tarifa.
  for t in select (l ->> 'tarifa')::numeric as tarifa,
                  sum(round((l ->> 'cantidad')::numeric * (l ->> 'precio')::numeric - coalesce((l ->> 'descuento')::numeric, 0), 2)) as base
             from jsonb_array_elements(p_lineas) l group by 1 loop
    v_impuestos := v_impuestos || format(
      '<totalImpuesto><codigo>2</codigo><codigoPorcentaje>%s</codigoPorcentaje><baseImponible>%s</baseImponible><valor>%s</valor></totalImpuesto>',
      case when t.tarifa = 0 then '0' else '4' end, t.base, round(t.base * t.tarifa / 100, 2));
    v_iva_tot := v_iva_tot + round(t.base * t.tarifa / 100, 2);
  end loop;

  v_factura := format(
    '<?xml version="1.0" encoding="UTF-8"?><factura id="comprobante" version="1.1.0"><infoTributaria>'
    '<ambiente>%s</ambiente><tipoEmision>1</tipoEmision><razonSocial>Bodega A &amp; Hijos</razonSocial><ruc>%s</ruc>'
    '<claveAcceso>%s</claveAcceso><codDoc>01</codDoc><estab>001</estab><ptoEmi>001</ptoEmi>'
    '<secuencial>%s</secuencial><dirMatriz>Centro</dirMatriz></infoTributaria><infoFactura>'
    '<fechaEmision>%s</fechaEmision><tipoIdentificacionComprador>%s</tipoIdentificacionComprador>'
    '<razonSocialComprador>%s</razonSocialComprador><identificacionComprador>%s</identificacionComprador>'
    '<totalSinImpuestos>%s</totalSinImpuestos><totalDescuento>%s</totalDescuento>'
    '<totalConImpuestos>%s</totalConImpuestos><propina>0.00</propina><importeTotal>%s</importeTotal>'
    '<moneda>DOLAR</moneda><pagos><pago><formaPago>%s</formaPago><total>%s</total></pago></pagos></infoFactura>'
    '<detalles>%s</detalles></factura>',
    p_ambiente, p_ruc, v_clave, lpad(p_secuencial::text, 9, '0'), to_char(p_fecha, 'DD/MM/YYYY'),
    p_comprador ->> 'tipo', p_comprador ->> 'nombre', p_comprador ->> 'id',
    v_base_tot, v_desc_tot, v_impuestos, v_base_tot + v_iva_tot, p_forma_pago, v_base_tot + v_iva_tot, v_detalles);

  if not p_sobre then
    return v_factura;
  end if;
  return format('<?xml version="1.0" encoding="UTF-8"?><autorizacion><estado>%s</estado>'
                '<numeroAutorizacion>%s</numeroAutorizacion><fechaAutorizacion>2026-10-01T10:00:00-05:00</fechaAutorizacion>'
                '<ambiente>PRODUCCIÓN</ambiente><comprobante><![CDATA[%s]]></comprobante></autorizacion>',
                p_estado, v_clave, v_factura);
end;
$$;

-- Fecha de hoy en Ecuador: las ventas a mano se registran con esa fecha.
select set_config('prueba.hoy', (now() at time zone 'America/Guayaquil')::date::text, false);

select set_config('prueba.x1', pg_temp.factura(101, '2026-10-01',
  '[{"codigo":"ACE1","descripcion":"Aceite 1 L","cantidad":"3","precio":"3.00","tarifa":"15"},
    {"codigo":"Q-SRI","descripcion":"Queso fresco","cantidad":"1.25","precio":"6.00","tarifa":"0"}]',
  true, '0900000000001', '2', '{"tipo":"05","id":"0912345678","nombre":"MARÍA PÉREZ"}', '20'), false);
select set_config('prueba.x_otro_ruc', pg_temp.factura(102, '2026-10-01',
  '[{"codigo":"X","descripcion":"X","cantidad":"1","precio":"1","tarifa":"0"}]', true, '0999999999001'), false);
select set_config('prueba.x_pruebas', pg_temp.factura(103, '2026-10-01',
  '[{"codigo":"X","descripcion":"X","cantidad":"1","precio":"1","tarifa":"0"}]', true, '0900000000001', '1'), false);
select set_config('prueba.x_no_autorizado', pg_temp.factura(104, '2026-10-01',
  '[{"codigo":"X","descripcion":"X","cantidad":"1","precio":"1","tarifa":"0"}]', true, '0900000000001', '2',
  '{"tipo":"07","id":"9999999999999","nombre":"CONSUMIDOR FINAL"}', '01', 'NO AUTORIZADO'), false);
select set_config('prueba.x_sola', pg_temp.factura(105, '2026-10-02',
  '[{"codigo":"Q-SRI","descripcion":"Queso","cantidad":"1","precio":"6.00","tarifa":"0"}]', false), false);
-- Tres líneas de $0,10 con IVA: por línea 0,02 × 3 = 0,06; el SRI cobra 15 % de 0,30 = 0,05.
select set_config('prueba.x_centavos', pg_temp.factura(106, '2026-10-03',
  '[{"codigo":"ACE1","descripcion":"a","cantidad":"1","precio":"0.10","tarifa":"15"},
    {"codigo":"ACE1","descripcion":"b","cantidad":"1","precio":"0.10","tarifa":"15"},
    {"codigo":"ACE1","descripcion":"c","cantidad":"1","precio":"0.10","tarifa":"15"}]'), false);
select set_config('prueba.x_hoy', pg_temp.factura(107, current_setting('prueba.hoy')::date,
  '[{"codigo":"ACE1","descripcion":"Aceite 1 L","cantidad":"1","precio":"3.00","tarifa":"15"}]'), false);
select set_config('prueba.x_hoy2', pg_temp.factura(108, current_setting('prueba.hoy')::date,
  '[{"codigo":"ACE1","descripcion":"Aceite 1 L","cantidad":"1","precio":"3.00","tarifa":"15"}]'), false);
select set_config('prueba.x_descartar', pg_temp.factura(109, '2026-10-04',
  '[{"codigo":"X","descripcion":"X","cantidad":"1","precio":"1","tarifa":"0"}]'), false);

-- Catálogo, stock y caja del Dueño de A
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);
select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite 1 L","tarifa_iva":15,"precio_venta":3.45,"codigo_barras":"ACE1"}') -> 'data' ->> 'id', true);
select set_config('prueba.aceite_u', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.aceite')::uuid), true);
select set_config('prueba.queso', public.guardar_producto(null,
  '{"nombre":"Queso","unidad_base":"KG","tarifa_iva":0,"precio_venta":6.00}') -> 'data' ->> 'id', true);
select set_config('prueba.queso_kg', (select id::text from public.presentaciones
  where producto_id = current_setting('prueba.queso')::uuid), true);
select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 20, 2);
select public.ajustar_inventario(current_setting('prueba.queso')::uuid, 'APERTURA', 10, 4);
select public.abrir_caja(0);

-- =============================================================================
-- Importar
-- =============================================================================
select set_config('prueba.c1', coalesce(public.importar_comprobante(current_setting('prueba.x1')) -> 'data' ->> 'comprobante_id', ''), true);
select results_eq(
  $$ select numero, fecha_emision, subtotal::numeric, iva::numeric, total::numeric, identificacion_comprador
       from public.comprobantes where id = nullif(current_setting('prueba.c1'), '')::uuid $$,
  $$ values ('001-001-000000101'::text, '2026-10-01'::date, 16.50::numeric, 1.35::numeric, 17.85::numeric, '0912345678'::text) $$,
  'I1. Se lee la factura del sobre de autorización (CDATA): número, fecha, totales y comprador');

select results_eq(
  $$ select codigo, descripcion, cantidad::numeric, base::numeric, iva::numeric, presentacion_id is not null
       from public.comprobante_lineas where comprobante_id = current_setting('prueba.c1')::uuid order by orden $$,
  $$ values ('ACE1'::text, 'Aceite 1 L'::text, 3::numeric, 9.00::numeric, 1.35::numeric, true),
            ('Q-SRI', 'Queso fresco', 1.25, 7.50, 0, false) $$,
  'I2. Las líneas se leen; la del aceite se asocia sola por su código de barras');

select is(public.importar_comprobante(current_setting('prueba.x1')) -> 'data' ->> 'repetido', 'true',
  'I3. Importar el mismo XML dos veces no lo duplica');

select is((select cantidad from public.existencias where producto_id = current_setting('prueba.aceite')::uuid),
  20::numeric(14,3),
  'I4. Importar no toca el inventario');

select is(public.importar_comprobante(current_setting('prueba.x_otro_ruc')) -> 'error' ->> 'mensaje',
  'La factura no es de esta bodega (otro RUC)',
  'I5. Una factura de otro RUC (de un proveedor) se rechaza');

select is(public.importar_comprobante(current_setting('prueba.x_pruebas')) -> 'error' ->> 'mensaje',
  'La factura es del ambiente de pruebas del SRI',
  'I6. Una factura del ambiente de pruebas se rechaza');

select is(public.importar_comprobante(regexp_replace(current_setting('prueba.x_descartar'),
    '(<claveAcceso>[0-9]{48})([0-9])', '\1' || '0')) -> 'error' ->> 'mensaje',
  'La clave de acceso no es válida',
  'I7. Una clave de acceso con el dígito verificador alterado se rechaza');

select is(public.importar_comprobante(current_setting('prueba.x_no_autorizado')) -> 'error' ->> 'mensaje',
  'El comprobante no está autorizado por el SRI',
  'I8. Un comprobante no autorizado se rechaza');

select is(public.importar_comprobante('<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><x>&e;</x>')
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'I9. Un XML con DOCTYPE (entidades externas) se rechaza');

select is(public.importar_comprobante('esto no es xml') -> 'error' ->> 'mensaje', 'El archivo no es un XML válido',
  'I10. Un archivo que no es XML se rechaza');

select set_config('prueba.c_sola', coalesce(public.importar_comprobante(current_setting('prueba.x_sola')) -> 'data' ->> 'comprobante_id', ''), true);
select isnt(nullif(current_setting('prueba.c_sola'), ''), null,
  'I11. También se importa la factura sola, sin el sobre de autorización');

select set_config('prueba.c_centavos', coalesce(public.importar_comprobante(current_setting('prueba.x_centavos')) -> 'data' ->> 'comprobante_id', ''), true);
select results_eq(
  $$ select c.iva::numeric, (select sum(l.iva) from public.comprobante_lineas l where l.comprobante_id = c.id)
       from public.comprobantes c where c.id = current_setting('prueba.c_centavos')::uuid $$,
  $$ values (0.05::numeric, 0.05::numeric) $$,
  'I12. D-042: el centavo de diferencia del IVA se reparte para que las líneas cuadren con la cabecera');

-- =============================================================================
-- Asociar y crear la venta
-- =============================================================================
select is(public.crear_venta_de_comprobante(current_setting('prueba.c1')::uuid) -> 'error' ->> 'mensaje',
  'Asocia todas las líneas a un producto antes de crear la venta',
  'A1. No se crea la venta con líneas sin producto');

select is(public.asociar_linea_comprobante(
    (select id from public.comprobante_lineas where comprobante_id = current_setting('prueba.c1')::uuid and codigo = 'Q-SRI'),
    current_setting('prueba.queso_kg')::uuid) ->> 'ok', 'true',
  'A2. El Dueño asocia la línea del queso');

select is((select presentacion_id::text from public.comprobante_lineas
            where comprobante_id = current_setting('prueba.c_sola')::uuid), current_setting('prueba.queso_kg'),
  'A3. La asociación se aplica a otras facturas pendientes con el mismo código');

select is((select presentacion_id::text from public.codigos_sri where codigo = 'Q-SRI'), current_setting('prueba.queso_kg'),
  'A4. Y se recuerda para las próximas facturas');

select set_config('prueba.v1', coalesce(public.crear_venta_de_comprobante(current_setting('prueba.c1')::uuid) -> 'data' ->> 'venta_id', ''), true);
select results_eq(
  $$ select fecha, tipo_comprobante, subtotal::numeric, iva::numeric, total::numeric, caja_id is null
       from public.ventas where id = nullif(current_setting('prueba.v1'), '')::uuid $$,
  $$ values ('2026-10-01'::date, 'FACTURA'::text, 16.50::numeric, 1.35::numeric, 17.85::numeric, true) $$,
  'C1. La venta se crea con la fecha y los montos exactos de la factura, fuera de la caja (D-043)');

select results_eq(
  $$ select (select cantidad from public.existencias where producto_id = current_setting('prueba.aceite')::uuid),
            (select cantidad from public.existencias where producto_id = current_setting('prueba.queso')::uuid) $$,
  $$ values (17::numeric(14,3), 8.75::numeric(14,3)) $$,
  'C2. La venta descuenta 3 aceites y 1,25 kg de queso');

select results_eq(
  $$ select v.nombre, v.identificacion from public.clientes v
       join public.ventas x on x.cliente_id = v.id where x.id = current_setting('prueba.v1')::uuid $$,
  $$ values ('MARÍA PÉREZ'::text, '0912345678'::text) $$,
  'C3. El comprador se registra como cliente con su cédula');

select results_eq(
  $$ select medio, monto::numeric from public.venta_pagos where venta_id = current_setting('prueba.v1')::uuid $$,
  $$ values ('TRANSFERENCIA'::text, 17.85::numeric) $$,
  'C4. La forma de pago del XML (20) se registra como transferencia');

select results_eq(
  $$ select vinculo, venta_id::text from public.comprobantes where id = current_setting('prueba.c1')::uuid $$,
  $$ values ('CREADA'::text, current_setting('prueba.v1')) $$,
  'C5. El comprobante queda unido a la venta creada');

select is(public.crear_venta_de_comprobante(current_setting('prueba.c1')::uuid) -> 'data' ->> 'repetido', 'true',
  'C6. Crear la venta dos veces no descuenta dos veces');

-- =============================================================================
-- Vincular a una venta registrada a mano (D-012)
-- =============================================================================
select set_config('prueba.v_mano', public.registrar_venta(
  jsonb_build_array(jsonb_build_object('presentacion_id', current_setting('prueba.aceite_u'), 'cantidad', 1)),
  null, null, 'FACTURA', gen_random_uuid()) -> 'data' ->> 'venta_id', true);
select set_config('prueba.c_hoy', public.importar_comprobante(current_setting('prueba.x_hoy')) -> 'data' ->> 'comprobante_id', true);

select is((public.candidatos_comprobante(current_setting('prueba.c_hoy')::uuid) -> 'data' -> 'ventas' -> 0 ->> 'venta_id'),
  current_setting('prueba.v_mano'),
  'V1. D-012: la venta a mano del mismo día y el mismo total aparece como candidata');

select is(public.vincular_comprobante(current_setting('prueba.c_hoy')::uuid, current_setting('prueba.v_mano')::uuid) ->> 'ok',
  'true',
  'V2. El Dueño vincula la factura a la venta registrada a mano');

select is((select cantidad from public.existencias where producto_id = current_setting('prueba.aceite')::uuid),
  16::numeric(14,3),
  'V3. Vincular no descuenta stock otra vez (solo la venta a mano lo hizo)');

select set_config('prueba.c_hoy2', public.importar_comprobante(current_setting('prueba.x_hoy2')) -> 'data' ->> 'comprobante_id', true);
select is(jsonb_array_length(public.candidatos_comprobante(current_setting('prueba.c_hoy2')::uuid) -> 'data' -> 'ventas'), 0,
  'V4. Una venta ya vinculada no vuelve a ser candidata');

select is(public.vincular_comprobante(current_setting('prueba.c_hoy2')::uuid, current_setting('prueba.v_mano')::uuid)
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'V5. Una venta no se vincula a dos facturas');

select is(public.vincular_comprobante(current_setting('prueba.c_sola')::uuid, current_setting('prueba.v_mano')::uuid)
    -> 'error' ->> 'mensaje', 'La venta no es del mismo día o su total no coincide (D-012)',
  'V6. No se vincula una venta de otro día o con otro total');

-- =============================================================================
-- Descartar e inmutabilidad
-- =============================================================================
select set_config('prueba.c_desc', public.importar_comprobante(current_setting('prueba.x_descartar')) -> 'data' ->> 'comprobante_id', true);
select is(public.descartar_comprobante(current_setting('prueba.c_desc')::uuid) ->> 'ok', 'true',
  'D1. Un comprobante sin venta se puede descartar');
select is(public.descartar_comprobante(current_setting('prueba.c1')::uuid) -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'D2. Un comprobante con venta no se descarta');

reset role;

select throws_ok($$ update public.comprobantes set total = 1 where id = current_setting('prueba.c1')::uuid $$,
  'P0001', null, 'M1. Un comprobante no se edita ni con privilegios de servidor');
select throws_ok($$ delete from public.comprobantes where id = current_setting('prueba.c1')::uuid $$,
  'P0001', null, 'M2. Un comprobante con venta no se borra');
select throws_ok($$ update public.comprobante_lineas set cantidad = 99 where comprobante_id = current_setting('prueba.c_hoy2')::uuid $$,
  'P0001', null, 'M3. De una línea solo cambia el producto asociado');

select is_empty(
  $$ select x.producto_id
       from public.existencias x
       left join (select producto_id, sum(cantidad) c, sum(valor) v
                    from public.movimientos_inventario group by producto_id) m
         on m.producto_id = x.producto_id
      where x.cantidad <> coalesce(m.c, 0) or x.valor_total <> coalesce(m.v, 0) $$,
  'M4. Existencias sigue coincidiendo con el libro');

-- =============================================================================
-- Vendedor, Dueño de B y visitante
-- =============================================================================
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.importar_comprobante(current_setting('prueba.x_hoy2')) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'P1. El Vendedor no importa comprobantes (Fase 4)');
select is_empty($$ select 1 from public.comprobantes $$, 'P2. El Vendedor no ve comprobantes');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);
select is(public.vincular_comprobante(current_setting('prueba.c_hoy2')::uuid, current_setting('prueba.v_mano')::uuid)
    -> 'error' ->> 'codigo', 'DATOS_INVALIDOS',
  'P3. El Dueño de B no toca comprobantes de A');
select is(public.importar_comprobante(current_setting('prueba.x_hoy2')) -> 'error' ->> 'mensaje',
  'La factura no es de esta bodega (otro RUC)',
  'P4. El Dueño de B no puede importar facturas de A');
reset role;

set local role anon;
select set_config('request.jwt.claims', '', true);
select throws_ok($$ select public.importar_comprobante('<x/>') $$, '42501', null,
  'P5. Visitante sin sesión no importa');
reset role;

select * from finish();
rollback;
