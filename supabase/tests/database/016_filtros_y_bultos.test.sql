-- =============================================================================
-- Pruebas de proveedores por producto y bultos por peso (D-057)
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(7);

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

-- Factura con 3 sacos a $20 y 1 funda a $4, sin IVA.
create function pg_temp.factura(p_secuencial int)
returns text
language plpgsql
as $$
declare
  v_base_clave text := '01102026' || '01' || '1790000000001' || '2' || '001002'
                       || lpad(p_secuencial::text, 9, '0') || '12345678' || '1';
  v_clave text := v_base_clave || privado.digito_clave_acceso(v_base_clave);
  d text := '<detalle><codigoPrincipal>%s</codigoPrincipal><descripcion>%s</descripcion><cantidad>%s</cantidad>'
            '<precioUnitario>%s</precioUnitario><descuento>0.00</descuento><precioTotalSinImpuesto>%s</precioTotalSinImpuesto>'
            '<impuestos><impuesto><codigo>2</codigo><codigoPorcentaje>0</codigoPorcentaje><tarifa>0</tarifa>'
            '<baseImponible>%s</baseImponible><valor>0.00</valor></impuesto></impuestos></detalle>';
begin
  return format(
    '<factura id="comprobante" version="1.1.0"><infoTributaria><ambiente>2</ambiente><tipoEmision>1</tipoEmision>'
    '<razonSocial>Molinos</razonSocial><ruc>1790000000001</ruc><claveAcceso>%s</claveAcceso><codDoc>01</codDoc><estab>001</estab>'
    '<ptoEmi>002</ptoEmi><secuencial>%s</secuencial><dirMatriz>Quito</dirMatriz></infoTributaria><infoFactura>'
    '<fechaEmision>01/10/2026</fechaEmision><identificacionComprador>0900000000001</identificacionComprador>'
    '<totalSinImpuestos>64.00</totalSinImpuestos><totalDescuento>0.00</totalDescuento><totalConImpuestos><totalImpuesto>'
    '<codigo>2</codigo><codigoPorcentaje>0</codigoPorcentaje><baseImponible>64.00</baseImponible><valor>0.00</valor></totalImpuesto>'
    '</totalConImpuestos><propina>0.00</propina><importeTotal>64.00</importeTotal></infoFactura><detalles>%s%s</detalles></factura>',
    v_clave, lpad(p_secuencial::text, 9, '0'),
    format(d, 'ARROZ', 'Arroz saco', '3', '20.00', '60.00', '60.00'),
    format(d, 'AZU', 'Azucar funda', '1', '4.00', '4.00', '4.00'));
end;
$$;

select set_config('prueba.x1', pg_temp.factura(501), false);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select is(public.proveedores_de_productos() -> 'data', '[]'::jsonb, 'B1. Sin compras no hay proveedores que filtrar');

select set_config('prueba.r', public.registrar_compra_de_factura(current_setting('prueba.x1'), '[
  {"orden":1,"cantidad_recibida":"3","factor":"10","presentacion":"Saco 10 kg","nuevo":{"nombre":"Arroz","unidad_base":"KG","precio_venta":"1.10"}},
  {"orden":2,"cantidad_recibida":"1","factor":"2.267960","presentacion":"Saco 5 lb","nuevo":{"nombre":"Azúcar","unidad_base":"KG"}}]',
  gen_random_uuid())::text, true);
select is(current_setting('prueba.r')::jsonb ->> 'ok', 'true', 'B2. Se guarda la compra');

select results_eq(
  $$ select p.nombre, p.unidad_base, r.nombre, r.factor::numeric, r.se_vende
       from public.productos p join public.presentaciones r on r.producto_id = p.id
      where r.factor <> 1 order by p.nombre $$,
  $$ values ('Arroz'::text, 'KG'::text, 'Saco 10 kg'::text, 10::numeric, false),
            ('Azúcar', 'KG', 'Saco 5 lb', 2.26796, false) $$,
  'B3. Los productos quedan por kilo, con el bulto nombrado por su contenido');

select results_eq(
  $$ select p.nombre, x.cantidad from public.existencias x join public.productos p on p.id = x.producto_id order by p.nombre $$,
  $$ values ('Arroz'::text, 30::numeric(14,3)), ('Azúcar', 2.268) $$,
  'B4. 3 sacos de 10 kg son 30 kg; 5 libras son 2,268 kg');

reset role;
select results_eq(
  $$ select p.nombre, round(x.valor_total / x.cantidad, 2) from public.existencias x join public.productos p on p.id = x.producto_id
      where p.empresa_id = 'aaaaaaaa-0000-0000-0000-000000000000' order by p.nombre $$,
  $$ values ('Arroz'::text, 2.00::numeric), ('Azúcar', 1.76) $$,
  'B5. El costo queda por kilo: $60 ÷ 30 kg y $4 ÷ 2,268 kg');
set local role authenticated;

select results_eq(
  $$ select v ->> 'nombre', jsonb_array_length(v -> 'productos') from jsonb_array_elements(public.proveedores_de_productos() -> 'data') v $$,
  $$ values ('Molinos'::text, 2) $$,
  'B6. Cada proveedor con los productos que se le compraron');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.proveedores_de_productos() -> 'error' ->> 'codigo', 'SIN_PERMISO', 'B7. El Vendedor no ve proveedores');

select * from finish();
rollback;
