-- =============================================================================
-- Pruebas de importar la factura del proveedor como compra (D-054)
--   * rechazos: a nombre de otro, propia, pruebas, clave mala, no cuadra, repetida
--   * lectura: líneas, ICE/IRBPNR, centavo de IVA, productos reconocidos
--   * guardar: proveedor, productos y cajas nuevas, costo, stock, memoria
--   * lo recibido manda; omitir; todo o nada; permisos
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(28);

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

-- Factura de proveedor. lineas: [{"p","a","d","c","u","t","o"}]: código, auxiliar,
-- descripción, cantidad, unitario, tarifa, otros impuestos.
create function pg_temp.factura(
  p_secuencial int, p_lineas jsonb, p_ruc text default '1790000000001', p_comprador text default '0900000000001',
  p_ambiente text default '2', p_sumar_total numeric default 0)
returns text
language plpgsql
as $$
declare
  v_base_clave text := '01102026' || '01' || p_ruc || p_ambiente || '001002'
                       || lpad(p_secuencial::text, 9, '0') || '12345678' || '1';
  v_clave text := v_base_clave || privado.digito_clave_acceso(v_base_clave);
  v_det text := '';
  v_base_tot numeric := 0;
  v_iva_tot numeric := 0;
  v_otros_tot numeric := 0;
  v_l jsonb;
  v_base numeric;
  v_iva numeric;
  v_otros numeric;
begin
  for v_l in select * from jsonb_array_elements(p_lineas) loop
    v_base  := round((v_l ->> 'c')::numeric * (v_l ->> 'u')::numeric, 2);
    v_otros := coalesce((v_l ->> 'o')::numeric, 0);
    v_iva   := round((v_base + v_otros) * (v_l ->> 't')::numeric / 100, 2);
    v_base_tot := v_base_tot + v_base;
    v_iva_tot  := v_iva_tot + v_iva;
    v_otros_tot := v_otros_tot + v_otros;
    v_det := v_det || format(
      '<detalle><codigoPrincipal>%s</codigoPrincipal><codigoAuxiliar>%s</codigoAuxiliar><descripcion>%s</descripcion>'
      '<cantidad>%s</cantidad><precioUnitario>%s</precioUnitario><descuento>0.00</descuento>'
      '<precioTotalSinImpuesto>%s</precioTotalSinImpuesto><impuestos><impuesto><codigo>2</codigo>'
      '<codigoPorcentaje>%s</codigoPorcentaje><tarifa>%s</tarifa><baseImponible>%s</baseImponible><valor>%s</valor></impuesto>'
      '<impuesto><codigo>3</codigo><codigoPorcentaje>3051</codigoPorcentaje><tarifa>10</tarifa><baseImponible>%s</baseImponible><valor>%s</valor></impuesto>'
      '</impuestos></detalle>',
      v_l ->> 'p', v_l ->> 'a', v_l ->> 'd', v_l ->> 'c', v_l ->> 'u', v_base,
      case when (v_l ->> 't')::numeric = 0 then '0' else '4' end, v_l ->> 't', v_base + v_otros, v_iva, v_base, v_otros);
  end loop;

  return format(
    '<?xml version="1.0" encoding="UTF-8"?><autorizacion><estado>AUTORIZADO</estado><numeroAutorizacion>%s</numeroAutorizacion>'
    '<comprobante><![CDATA[<factura id="comprobante" version="1.1.0"><infoTributaria><ambiente>%s</ambiente><tipoEmision>1</tipoEmision>'
    '<razonSocial>Distribuidora &amp; Cía</razonSocial><ruc>%s</ruc><claveAcceso>%s</claveAcceso><codDoc>01</codDoc><estab>001</estab>'
    '<ptoEmi>002</ptoEmi><secuencial>%s</secuencial><dirMatriz>Quito</dirMatriz></infoTributaria><infoFactura>'
    '<fechaEmision>01/10/2026</fechaEmision><tipoIdentificacionComprador>04</tipoIdentificacionComprador>'
    '<razonSocialComprador>BODEGA A</razonSocialComprador><identificacionComprador>%s</identificacionComprador>'
    '<totalSinImpuestos>%s</totalSinImpuestos><totalDescuento>0.00</totalDescuento><totalConImpuestos><totalImpuesto><codigo>2</codigo>'
    '<codigoPorcentaje>4</codigoPorcentaje><baseImponible>%s</baseImponible><valor>%s</valor></totalImpuesto></totalConImpuestos>'
    '<propina>0.00</propina><importeTotal>%s</importeTotal><moneda>DOLAR</moneda></infoFactura><detalles>%s</detalles></factura>]]></comprobante></autorizacion>',
    v_clave, p_ambiente, p_ruc, v_clave, lpad(p_secuencial::text, 9, '0'), p_comprador,
    v_base_tot, v_base_tot, v_iva_tot, v_base_tot + v_iva_tot + v_otros_tot + p_sumar_total, v_det);
