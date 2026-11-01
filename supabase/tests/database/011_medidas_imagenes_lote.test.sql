-- =============================================================================
-- Pruebas de medidas propias, imagen del producto y creación en lote
--   * medidas iniciales, crear, renombrar, borrar y sus límites
--   * producto en paquetes: presentación base con el nombre de la medida
--   * imagen: ruta dentro de la carpeta de la bodega
--   * crear productos desde líneas: datos, precio con IVA, mismo código,
--     mismo nombre, sin stock, todo o nada, permisos y aislamiento
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(24);

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

-- Factura XML como las del SRI. lineas: [{"codigo","descripcion","cantidad","precio","tarifa"}]
create function pg_temp.factura(p_secuencial int, p_lineas jsonb)
returns text
language plpgsql
as $$
declare
  v_base_clave text := '01102026' || '01' || '0900000000001' || '2' || '001001'
                       || lpad(p_secuencial::text, 9, '0') || '12345678' || '1';
  v_clave text := v_base_clave || privado.digito_clave_acceso(v_base_clave);
  v_detalles text := '';
  v_impuestos text := '';
  v_base_tot numeric := 0;
  v_iva_tot numeric := 0;
  v_l jsonb;
  v_base numeric;
  v_iva numeric;
  v_cod text;
begin
  for v_l in select * from jsonb_array_elements(p_lineas) loop
    v_base := round((v_l ->> 'cantidad')::numeric * (v_l ->> 'precio')::numeric, 2);
    v_iva  := round(v_base * (v_l ->> 'tarifa')::numeric / 100, 2);
    v_cod  := case when (v_l ->> 'tarifa')::numeric = 0 then '0' else '4' end;
    v_base_tot := v_base_tot + v_base;
    v_iva_tot  := v_iva_tot + v_iva;
    v_detalles := v_detalles || format(
      '<detalle><codigoPrincipal>%s</codigoPrincipal><descripcion>%s</descripcion><cantidad>%s</cantidad>'
      '<precioUnitario>%s</precioUnitario><descuento>0.00</descuento><precioTotalSinImpuesto>%s</precioTotalSinImpuesto>'
      '<impuestos><impuesto><codigo>2</codigo><codigoPorcentaje>%s</codigoPorcentaje><tarifa>%s</tarifa>'
      '<baseImponible>%s</baseImponible><valor>%s</valor></impuesto></impuestos></detalle>',
      v_l ->> 'codigo', v_l ->> 'descripcion', v_l ->> 'cantidad', v_l ->> 'precio', v_base, v_cod,
      v_l ->> 'tarifa', v_base, v_iva);
    v_impuestos := v_impuestos || format(
      '<totalImpuesto><codigo>2</codigo><codigoPorcentaje>%s</codigoPorcentaje><baseImponible>%s</baseImponible><valor>%s</valor></totalImpuesto>',
      v_cod, v_base, v_iva);
  end loop;

  return format(
    '<?xml version="1.0" encoding="UTF-8"?><factura id="comprobante" version="1.1.0"><infoTributaria>'
    '<ambiente>2</ambiente><tipoEmision>1</tipoEmision><razonSocial>Bodega A</razonSocial><ruc>0900000000001</ruc>'
    '<claveAcceso>%s</claveAcceso><codDoc>01</codDoc><estab>001</estab><ptoEmi>001</ptoEmi>'
    '<secuencial>%s</secuencial><dirMatriz>Centro</dirMatriz></infoTributaria><infoFactura>'
    '<fechaEmision>01/10/2026</fechaEmision><tipoIdentificacionComprador>07</tipoIdentificacionComprador>'
    '<razonSocialComprador>CONSUMIDOR FINAL</razonSocialComprador><identificacionComprador>9999999999999</identificacionComprador>'
    '<totalSinImpuestos>%s</totalSinImpuestos><totalDescuento>0.00</totalDescuento>'
    '<totalConImpuestos>%s</totalConImpuestos><propina>0.00</propina><importeTotal>%s</importeTotal><moneda>DOLAR</moneda>'
    '<pagos><pago><formaPago>01</formaPago><total>%s</total></pago></pagos></infoFactura><detalles>%s</detalles></factura>',
    v_clave, lpad(p_secuencial::text, 9, '0'), v_base_tot, v_impuestos,
    v_base_tot + v_iva_tot, v_base_tot + v_iva_tot, v_detalles);
