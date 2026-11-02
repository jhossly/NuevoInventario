-- =============================================================================
-- Pruebas de utilidad estimada de una compra (D-058)
--   * precio con IVA, costo con IVA e ICE, cajas, kilos, sin precio, pérdida
--   * coincide con la compra ya guardada; IVA 0 % vigente; no guarda nada
--   * permisos
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(13);

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

-- Línea 1: 2 cajas a $12 + IVA 15 % ($3,60). Línea 2: 1 saco a $20 sin IVA.
create function pg_temp.factura()
returns text
language plpgsql
as $$
declare
  v_base_clave text := '01102026' || '01' || '1790000000001' || '2' || '001002' || '000000601' || '12345678' || '1';
  v_clave text := v_base_clave || privado.digito_clave_acceso(v_base_clave);
begin
  return format(
    '<factura id="comprobante" version="1.1.0"><infoTributaria><ambiente>2</ambiente><tipoEmision>1</tipoEmision>'
    '<razonSocial>Prov</razonSocial><ruc>1790000000001</ruc><claveAcceso>%s</claveAcceso><codDoc>01</codDoc><estab>001</estab>'
    '<ptoEmi>002</ptoEmi><secuencial>000000601</secuencial><dirMatriz>Quito</dirMatriz></infoTributaria><infoFactura>'
    '<fechaEmision>01/10/2026</fechaEmision><identificacionComprador>0900000000001</identificacionComprador>'
    '<totalSinImpuestos>44.00</totalSinImpuestos><totalDescuento>0.00</totalDescuento><totalConImpuestos><totalImpuesto>'
    '<codigo>2</codigo><codigoPorcentaje>4</codigoPorcentaje><baseImponible>24.00</baseImponible><valor>3.60</valor></totalImpuesto>'
    '</totalConImpuestos><propina>0.00</propina><importeTotal>47.60</importeTotal></infoFactura><detalles>'
    '<detalle><codigoPrincipal>A</codigoPrincipal><descripcion>Aceite caja</descripcion><cantidad>2</cantidad><precioUnitario>12.00</precioUnitario>'
    '<descuento>0.00</descuento><precioTotalSinImpuesto>24.00</precioTotalSinImpuesto><impuestos><impuesto><codigo>2</codigo>'
    '<codigoPorcentaje>4</codigoPorcentaje><tarifa>15</tarifa><baseImponible>24.00</baseImponible><valor>3.60</valor></impuesto></impuestos></detalle>'
    '<detalle><codigoPrincipal>B</codigoPrincipal><descripcion>Arroz saco</descripcion><cantidad>1</cantidad><precioUnitario>20.00</precioUnitario>'
    '<descuento>0.00</descuento><precioTotalSinImpuesto>20.00</precioTotalSinImpuesto><impuestos><impuesto><codigo>2</codigo>'
    '<codigoPorcentaje>0</codigoPorcentaje><tarifa>0</tarifa><baseImponible>20.00</baseImponible><valor>0.00</valor></impuesto></impuestos></detalle>'
    '</detalles></factura>', v_clave);
end;
$$;
select set_config('prueba.x', pg_temp.factura(), false);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

-- Precio con IVA incluido: $3,45 son $3,00 de venta.
select set_config('prueba.aceite', public.guardar_producto(null,
  '{"nombre":"Aceite","codigo_iva":"4","precio_venta":3.45}') -> 'data' ->> 'id', true);

select set_config('prueba.l', jsonb_build_array(
  jsonb_build_object('orden', 1, 'cantidad_recibida', '2', 'factor', '6', 'producto_id', current_setting('prueba.aceite')),
  jsonb_build_object('orden', 2, 'cantidad_recibida', '1', 'factor', '10',
                     'nuevo', jsonb_build_object('nombre', 'Arroz', 'unidad_base', 'KG', 'precio_venta', '2.50')))::text, true);

select set_config('prueba.e', public.estimar_utilidad_factura(current_setting('prueba.x'), current_setting('prueba.l')::jsonb)::text, true);

select results_eq(
  $$ select l ->> 'nombre', (l ->> 'cantidad')::numeric, (l ->> 'costo_unidad')::numeric, (l ->> 'venta_unidad')::numeric, l ->> 'utilidad'
       from jsonb_array_elements(current_setting('prueba.e')::jsonb -> 'data' -> 'lineas') l order by (l ->> 'orden')::int $$,
  $$ values ('Aceite caja'::text, 12::numeric, 2.3::numeric, 3::numeric, '8.40'::text),
            ('Arroz saco', 10, 2, 2.5, '5.00') $$,
  'U1. Por línea: costo con IVA, venta sin IVA y utilidad');

