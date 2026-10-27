-- =============================================================================
-- Migración 0001: base de seguridad
-- Fase 4 (diseño) / Fase 5 (implementación)
--
-- Crea:
--   * esquema `privado` (no expuesto por la API) con funciones auxiliares
--   * tablas empresas, perfiles, membresias, auditoria
--   * permisos SQL restrictivos + RLS en todas las tablas de `public`
--
-- Reglas que siguen TODAS las migraciones futuras:
--   1. Toda tabla nueva en `public` activa RLS en la misma migración.
--   2. El navegador (rol authenticated) solo recibe SELECT; las escrituras
--      pasan por funciones `security definer` con `set search_path = ''`.
--   3. La empresa se obtiene siempre de privado.mi_empresa(), nunca de un
--      dato enviado por el cliente.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Permisos por defecto: nada nuevo nace accesible para anon/authenticated
-- -----------------------------------------------------------------------------
-- Supabase concede por defecto ALL sobre tablas nuevas a anon y authenticated.
-- Lo revocamos para que cada permiso sea explícito.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. Esquema privado
-- -----------------------------------------------------------------------------
create schema if not exists privado;
revoke all on schema privado from public, anon;
-- authenticated necesita "usage" para que las políticas RLS puedan llamar a
-- mi_empresa()/mi_rol(); la API no expone este esquema.
grant usage on schema privado to authenticated;

-- -----------------------------------------------------------------------------
-- 3. Tablas
-- -----------------------------------------------------------------------------
create table public.empresas (
  id                       uuid primary key default gen_random_uuid(),
  ruc                      text not null,
  razon_social             text not null,
  nombre_comercial         text,
  regimen                  text not null default 'NEGOCIO_POPULAR',
  precios_incluyen_iva     boolean not null default true,
  iva_compras_es_costo     boolean not null default true,
  permitir_venta_sin_stock boolean not null default false,
  vendedor_ve_costos       boolean not null default false,
  descuento_max_vendedor   numeric(5,2) not null default 0,
  zona_horaria             text not null default 'America/Guayaquil',
  creado_en                timestamptz not null default now(),
  constraint empresas_ruc_formato check (ruc ~ '^[0-9]{13}$'),
  constraint empresas_ruc_unico unique (ruc),
  constraint empresas_regimen_valido
    check (regimen in ('NEGOCIO_POPULAR', 'RIMPE_EMPRENDEDOR', 'GENERAL')),
  constraint empresas_descuento_rango
    check (descuento_max_vendedor between 0 and 100)
);
comment on table public.empresas is
  'Negocio que usa el sistema. Hoy hay una sola; el modelo admite varias.';

create table public.perfiles (
  id         uuid primary key references auth.users (id) on delete restrict,
  nombre     text not null,
  creado_en  timestamptz not null default now(),
  constraint perfiles_nombre_no_vacio check (length(trim(nombre)) > 0)
);
comment on table public.perfiles is
  'Datos visibles del usuario. Un usuario no se borra: se desactiva su membresía.';

create table public.membresias (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas (id) on delete restrict,
  usuario_id  uuid not null references public.perfiles (id) on delete restrict,
  rol         text not null,
  activo      boolean not null default true,
  creado_en   timestamptz not null default now(),
  creado_por  uuid,
  constraint membresias_rol_valido check (rol in ('DUENO', 'VENDEDOR')),
  constraint membresias_unica unique (empresa_id, usuario_id)
);
-- Las políticas RLS consultan membresías por usuario en cada solicitud.
create index membresias_usuario_idx on public.membresias (usuario_id) where activo;

create table public.auditoria (
  id           uuid primary key default gen_random_uuid(),
  empresa_id   uuid not null references public.empresas (id) on delete restrict,
  usuario_id   uuid,
  accion       text not null,
  tabla        text,
  registro_id  uuid,
  antes        jsonb,
  despues      jsonb,
  creado_en    timestamptz not null default now()
);
create index auditoria_empresa_fecha_idx on public.auditoria (empresa_id, creado_en desc);
comment on table public.auditoria is
  'Registro de acciones importantes. Solo admite inserción.';

-- -----------------------------------------------------------------------------
-- 4. Funciones auxiliares (esquema privado)
-- -----------------------------------------------------------------------------

-- Empresa de la membresía activa del usuario en sesión.
-- security definer: necesita leer `membresias` sin pasar por su propia RLS
-- (si no, la política de membresias llamaría a esta función en un ciclo).
create function privado.mi_empresa()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.empresa_id
  from public.membresias m
  where m.usuario_id = auth.uid()
    and m.activo
  limit 1
