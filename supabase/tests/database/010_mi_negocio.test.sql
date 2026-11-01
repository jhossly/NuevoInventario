-- =============================================================================
-- Pruebas de «Mi negocio» (D-047)
--   * el Dueño cambia datos y ajustes; lo no enviado no cambia
--   * el contexto de la sesión refleja nombre y logo
--   * el RUC no se cambia; logo válido (sin SVG ni demasiado grande)
--   * el Vendedor no escribe; cada bodega solo toca lo suyo; auditoría sin logo
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(16);

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

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

-- =============================================================================
-- Dueño
-- =============================================================================
select ok((public.guardar_mi_negocio(
  '{"nombre_comercial":"  Bodega Doña Rosa ","razon_social":"ROSA PEREZ","direccion":"Calle 10 y Av. 5",
    "telefono":"0991234567","precios_incluyen_iva":false,"descuento_max_vendedor":5,
    "monto_max_consumidor_final":60,"limite_ingresos_rimpe":25000}') ->> 'ok')::boolean,
  'N1. El Dueño guarda los datos de la bodega');

select results_eq(
  $$ select nombre_comercial, razon_social, direccion, telefono, precios_incluyen_iva,
            descuento_max_vendedor, monto_max_consumidor_final, limite_ingresos_rimpe
       from public.empresas where id = 'aaaaaaaa-0000-0000-0000-000000000000' $$,
  $$ values ('Bodega Doña Rosa'::text, 'ROSA PEREZ'::text, 'Calle 10 y Av. 5'::text, '0991234567'::text, false,
             5::numeric(5,2), 60::numeric(12,2), 25000::numeric(12,2)) $$,
  'N2. Los datos quedan guardados y recortados');

select public.guardar_mi_negocio('{"telefono":"022345678"}');
select results_eq(
  $$ select telefono, direccion, descuento_max_vendedor from public.empresas
      where id = 'aaaaaaaa-0000-0000-0000-000000000000' $$,
  $$ values ('022345678'::text, 'Calle 10 y Av. 5'::text, 5::numeric(5,2)) $$,
  'N3. Lo que no se envía no cambia');

select is(public.mi_contexto() -> 'data' ->> 'nombre', 'Bodega Doña Rosa',
  'N4. La sesión muestra el nombre nuevo');

select public.guardar_mi_negocio('{"nombre_comercial":""}');
select is(public.mi_contexto() -> 'data' ->> 'nombre', 'ROSA PEREZ',
  'N5. Sin nombre comercial se muestra la razón social');

select public.guardar_mi_negocio('{"logo":"data:image/png;base64,iVBORw0KGgo="}');
select is(public.mi_contexto() -> 'data' ->> 'logo', 'data:image/png;base64,iVBORw0KGgo=',
  'N6. El logo llega a la sesión');

select is(public.guardar_mi_negocio('{"logo":"data:image/svg+xml;base64,PHN2Zz4="}') -> 'error' -> 'detalle' ->> 'restriccion',
  'empresas_logo_valido', 'N7. Un SVG no se acepta como logo');
select is(public.guardar_mi_negocio(jsonb_build_object('logo', 'data:image/png;base64,' || repeat('A', 200001)))
    -> 'error' -> 'detalle' ->> 'restriccion',
  'empresas_logo_valido', 'N8. Un logo demasiado grande no se acepta');

select public.guardar_mi_negocio('{"logo":""}');
select is(public.mi_contexto() -> 'data' ->> 'logo', null, 'N9. El logo se puede quitar');

select is(public.guardar_mi_negocio('{"ruc":"0999999999999"}') -> 'error' ->> 'mensaje',
  'El RUC no se cambia desde aquí', 'N10. El RUC no se cambia');
select is(public.guardar_mi_negocio('{"razon_social":"  "}') -> 'error' -> 'detalle' ->> 'restriccion',
  'empresas_razon_social_no_vacia', 'N11. La razón social no queda vacía');
select is(public.guardar_mi_negocio('{"descuento_max_vendedor":"abc"}') -> 'error' ->> 'codigo',
  'DATOS_INVALIDOS', 'N12. Un número mal escrito se rechaza');
select is(public.guardar_mi_negocio('{"descuento_max_vendedor":101}') -> 'error' -> 'detalle' ->> 'restriccion',
  'empresas_descuento_rango', 'N13. El descuento máximo no pasa de 100 %');

reset role;
select is((select count(*)::int from public.auditoria
            where tabla = 'empresas' and despues ? 'logo'), 0,
  'N14. La imagen del logo no se copia a la auditoría');
set local role authenticated;

-- =============================================================================
-- Vendedor y otra bodega
-- =============================================================================
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);
select is(public.guardar_mi_negocio('{"nombre_comercial":"Mía"}') -> 'error' ->> 'codigo', 'SIN_PERMISO',
  'N15. El Vendedor no cambia la bodega');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);
select public.guardar_mi_negocio('{"nombre_comercial":"Bodega B Nueva"}');
reset role;
select is((select razon_social from public.empresas where id = 'aaaaaaaa-0000-0000-0000-000000000000'), 'ROSA PEREZ',
  'N16. Otra bodega no toca los datos de esta');

select * from finish();
rollback;
