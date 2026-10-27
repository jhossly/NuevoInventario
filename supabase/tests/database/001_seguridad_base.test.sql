-- =============================================================================
-- Pruebas de seguridad de la migración base (Fase 4, pruebas 1-4, 7, 13-18)
-- Se ejecutan con:  npx supabase test db
-- Todo ocurre dentro de una transacción que se revierte al final.
-- =============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(24);

-- -----------------------------------------------------------------------------
-- Datos de prueba: dos empresas, un Dueño y un Vendedor en cada una,
-- y un vendedor desactivado en la empresa A.
-- -----------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a001', 'dueno.a@prueba.test'),
  ('00000000-0000-0000-0000-00000000a002', 'vendedor.a@prueba.test'),
  ('00000000-0000-0000-0000-00000000a003', 'inactivo.a@prueba.test'),
  ('00000000-0000-0000-0000-00000000b001', 'dueno.b@prueba.test');

insert into public.empresas (id, ruc, razon_social) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '0900000000001', 'Bodega A'),
  ('bbbbbbbb-0000-0000-0000-000000000000', '0900000000002', 'Bodega B');

insert into public.perfiles (id, nombre) values
  ('00000000-0000-0000-0000-00000000a001', 'Dueño A'),
  ('00000000-0000-0000-0000-00000000a002', 'Vendedor A'),
  ('00000000-0000-0000-0000-00000000a003', 'Inactivo A'),
  ('00000000-0000-0000-0000-00000000b001', 'Dueño B');

insert into public.membresias (empresa_id, usuario_id, rol, activo) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a001', 'DUENO',    true),
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a002', 'VENDEDOR', true),
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a003', 'VENDEDOR', false),
  ('bbbbbbbb-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000b001', 'DUENO',    true);

insert into public.auditoria (empresa_id, usuario_id, accion) values
  ('aaaaaaaa-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000a001', 'PRUEBA_A'),
  ('bbbbbbbb-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000b001', 'PRUEBA_B');

-- -----------------------------------------------------------------------------
-- Revisiones automáticas de estructura (pruebas 14, 15, 18)
-- -----------------------------------------------------------------------------
select is_empty(
  $$ select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity $$,
  '14. Todas las tablas de public tienen RLS activado'
);

select is_empty(
  $$ select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'privado') and p.prosecdef
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%') $$,
  '15. Toda función security definer fija search_path'
);

select is_empty(
  $$ select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v'
       and not coalesce('security_invoker=true' = any(c.reloptions), false) $$,
  '18. Toda vista de public usa security_invoker'
);

select is_empty(
  $$ select table_name || ':' || privilege_type from information_schema.role_table_grants
     where table_schema = 'public' and grantee in ('anon', 'authenticated')
       and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE') $$,
  '7a. anon y authenticated no tienen permisos de escritura en tablas de public'
);

-- -----------------------------------------------------------------------------
-- Visitante sin sesión (rol anon)  — pruebas 1 y 2
-- -----------------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', '', true);

select throws_ok(
  $$ select * from public.empresas $$,
  '42501', null,
  '1. Visitante sin sesión no puede leer empresas'
);

select throws_ok(
  $$ select public.mi_contexto() $$,
  '42501', null,
  '2. Visitante sin sesión no puede ejecutar funciones expuestas'
);

reset role;

-- -----------------------------------------------------------------------------
-- Dueño de A
-- -----------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a001","role":"authenticated"}', true);

select results_eq(
  $$ select razon_social from public.empresas $$,
  array['Bodega A'],
  '3. Dueño de A solo ve su empresa'
);

select is(
  (select count(*)::int from public.membresias), 3,
  '3b. Dueño de A ve las 3 membresías de su empresa (incluida la inactiva)'
);

select results_eq(
  $$ select accion from public.auditoria $$,
  array['PRUEBA_A'],
  '3c. Dueño de A solo ve la auditoría de A'
);

select is(
  (public.mi_contexto() -> 'data' ->> 'rol'), 'DUENO',
  '3d. mi_contexto devuelve el rol DUENO'
);

select is(
  (public.mi_contexto() -> 'data' ->> 've_costos')::boolean, true,
  '3e. El Dueño ve costos'
);

select throws_ok(
  $$ insert into public.empresas (ruc, razon_social) values ('0900000000009', 'Intrusa') $$,
  '42501', null,
  '7b. Dueño no puede insertar empresas directamente'
);

select throws_ok(
  $$ update public.membresias set rol = 'DUENO' $$,
  '42501', null,
  '7c. Nadie puede modificar membresías directamente'
);

select throws_ok(
  $$ delete from public.auditoria $$,
  '42501', null,
  '7d. Nadie puede borrar auditoría desde el navegador'
);

reset role;

-- -----------------------------------------------------------------------------
-- Dueño de B intentando ver A  — prueba 4
-- -----------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000b001","role":"authenticated"}', true);

select is_empty(
  $$ select 1 from public.empresas where id = 'aaaaaaaa-0000-0000-0000-000000000000' $$,
  '4. Dueño de B no ve la empresa A aunque filtre por su id'
);

select is_empty(
  $$ select 1 from public.membresias where empresa_id = 'aaaaaaaa-0000-0000-0000-000000000000' $$,
  '4b. Dueño de B no ve membresías de A'
);

select is_empty(
  $$ select 1 from public.perfiles where id = '00000000-0000-0000-0000-00000000a002' $$,
  '4c. Dueño de B no ve perfiles de A'
);

select is_empty(
  $$ select 1 from public.auditoria where empresa_id = 'aaaaaaaa-0000-0000-0000-000000000000' $$,
  '4d. Dueño de B no ve auditoría de A'
);

reset role;

-- -----------------------------------------------------------------------------
-- Vendedor de A
-- -----------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a002","role":"authenticated"}', true);

select is(
  (select count(*)::int from public.membresias), 1,
  '9a. Vendedor solo ve su propia membresía'
);

select is_empty(
  $$ select 1 from public.auditoria $$,
  '9b. Vendedor no ve auditoría'
);

select is(
  (public.mi_contexto() -> 'data' ->> 've_costos')::boolean, false,
  '9c. Vendedor no ve costos con la configuración por defecto'
);

reset role;

-- -----------------------------------------------------------------------------
-- Vendedor desactivado con token vigente  — prueba 13
-- -----------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a003","role":"authenticated"}', true);

select is_empty(
  $$ select 1 from public.empresas $$,
  '13. Usuario desactivado no ve datos de la empresa'
);

select is(
  (public.mi_contexto() -> 'error' ->> 'codigo'), 'SIN_PERMISO',
  '13b. Usuario desactivado recibe SIN_PERMISO'
);

reset role;

-- -----------------------------------------------------------------------------
-- Auditoría inmutable incluso para el dueño de la base (trigger)
-- -----------------------------------------------------------------------------
select throws_ok(
  $$ update public.auditoria set accion = 'X' $$,
  'P0001', null,
  'La auditoría no se puede modificar ni siquiera con privilegios de servidor'
);

select * from finish();
rollback;