$$;

create function privado.mi_rol()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select m.rol
  from public.membresias m
  where m.usuario_id = auth.uid()
    and m.activo
  limit 1
$$;

-- Formato único de error para las funciones de negocio.
create function privado.error(p_codigo text, p_mensaje text default null, p_detalle jsonb default null)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'ok', false,
    'error', jsonb_build_object(
      'codigo',  p_codigo,
      'mensaje', coalesce(p_mensaje, case p_codigo
        when 'SIN_PERMISO'        then 'No tienes permiso para esta acción'
        when 'DATOS_INVALIDOS'    then 'Hay datos inválidos'
        when 'STOCK_INSUFICIENTE' then 'No hay stock suficiente'
        when 'LIMITE_FIADO'       then 'El cliente supera su límite de fiado'
        when 'CAJA_CERRADA'       then 'La caja está cerrada'
        when 'DUPLICADO'          then 'El registro ya existe'
        else 'Ocurrió un error inesperado'
      end),
      'detalle', p_detalle
    )
  )
$$;

create function privado.ok(p_data jsonb default '{}'::jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('ok', true, 'data', p_data)
$$;

-- Trigger para tablas de solo inserción (auditoria; luego movimientos_inventario).
create function privado.impedir_cambios()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'La tabla % es de solo inserción: % no permitido', tg_table_name, tg_op
    using errcode = 'P0001';
end;
$$;

create trigger auditoria_solo_insercion
  before update or delete on public.auditoria
  for each row execute function privado.impedir_cambios();

-- Permisos de las funciones auxiliares
revoke all on all functions in schema privado from public, anon, authenticated;
grant execute on function privado.mi_empresa() to authenticated;
grant execute on function privado.mi_rol()     to authenticated;

-- -----------------------------------------------------------------------------
-- 5. Permisos SQL sobre tablas (primera barrera)
-- -----------------------------------------------------------------------------
revoke all on public.empresas, public.perfiles, public.membresias, public.auditoria
  from anon, authenticated;

grant select on public.empresas, public.perfiles, public.membresias, public.auditoria
  to authenticated;

-- -----------------------------------------------------------------------------
-- 6. RLS (segunda barrera). Solo políticas de lectura: sin política de
--    insert/update/delete, RLS niega esas operaciones a authenticated.
-- -----------------------------------------------------------------------------
alter table public.empresas   enable row level security;
alter table public.perfiles   enable row level security;
alter table public.membresias enable row level security;
alter table public.auditoria  enable row level security;

create policy empresas_lectura on public.empresas
  for select to authenticated
  using (id = (select privado.mi_empresa()));

-- Un usuario ve su propio perfil y los perfiles de su misma empresa.
create policy perfiles_lectura on public.perfiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or exists (
      select 1 from public.membresias m
      where m.usuario_id = perfiles.id
        and m.empresa_id = (select privado.mi_empresa())
    )
  );

-- El Dueño ve todas las membresías de su empresa; el Vendedor solo la suya.
create policy membresias_lectura on public.membresias
  for select to authenticated
  using (
    empresa_id = (select privado.mi_empresa())
    and (usuario_id = (select auth.uid()) or (select privado.mi_rol()) = 'DUENO')
  );

-- Solo el Dueño lee la auditoría.
create policy auditoria_lectura on public.auditoria
  for select to authenticated
  using (
    empresa_id = (select privado.mi_empresa())
    and (select privado.mi_rol()) = 'DUENO'
  );

-- -----------------------------------------------------------------------------
-- 7. Primera función expuesta: contexto del usuario para la interfaz
-- -----------------------------------------------------------------------------
create function public.mi_contexto()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_rol     text := privado.mi_rol();
  v_datos   jsonb;
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;

  select jsonb_build_object(
           'empresa_id',         e.id,
           'nombre',             coalesce(e.nombre_comercial, e.razon_social),
           'regimen',            e.regimen,
           'rol',                v_rol,
           've_costos',          (v_rol = 'DUENO' or e.vendedor_ve_costos),
           'precios_incluyen_iva', e.precios_incluyen_iva
         )
    into v_datos
  from public.empresas e
  where e.id = v_empresa;

  return privado.ok(v_datos);
end;
$$;

revoke execute on function public.mi_contexto() from public, anon;
grant  execute on function public.mi_contexto() to authenticated;