select results_eq(
  $$ select r ->> 'costo', r ->> 'venta', r ->> 'utilidad', r ->> 'margen', r ->> 'sin_precio'
       from (select current_setting('prueba.e')::jsonb -> 'data' r) x $$,
  $$ values ('47.60'::text, '61.00'::text, '13.40'::text, '0.2197'::text, '0'::text) $$,
  'U2. Totales de la compra');

select is((select count(*)::int from public.compras), 0, 'U3. Estimar no guarda nada');

select results_eq(
  $$ select r ->> 'subtotal', r ->> 'iva', r ->> 'otros', r ->> 'total', r ->> 'total_factura'
       from (select current_setting('prueba.e')::jsonb -> 'data' -> 'compra' r) x $$,
  $$ values ('44.00'::text, '3.60'::text, '0.00'::text, '47.60'::text, '47.60'::text) $$,
  'T1. El total de la compra antes de guardar');

select results_eq(
  $$ select r ->> 'total', r ->> 'total_factura'
       from (select public.estimar_utilidad_factura(current_setting('prueba.x'), jsonb_build_array(
               jsonb_build_object('orden', 1, 'cantidad_recibida', '1', 'factor', '6', 'producto_id', current_setting('prueba.aceite')),
               jsonb_build_object('orden', 2, 'cantidad_recibida', '0'))) -> 'data' -> 'compra' r) x $$,
  $$ values ('13.80'::text, '47.60'::text) $$,
  'T2. Con lo recibido: llegó 1 de 2 cajas y el saco no llegó');

select results_eq(
  $$ select r ->> 'sin_precio', r ->> 'utilidad'
       from (select public.estimar_utilidad_factura(current_setting('prueba.x'), jsonb_build_array(
               jsonb_build_object('orden', 1, 'cantidad_recibida', '2', 'factor', '6', 'producto_id', current_setting('prueba.aceite')),
               jsonb_build_object('orden', 2, 'cantidad_recibida', '1', 'factor', '10', 'nuevo', jsonb_build_object('nombre', 'Arroz', 'precio_venta', '')))) -> 'data' r) x $$,
  $$ values ('1'::text, '8.40'::text) $$,
  'U4. Una línea sin precio se avisa y no suma');

select is((public.estimar_utilidad_factura(current_setting('prueba.x'), jsonb_build_array(
    jsonb_build_object('orden', 2, 'cantidad_recibida', '1', 'factor', '10', 'nuevo', jsonb_build_object('nombre', 'Arroz', 'precio_venta', '1.50'))))
    -> 'data' -> 'lineas' -> 0 ->> 'utilidad'), '-5.00', 'U5. Vender por debajo del costo da utilidad negativa');

select is(public.estimar_utilidad_factura(current_setting('prueba.x'), '[{"orden":1,"cantidad_recibida":"0"}]') -> 'data' ->> 'utilidad',
  '0.00', 'U6. Lo que no llegó no cuenta');

-- La estimación coincide con lo guardado
select set_config('prueba.c', public.registrar_compra_de_factura(current_setting('prueba.x'), current_setting('prueba.l')::jsonb, gen_random_uuid())
  -> 'data' ->> 'compra_id', true);
select set_config('prueba.d', public.utilidad_estimada_compra(current_setting('prueba.c')::uuid)::text, true);
select results_eq(
  $$ select r ->> 'costo', r ->> 'venta', r ->> 'utilidad' from (select current_setting('prueba.d')::jsonb -> 'data' r) x $$,
  $$ values ('47.60'::text, '61.00'::text, '13.40'::text) $$,
  'U7. Guardada, la compra da lo mismo que se estimó');

-- Con IVA 0 % vigente, todo el precio es venta
select public.fijar_iva_ventas((now() at time zone 'America/Guayaquil')::date, true);
select is(public.utilidad_estimada_compra(current_setting('prueba.c')::uuid) -> 'data' ->> 'venta', '66.40',
  'U8. Con IVA 0 %: 12 × $3,45 + 10 × $2,50');

-- Precio sin IVA incluido
select public.guardar_mi_negocio('{"precios_incluyen_iva":false}');
select public.fijar_iva_ventas((now() at time zone 'America/Guayaquil')::date, false);
select is(public.utilidad_estimada_compra(current_setting('prueba.c')::uuid) -> 'data' ->> 'venta', '66.40',
  'U9. Si el precio no incluye IVA, se toma completo');

select is(public.utilidad_estimada_compra('aaaaaaaa-0000-0000-0000-000000000009') -> 'error' ->> 'mensaje', 'La compra no existe',
  'U10. Una compra que no existe');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.utilidad_estimada_compra(current_setting('prueba.c')::uuid) -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'U11. El Vendedor no ve utilidades de compras');

select * from finish();
rollback;