end;
$$;

select set_config('prueba.x1', pg_temp.factura(401,
  '[{"p":"COLA3","a":"7861000000011","d":"Cola 3L caja 6","c":"2","u":"12.00","t":"15","o":"1.20"},
    {"p":"ACE1","a":"7861001234567","d":"Aceite","c":"5","u":"2.00","t":"15"},
    {"p":"PROMO","a":"X","d":"Cola 3L caja 6","c":"1","u":"0.00","t":"15"}]'), false);
select set_config('prueba.x_ajena', pg_temp.factura(402, '[{"p":"A","a":"B","d":"X","c":"1","u":"1","t":"0"}]', '1790000000001', '0911111111001'), false);
select set_config('prueba.x_propia', pg_temp.factura(403, '[{"p":"A","a":"B","d":"X","c":"1","u":"1","t":"0"}]', '0900000000001'), false);
select set_config('prueba.x_pruebas', pg_temp.factura(404, '[{"p":"A","a":"B","d":"X","c":"1","u":"1","t":"0"}]', '1790000000001', '0900000000001', '1'), false);
select set_config('prueba.x_mal', pg_temp.factura(405, '[{"p":"A","a":"B","d":"X","c":"1","u":"1","t":"0"}]', '1790000000001', '0900000000001', '2', 5), false);
select set_config('prueba.x2', pg_temp.factura(406,
  '[{"p":"ACE1","a":"7861001234567","d":"Aceite","c":"10","u":"2.00","t":"0"},
    {"p":"NUEVO","a":"Y","d":"Otro","c":"4","u":"1.00","t":"0"}]'), false);
select set_config('prueba.x3', pg_temp.factura(407, '[{"p":"COLA3","a":"7861000000011","d":"Cola 3L caja 6","c":"1","u":"12.00","t":"0"}]'), false);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite vegetal","codigo_iva":"4","precio_venta":3.45,"codigo_barras":"7861001234567"}') -> 'data' ->> 'id', true);
select public.ajustar_inventario(current_setting('prueba.aceite')::uuid, 'APERTURA', 10, 3);

-- =============================================================================
-- Rechazos
-- =============================================================================
select is(public.leer_factura_proveedor(current_setting('prueba.x_ajena')) -> 'error' ->> 'mensaje',
  'La factura no está a nombre de esta bodega', 'R1. A nombre de otro comprador');
select is(public.leer_factura_proveedor(current_setting('prueba.x_propia')) -> 'error' ->> 'mensaje',
  'Esta factura la emitiste tú: súbela en Facturas SRI', 'R2. Una factura propia va a Facturas SRI');
select is(public.leer_factura_proveedor(current_setting('prueba.x_pruebas')) -> 'error' ->> 'mensaje',
  'La factura es del ambiente de pruebas del SRI', 'R3. Ambiente de pruebas');
select is(public.leer_factura_proveedor(current_setting('prueba.x_mal')) -> 'error' ->> 'mensaje',
  'Los valores de la factura no suman su total', 'R4. Los valores deben sumar el total');
select is(public.leer_factura_proveedor('<!DOCTYPE x><x/>') -> 'error' ->> 'mensaje',
  'El archivo no es un XML del SRI', 'R5. DOCTYPE');
select is(public.leer_factura_proveedor('hola') -> 'error' ->> 'mensaje', 'El archivo no es un XML válido', 'R6. Texto suelto');

-- =============================================================================
-- Lectura
-- =============================================================================
select set_config('prueba.l1', public.leer_factura_proveedor(current_setting('prueba.x1'))::text, true);
select results_eq(
  $$ select r -> 'data' ->> 'numero', r -> 'data' ->> 'razon_social', r -> 'data' ->> 'total', jsonb_array_length(r -> 'data' -> 'lineas')
       from (select current_setting('prueba.l1')::jsonb r) x $$,
  $$ values ('001-002-000000401'::text, 'Distribuidora & Cía'::text, '40.48'::text, 3) $$,
  'L1. Cabecera: 24 + 10 + ICE 1,20 + IVA 5,28');

select results_eq(
  $$ select l ->> 'descripcion', l ->> 'otros_impuestos', l ->> 'iva', l ->> 'producto'
       from jsonb_array_elements(current_setting('prueba.l1')::jsonb -> 'data' -> 'lineas') l order by (l ->> 'orden')::int $$,
  $$ values ('Cola 3L caja 6'::text, '1.20'::text, '3.78'::text, null::text),
            ('Aceite', '0', '1.50', 'Aceite vegetal'),
            ('Cola 3L caja 6', '0', '0.00', null) $$,
  'L2. Líneas con ICE y aceite reconocido por el código de barras auxiliar');

-- =============================================================================
-- Guardar
-- =============================================================================
select set_config('prueba.lineas', '[
  {"orden":1,"cantidad_recibida":"2","factor":6,"nuevo":{"nombre":"Cola 3L","precio_venta":"3.10"}},
  {"orden":2,"cantidad_recibida":"5","factor":1,"producto_id":"' || current_setting('prueba.aceite') || '"},
  {"orden":3,"cantidad_recibida":"1","factor":6,"nuevo":{"nombre":"Cola 3L"}}]', true);

select is(public.registrar_compra_de_factura(current_setting('prueba.x1'), '[{"orden":1,"cantidad_recibida":"2","factor":1,"producto_id":"aaaaaaaa-0000-0000-0000-000000000009"}]', gen_random_uuid()) -> 'error' ->> 'mensaje',
  'Cola 3L caja 6: elige el producto', 'G1. Un producto ajeno se rechaza');
select is((select count(*)::int from public.proveedores), 0, 'G2. Todo o nada: nada quedó guardado');

select set_config('prueba.clave', gen_random_uuid()::text, true);
select set_config('prueba.g1', public.registrar_compra_de_factura(current_setting('prueba.x1'),
  current_setting('prueba.lineas')::jsonb, current_setting('prueba.clave')::uuid)::text, true);
select results_eq(
  $$ select r ->> 'ok', r -> 'data' ->> 'total', r -> 'data' ->> 'total_factura', r -> 'data' ->> 'productos_nuevos'
       from (select current_setting('prueba.g1')::jsonb r) x $$,
  $$ values ('true'::text, '40.48'::text, '40.48'::text, '1'::text) $$,
  'G3. Coincide con la factura; la bonificación no crea otro producto');

select results_eq(
  $$ select p.nombre, p.tipo_identificacion, p.identificacion from public.proveedores p $$,
  $$ values ('Distribuidora & Cía'::text, 'RUC'::text, '1790000000001'::text) $$,
  'G4. Crea el proveedor desde la factura');

select results_eq(
  $$ select r.nombre, r.factor::numeric, r.se_vende, r.codigo_barras from public.presentaciones r
       join public.productos p on p.id = r.producto_id where p.nombre = 'Cola 3L' order by r.factor $$,
  $$ values ('Unidad'::text, 1::numeric, true, null::text), ('Caja 6', 6, false, '7861000000011') $$,
  'G5. Crea la presentación Caja 6, que no se vende, con el código de barras');

select is((select cantidad from public.existencias x join public.productos p on p.id = x.producto_id where p.nombre = 'Cola 3L'),
  18::numeric(14,3), 'G6. Entran 18 unidades: 2 cajas + 1 bonificada, de 6');

reset role;
select is((select round(valor_total, 2) from public.existencias x join public.productos p on p.id = x.producto_id where p.nombre = 'Cola 3L'),
  28.98::numeric, 'G7. El costo incluye ICE e IVA: 24 + 1,20 + 3,78; la bonificación entra a costo 0');
select results_eq(
  $$ select total, otros_impuestos, clave_acceso is not null, xml is not null from public.compras $$,
  $$ values (40.48::numeric(12,2), 1.20::numeric(12,2), true, true) $$,
  'G8. La compra guarda otros impuestos, clave y XML');
select is((select cantidad from public.existencias where producto_id = current_setting('prueba.aceite')::uuid),
  15::numeric(14,3), 'G9. El aceite suma a su stock');
set local role authenticated;

select is(public.registrar_compra_de_factura(current_setting('prueba.x1'), current_setting('prueba.lineas')::jsonb,
    current_setting('prueba.clave')::uuid) -> 'data' ->> 'repetido', 'true', 'G10. Doble clic: misma clave, misma compra');
select is(public.leer_factura_proveedor(current_setting('prueba.x1')) -> 'error' ->> 'mensaje',
  'Esta factura ya está registrada como compra', 'G11. La misma factura no se lee dos veces');
select is(public.registrar_compra_de_factura(current_setting('prueba.x1'), current_setting('prueba.lineas')::jsonb, gen_random_uuid()) -> 'error' ->> 'codigo',
  'DUPLICADO', 'G12. Ni se registra dos veces');

-- Lo que llegó manda
select public.guardar_presentacion(null, jsonb_build_object('producto_id', current_setting('prueba.aceite'), 'nombre', 'Caja 12', 'factor', 12));
select set_config('prueba.g2', public.registrar_compra_de_factura(current_setting('prueba.x2'), jsonb_build_array(
  jsonb_build_object('orden', 1, 'cantidad_recibida', '9', 'factor', 1, 'producto_id', current_setting('prueba.aceite')),
  jsonb_build_object('orden', 2, 'cantidad_recibida', '0')), gen_random_uuid())::text, true);
select results_eq(
  $$ select r -> 'data' ->> 'total', r -> 'data' ->> 'total_factura'
       from (select current_setting('prueba.g2')::jsonb r) x $$,
  $$ values ('18.00'::text, '24.00'::text) $$,
  'P1. Llegaron 9 de 10 y una línea no llegó: se registra lo recibido y queda el total de la factura');
select is((select cantidad from public.existencias where producto_id = current_setting('prueba.aceite')::uuid),
  24::numeric(14,3), 'P2. Entra solo lo recibido');

-- Memoria del proveedor
select results_eq(
  $$ select l ->> 'producto', l ->> 'factor' from jsonb_array_elements(
       public.leer_factura_proveedor(current_setting('prueba.x3')) -> 'data' -> 'lineas') l $$,
  $$ values ('Cola 3L'::text, '6.000000'::text) $$,
  'M1. La próxima factura ya sabe qué producto es y cuánto trae la caja');

reset role;
select is((select count(*)::int from public.movimientos_inventario m join public.compras c on c.id = m.origen_id), 4,
  'M2. Cada línea recibida entra al kardex');
set local role authenticated;

-- Anular y permisos
select is(public.anular_compra((select id from public.compras order by creado_en limit 1), 'Prueba') ->> 'ok', 'true',
  'A1. Una compra importada se anula igual que las otras');
select results_eq(
  $$ select r ->> 'ok' from (select public.leer_factura_proveedor(current_setting('prueba.x1')) r) x $$,
  $$ values ('true'::text) $$,
  'A2. Anulada, la factura se puede volver a leer');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.leer_factura_proveedor(current_setting('prueba.x1')) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'S1. El Vendedor no lee facturas de compra');
select is(public.registrar_compra_de_factura(current_setting('prueba.x1'), '[]', gen_random_uuid()) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'S2. Ni las registra');

select * from finish();
rollback;