end;
$$;

select set_config('prueba.x1', pg_temp.factura(301,
  '[{"codigo":"G-1","descripcion":"Galletas","cantidad":"2","precio":"0.50","tarifa":"0"},
    {"codigo":"C-1","descripcion":"Cola 2 L","cantidad":"1","precio":"2.00","tarifa":"15"},
    {"codigo":"G-1","descripcion":"Galletas","cantidad":"1","precio":"0.50","tarifa":"0"},
    {"codigo":"A-9","descripcion":"ACEITE","cantidad":"1","precio":"3.00","tarifa":"0"}]'), false);
select set_config('prueba.x2', pg_temp.factura(302,
  '[{"codigo":"G-1","descripcion":"Galletas","cantidad":"4","precio":"0.50","tarifa":"0"}]'), false);
select set_config('prueba.x3', pg_temp.factura(303,
  '[{"codigo":"R-1","descripcion":"Recarga","cantidad":"1","precio":"1.00","tarifa":"0"},
    {"codigo":"T-1","descripcion":"Rara","cantidad":"1","precio":"1.00","tarifa":"0"}]'), false);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

-- =============================================================================
-- Medidas
-- =============================================================================
select results_eq(
  $$ select codigo from public.unidades_medida order by codigo $$,
  $$ values ('KG'::text), ('LT'), ('PAQ'), ('UND') $$,
  'M1. Toda bodega nace con Unidad, Kilo, Paquete y Litro');

select is(public.guardar_medida(' fda ', 'Funda') -> 'data' ->> 'codigo', 'FDA',
  'M2. El Dueño crea una medida; el código es la abreviatura en mayúsculas');
select public.guardar_medida('FDA', 'Funda grande');
select is((select nombre from public.unidades_medida where codigo = 'FDA'), 'Funda grande',
  'M3. Guardar el mismo código cambia el nombre');
select is(public.guardar_medida('a b', 'Mala') -> 'error' ->> 'mensaje',
  'La abreviatura lleva de 1 a 8 letras o números, sin espacios', 'M4. La abreviatura no lleva espacios');

select set_config('prueba.paq', coalesce(public.guardar_producto(null,
  '{"nombre":"Fideos","unidad_base":"PAQ","codigo_iva":"0","precio_venta":1.20}') -> 'data' ->> 'id', ''), true);
select results_eq(
  $$ select p.unidad_base, r.nombre, r.factor::numeric from public.productos p
       join public.presentaciones r on r.producto_id = p.id
      where p.id = nullif(current_setting('prueba.paq'), '')::uuid $$,
  $$ values ('PAQ'::text, 'Paquete'::text, 1::numeric) $$,
  'M5. Un producto en paquetes tiene la presentación base «Paquete»');

select is(public.guardar_producto(null, '{"nombre":"X","unidad_base":"NOPE","codigo_iva":"0","precio_venta":1}') -> 'error' ->> 'mensaje',
  'La medida no existe', 'M6. No se usa una medida que no existe');
select is(public.eliminar_medida('PAQ') -> 'error' ->> 'mensaje',
  'Hay productos con esta medida: cámbiales la medida primero', 'M7. No se borra una medida en uso');
select is(public.eliminar_medida('UND') -> 'error' ->> 'mensaje', 'Unidad y Kilo no se eliminan',
  'M8. Unidad no se borra');
select is(public.eliminar_medida('FDA') ->> 'ok', 'true', 'M9. Una medida sin productos se borra');

-- =============================================================================
-- Imagen
-- =============================================================================
select public.guardar_producto(current_setting('prueba.paq')::uuid,
  '{"imagen":"aaaaaaaa-0000-0000-0000-000000000000/fideos.webp"}');
select is((select imagen from public.productos where id = current_setting('prueba.paq')::uuid),
  'aaaaaaaa-0000-0000-0000-000000000000/fideos.webp', 'I1. El producto guarda la ruta de su imagen');
select is(public.guardar_producto(current_setting('prueba.paq')::uuid,
    '{"imagen":"bbbbbbbb-0000-0000-0000-000000000000/ajena.webp"}') -> 'error' ->> 'mensaje',
  'La imagen no es de esta bodega', 'I2. No se usa una imagen de otra carpeta');

-- =============================================================================
-- Lote
-- =============================================================================
select public.guardar_producto(null, '{"nombre":"Aceite","codigo_iva":"4","precio_venta":3.45}');
select set_config('prueba.c1', public.importar_comprobante(current_setting('prueba.x1')) -> 'data' ->> 'comprobante_id', true);
select set_config('prueba.c2', public.importar_comprobante(current_setting('prueba.x2')) -> 'data' ->> 'comprobante_id', true);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.crear_productos_de_lineas(array['aaaaaaaa-0000-0000-0000-000000000001']::uuid[]) -> 'error' ->> 'codigo',
  'SIN_PERMISO', 'L1. El Vendedor no crea en lote');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select is(public.crear_productos_de_lineas(array[]::uuid[]) -> 'error' ->> 'mensaje', 'Elige al menos una línea',
  'L2. Sin líneas no hace nada');

select results_eq(
  $$ select r -> 'data' ->> 'creados', r -> 'data' ->> 'existentes'
       from (select public.crear_productos_de_lineas(array(
               select id from public.comprobante_lineas
                where comprobante_id = current_setting('prueba.c1')::uuid order by orden)) r) x $$,
  $$ values ('2'::text, '1'::text) $$,
  'L3. De 4 líneas crea 2 productos, repite código en una y reutiliza «Aceite» por nombre');

select results_eq(
  $$ select nombre, codigo_principal, codigo_iva from public.productos
      where nombre in ('Galletas', 'Cola 2 L') order by nombre $$,
  $$ values ('Cola 2 L'::text, 'C-1'::text, '4'::text), ('Galletas', 'G-1', '0') $$,
  'L4. Los productos llevan nombre, código y tarifa de la línea');

select is((select r.precio_venta from public.presentaciones r join public.productos p on p.id = r.producto_id
            where p.nombre = 'Cola 2 L'), 2.30::numeric(12,2),
  'L5. Con precios con IVA incluido, $2,00 + 15 % = $2,30');

select is((select count(*)::int from public.comprobante_lineas
            where comprobante_id = current_setting('prueba.c1')::uuid and presentacion_id is null), 0,
  'L6. Todas las líneas quedan asociadas');

select is((select count(*)::int from public.comprobante_lineas
            where comprobante_id = current_setting('prueba.c2')::uuid and presentacion_id is null), 0,
  'L7. También la otra factura pendiente con el mismo código');

select is((select presentacion_id is not null from public.codigos_sri where codigo = 'G-1'), true,
  'L8. El código queda recordado');

-- Sin control de stock y con un código ocupado por un producto inactivo
select public.guardar_producto(null, '{"nombre":"Vieja","codigo_iva":"0","precio_venta":1,"codigo_principal":"T-1"}');
select public.guardar_producto((select id from public.productos where nombre = 'Vieja'), '{"activo":false}');
select set_config('prueba.c3', public.importar_comprobante(current_setting('prueba.x3')) -> 'data' ->> 'comprobante_id', true);
select is(public.crear_productos_de_lineas(array(
    select id from public.comprobante_lineas where comprobante_id = current_setting('prueba.c3')::uuid order by orden), false)
    -> 'data' ->> 'creados', '2', 'L9. Crea aunque un producto inactivo tenga el código');
select results_eq(
  $$ select nombre, controla_stock, codigo_principal from public.productos where nombre in ('Recarga', 'Rara') order by nombre $$,
  $$ values ('Rara'::text, false, null::text), ('Recarga', false, 'R-1') $$,
  'L10. Se pueden crear sin control de stock; el código repetido se omite');

select is(public.crear_productos_de_lineas(array['aaaaaaaa-0000-0000-0000-000000000001']::uuid[]) -> 'error' ->> 'mensaje',
  'Una de las líneas ya no está pendiente', 'L11. Una línea que no existe detiene todo');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);
select is((select count(*)::int from public.comprobante_lineas), 0, 'L12. Otra bodega no ve las líneas');
select is(public.crear_productos_de_lineas(array[current_setting('prueba.c1')::uuid]) ->> 'ok', 'false',
  'L13. Otra bodega no crea desde líneas ajenas');

select * from finish();
rollback;
