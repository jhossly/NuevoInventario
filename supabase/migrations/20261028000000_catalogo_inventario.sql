-- =============================================================================
-- Migración 0002: catálogo e inventario
-- Fase 3 (diseño) / Fase 6 (implementación)
--
-- Crea:
--   * catálogo: categorias, productos, presentaciones
--   * inventario: movimientos_inventario (libro inmutable), existencias (saldo
--     derivado), conteos y conteo_detalles
--   * motor de inventario privado.registrar_movimiento (costo promedio ponderado)
--   * funciones expuestas: guardar_categoria, eliminar_categoria,
--     guardar_producto, guardar_presentacion, ajustar_inventario,
--     inventario_valorizado, guardar_conteo, confirmar_conteo
--
-- Sigue las reglas de la migración 0001: RLS en toda tabla, solo SELECT para
-- el navegador, escrituras por funciones security definer, empresa desde
-- privado.mi_empresa().
-- =============================================================================

create extension if not exists pg_trgm with schema extensions;

-- -----------------------------------------------------------------------------
-- 1. Auxiliares privados
-- -----------------------------------------------------------------------------

-- Error de negocio que se propaga desde funciones internas. El detalle lleva
-- la respuesta ya formateada por privado.error(); las funciones expuestas lo
-- capturan con `when sqlstate 'NG001'` y lo devuelven tal cual. Al lanzarse,
-- todo lo hecho dentro de la función expuesta se revierte.
create function privado.fallar(p_codigo text, p_mensaje text default null, p_detalle jsonb default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'NG001',
    message = p_codigo,
    detail  = privado.error(p_codigo, p_mensaje, p_detalle)::text;
end;
$$;

-- Quién puede ver costos: el Dueño, o el Vendedor si la empresa lo permite (D-015).
create function privado.ve_costos()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select privado.mi_rol() = 'DUENO' or e.vendedor_ve_costos
       from public.empresas e
      where e.id = privado.mi_empresa()),
    false)
$$;

-- -----------------------------------------------------------------------------
-- 2. Tablas del catálogo
-- -----------------------------------------------------------------------------
create table public.categorias (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas (id) on delete restrict,
  nombre      text not null,
  creado_en   timestamptz not null default now(),
  creado_por  uuid,
  constraint categorias_nombre_no_vacio check (length(trim(nombre)) > 0)
);
create unique index categorias_nombre_unico on public.categorias (empresa_id, lower(nombre));

create table public.productos (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references public.empresas (id) on delete restrict,
  nombre        text not null,
  categoria_id  uuid references public.categorias (id) on delete restrict,
  unidad_base   text not null default 'UND',
  tarifa_iva    numeric(5,2) not null,
  stock_minimo  numeric(14,3) not null default 0,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),
  creado_por    uuid,
  constraint productos_nombre_no_vacio check (length(trim(nombre)) > 0),
  constraint productos_unidad_valida check (unidad_base in ('UND', 'KG')),
  constraint productos_tarifa_rango check (tarifa_iva between 0 and 100),
  constraint productos_stock_minimo check (stock_minimo >= 0)
);
create index productos_empresa_idx on public.productos (empresa_id);
create index productos_categoria_idx on public.productos (categoria_id);
create index productos_nombre_trgm_idx on public.productos using gin (nombre extensions.gin_trgm_ops);

create table public.presentaciones (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references public.empresas (id) on delete restrict,
  producto_id    uuid not null references public.productos (id) on delete restrict,
  nombre         text not null,
  factor         numeric(14,6) not null,
  codigo_barras  text,
  precio_venta   numeric(12,2),
  se_vende       boolean not null default true,
  se_compra      boolean not null default true,
  activo         boolean not null default true,
  creado_en      timestamptz not null default now(),
  creado_por     uuid,
  constraint presentaciones_nombre_no_vacio check (length(trim(nombre)) > 0),
  constraint presentaciones_factor_positivo check (factor > 0),
  constraint presentaciones_precio_positivo check (precio_venta >= 0)
);
comment on column public.presentaciones.factor is
  'Unidades base por presentación: caja de 12 = 12; libra de un producto en KG = 0,453592.';
create index presentaciones_producto_idx on public.presentaciones (producto_id);
create unique index presentaciones_codigo_barras_unico
  on public.presentaciones (empresa_id, codigo_barras) where codigo_barras is not null;

-- -----------------------------------------------------------------------------
-- 3. Tablas de inventario
-- -----------------------------------------------------------------------------
create table public.movimientos_inventario (
  id                  uuid primary key default gen_random_uuid(),
  -- Orden exacto del kardex: varios movimientos de una misma transacción
  -- comparten creado_en.
  secuencia           bigint generated always as identity,
  empresa_id          uuid not null references public.empresas (id) on delete restrict,
  producto_id         uuid not null references public.productos (id) on delete restrict,
  fecha               date not null,
  tipo                text not null,
  cantidad            numeric(14,3) not null,
  costo_unitario      numeric(16,6) not null,
  valor               numeric(16,6) not null,
  saldo_cantidad      numeric(14,3) not null,
  saldo_valor         numeric(16,6) not null,
  origen_tabla        text,
  origen_id           uuid,
  motivo              text,
  clave_idempotencia  uuid,
  creado_en           timestamptz not null default now(),
  creado_por          uuid,
  constraint movimientos_tipo_valido check (tipo in (
    'APERTURA', 'COMPRA', 'VENTA', 'DEVOLUCION_VENTA', 'ANULACION_VENTA', 'AJUSTE', 'MERMA', 'CONTEO')),
  constraint movimientos_cantidad_no_cero check (cantidad <> 0),
  constraint movimientos_costo_positivo check (costo_unitario >= 0)
);
comment on table public.movimientos_inventario is
  'Libro inmutable de inventario (D-008). Cantidad y valor con signo, en unidad base.';
create index movimientos_kardex_idx on public.movimientos_inventario (producto_id, secuencia);
create index movimientos_origen_idx on public.movimientos_inventario (origen_tabla, origen_id);
create unique index movimientos_idempotencia_unica
  on public.movimientos_inventario (empresa_id, clave_idempotencia) where clave_idempotencia is not null;

create trigger movimientos_solo_insercion
  before update or delete on public.movimientos_inventario
  for each row execute function privado.impedir_cambios();

create table public.existencias (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references public.empresas (id) on delete restrict,
  producto_id     uuid not null references public.productos (id) on delete restrict,
  cantidad        numeric(14,3) not null default 0,
  valor_total     numeric(16,6) not null default 0,
  -- Se guarda el valor y el promedio se deriva: guardar solo el promedio
  -- redondeado acumularía errores de centavos (Fase 3).
  costo_promedio  numeric(16,6) generated always as
                    (case when cantidad > 0 then round(valor_total / cantidad, 6) end) stored,
  -- Costo con que entra una unidad cuando el stock está en cero.
  ultimo_costo    numeric(16,6),
  actualizado_en  timestamptz not null default now(),
  constraint existencias_producto_unico unique (empresa_id, producto_id),
  -- Mientras se bloqueen las ventas sin stock (D-004).
  constraint existencias_cantidad_no_negativa check (cantidad >= 0),
  constraint existencias_valor_no_negativo check (valor_total >= 0),
  constraint existencias_sin_stock_sin_valor check (cantidad > 0 or valor_total = 0)
);
comment on table public.existencias is
  'Saldo derivado del libro. Solo lo cambia privado.registrar_movimiento, en la misma transacción.';

create table public.conteos (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references public.empresas (id) on delete restrict,
  fecha           date not null,
  estado          text not null default 'BORRADOR',
  nota            text,
  creado_en       timestamptz not null default now(),
  creado_por      uuid,
  confirmado_en   timestamptz,
  confirmado_por  uuid,
  constraint conteos_estado_valido check (estado in ('BORRADOR', 'CONFIRMADO'))
);
create index conteos_empresa_fecha_idx on public.conteos (empresa_id, fecha desc);

create table public.conteo_detalles (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references public.empresas (id) on delete restrict,
  conteo_id         uuid not null references public.conteos (id) on delete cascade,
  producto_id       uuid not null references public.productos (id) on delete restrict,
  cantidad_sistema  numeric(14,3) not null,
  cantidad_contada  numeric(14,3) not null,
  constraint conteo_detalles_unico unique (conteo_id, producto_id),
  constraint conteo_detalles_contada_no_negativa check (cantidad_contada >= 0)
);

-- Un conteo confirmado queda congelado, incluso para el dueño de la base.
create function privado.conteo_congelado()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_estado text;
begin
  if tg_table_name = 'conteos' then
    v_estado := old.estado;
  else
    select c.estado into v_estado
      from public.conteos c
     where c.id = coalesce(new.conteo_id, old.conteo_id);
  end if;

  if v_estado = 'CONFIRMADO' then
    raise exception 'El conteo ya está confirmado: % no permitido', tg_op
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger conteos_congelados
  before update or delete on public.conteos
  for each row execute function privado.conteo_congelado();

create trigger conteo_detalles_congelados
  before insert or update or delete on public.conteo_detalles
  for each row execute function privado.conteo_congelado();

-- -----------------------------------------------------------------------------
-- 4. Permisos SQL (primera barrera)
-- -----------------------------------------------------------------------------
revoke all on public.categorias, public.productos, public.presentaciones,
              public.movimientos_inventario, public.existencias,
              public.conteos, public.conteo_detalles
  from anon, authenticated;

grant select on public.categorias, public.productos, public.presentaciones,
                public.movimientos_inventario, public.conteos, public.conteo_detalles
  to authenticated;

-- El Vendedor ve el stock pero no su valor (D-015). Dueño y Vendedor usan el
-- mismo rol de base de datos, así que los costos se ocultan por columna y el
-- valor se consulta con public.inventario_valorizado(). Consecuencia: la
-- interfaz debe pedir columnas explícitas; `select *` en existencias falla.
grant select (id, empresa_id, producto_id, cantidad, actualizado_en)
  on public.existencias to authenticated;

-- -----------------------------------------------------------------------------
-- 5. RLS (segunda barrera). Solo lectura, como en la migración 0001.
-- -----------------------------------------------------------------------------
alter table public.categorias             enable row level security;
alter table public.productos              enable row level security;
alter table public.presentaciones         enable row level security;
alter table public.movimientos_inventario enable row level security;
alter table public.existencias            enable row level security;
alter table public.conteos                enable row level security;
alter table public.conteo_detalles        enable row level security;

create policy categorias_lectura on public.categorias
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

create policy productos_lectura on public.productos
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

create policy presentaciones_lectura on public.presentaciones
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

create policy existencias_lectura on public.existencias
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

-- El kardex muestra costos: solo quien puede verlos.
create policy movimientos_lectura on public.movimientos_inventario
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.ve_costos()));

-- Ajustes, mermas y conteos son del Dueño (Fase 4).
create policy conteos_lectura on public.conteos
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');

create policy conteo_detalles_lectura on public.conteo_detalles
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');

-- -----------------------------------------------------------------------------
-- 6. Motor de inventario (privado; lo usan ajustes, conteos y, desde la Fase 7,
--    compras y ventas)
-- -----------------------------------------------------------------------------
-- Costo promedio ponderado (D-003):
--   * entrada: valor = cantidad × costo; el costo es el dado o, si falta, el
--     promedio vigente (o el último costo cuando el stock está en cero).
--   * salida: sale al promedio exacto (valor_total ÷ cantidad, sin redondear);
--     si sale todo el stock, sale todo el valor para no dejar residuos.
--   * redondeo solo al guardar: cantidad a 3 decimales, costo y valor a 6
--     (D-010, D-011); round() de numeric redondea la mitad alejándose de cero.
-- Bloquea la fila de existencias para que dos operaciones simultáneas sobre el
-- mismo producto se ordenen y la segunda vea el saldo de la primera.
create function privado.registrar_movimiento(
  p_empresa         uuid,
  p_producto        uuid,
  p_tipo            text,
  p_cantidad        numeric,
  p_costo_unitario  numeric default null,
  p_origen_tabla    text    default null,
  p_origen_id       uuid    default null,
  p_motivo          text    default null,
  p_clave           uuid    default null)
returns public.movimientos_inventario
language plpgsql
set search_path = ''
as $$
declare
  v_cantidad  numeric := round(p_cantidad, 3);
  v_existencia public.existencias;
  v_costo     numeric;
  v_valor     numeric;
  v_fecha     date;
  v_mov       public.movimientos_inventario;
begin
  if v_cantidad is null or v_cantidad = 0 then
    perform privado.fallar('DATOS_INVALIDOS', 'La cantidad no puede ser cero');
  end if;
  if p_costo_unitario < 0 then
    perform privado.fallar('DATOS_INVALIDOS', 'El costo no puede ser negativo');
  end if;
  if not exists (select 1 from public.productos p
                  where p.id = p_producto and p.empresa_id = p_empresa) then
    perform privado.fallar('DATOS_INVALIDOS', 'El producto no existe');
  end if;

  select (now() at time zone e.zona_horaria)::date into v_fecha
    from public.empresas e where e.id = p_empresa;

  insert into public.existencias (empresa_id, producto_id)
  values (p_empresa, p_producto)
  on conflict (empresa_id, producto_id) do nothing;

  select * into v_existencia
    from public.existencias x
   where x.empresa_id = p_empresa and x.producto_id = p_producto
     for update;

  if v_cantidad > 0 then
    v_costo := coalesce(
      p_costo_unitario,
      case when v_existencia.cantidad > 0 then v_existencia.valor_total / v_existencia.cantidad end,
      v_existencia.ultimo_costo);
    if v_costo is null then
      perform privado.fallar('DATOS_INVALIDOS',
        'Falta el costo unitario: el producto no tiene un costo anterior');
    end if;
    v_valor := round(v_cantidad * v_costo, 6);
  else
    if v_existencia.cantidad + v_cantidad < 0 then
      perform privado.fallar('STOCK_INSUFICIENTE', null, jsonb_build_object(
        'producto_id', p_producto,
        'disponible',  v_existencia.cantidad::text,
        'solicitado',  (-v_cantidad)::text));
    end if;
    v_costo := v_existencia.valor_total / v_existencia.cantidad;
    if v_existencia.cantidad + v_cantidad = 0 then
      v_valor := -v_existencia.valor_total;
    else
      v_valor := -round(-v_cantidad * v_costo, 6);
    end if;
  end if;

  update public.existencias x
     set cantidad       = x.cantidad + v_cantidad,
         valor_total    = x.valor_total + v_valor,
         ultimo_costo   = round(v_costo, 6),
         actualizado_en = now()
   where x.id = v_existencia.id
  returning * into v_existencia;

  insert into public.movimientos_inventario (
    empresa_id, producto_id, fecha, tipo, cantidad, costo_unitario, valor,
    saldo_cantidad, saldo_valor, origen_tabla, origen_id, motivo,
    clave_idempotencia, creado_por)
  values (
    p_empresa, p_producto, v_fecha, p_tipo, v_cantidad, round(v_costo, 6), v_valor,
    v_existencia.cantidad, v_existencia.valor_total, p_origen_tabla, p_origen_id,
    nullif(trim(p_motivo), ''), p_clave, auth.uid())
  returning * into v_mov;

  return v_mov;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Funciones del catálogo (solo Dueño)
-- -----------------------------------------------------------------------------
create function public.guardar_categoria(p_id uuid, p_nombre text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_id      uuid;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;

  if p_id is null then
    insert into public.categorias (empresa_id, nombre, creado_por)
    values (v_empresa, trim(p_nombre), auth.uid())
    returning id into v_id;
  else
    update public.categorias c
       set nombre = trim(p_nombre)
     where c.id = p_id and c.empresa_id = v_empresa
    returning id into v_id;
    if v_id is null then
      return privado.error('DATOS_INVALIDOS', 'La categoría no existe');
    end if;
  end if;

  return privado.ok(jsonb_build_object('id', v_id));
exception
  when unique_violation then
    return privado.error('DUPLICADO', 'Ya existe una categoría con ese nombre');
  when check_violation or not_null_violation then
    return privado.error('DATOS_INVALIDOS', 'El nombre es obligatorio');
end;
$$;

create function public.eliminar_categoria(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;

  delete from public.categorias c where c.id = p_id and c.empresa_id = v_empresa;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La categoría no existe');
  end if;
  return privado.ok(jsonb_build_object('id', p_id));
exception
  when foreign_key_violation then
    return privado.error('DATOS_INVALIDOS', 'La categoría tiene productos');
end;
$$;

-- p_id nulo crea el producto con su presentación base (factor 1) y su fila de
-- existencias. Con p_id, solo cambia las claves presentes en p_datos.
-- Claves: nombre, categoria_id, unidad_base, tarifa_iva, stock_minimo, activo;
-- al crear también precio_venta y codigo_barras de la presentación base.
create function public.guardar_producto(p_id uuid, p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa   uuid := privado.mi_empresa();
  v_anterior  public.productos;
  v_producto  public.productos;
  v_detalle   text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_datos) is distinct from 'object' then
    return privado.error('DATOS_INVALIDOS');
  end if;
  if p_datos ->> 'categoria_id' is not null and not exists (
       select 1 from public.categorias c
        where c.id = (p_datos ->> 'categoria_id')::uuid and c.empresa_id = v_empresa) then
    return privado.error('DATOS_INVALIDOS', 'La categoría no existe');
  end if;

  if p_id is null then
    insert into public.productos (empresa_id, nombre, categoria_id, unidad_base, tarifa_iva,
                                  stock_minimo, creado_por)
    values (v_empresa,
            trim(p_datos ->> 'nombre'),
            (p_datos ->> 'categoria_id')::uuid,
            coalesce(p_datos ->> 'unidad_base', 'UND'),
            (p_datos ->> 'tarifa_iva')::numeric,
            coalesce((p_datos ->> 'stock_minimo')::numeric, 0),
            auth.uid())
    returning * into v_producto;

    insert into public.presentaciones (empresa_id, producto_id, nombre, factor,
                                       codigo_barras, precio_venta, creado_por)
    values (v_empresa, v_producto.id,
            case v_producto.unidad_base when 'KG' then 'Kilo' else 'Unidad' end,
            1,
            nullif(trim(p_datos ->> 'codigo_barras'), ''),
            (p_datos ->> 'precio_venta')::numeric,
            auth.uid());

    insert into public.existencias (empresa_id, producto_id) values (v_empresa, v_producto.id);

    insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, despues)
    values (v_empresa, auth.uid(), 'PRODUCTO_CREADO', 'productos', v_producto.id, to_jsonb(v_producto));
  else
    select * into v_anterior
      from public.productos p
     where p.id = p_id and p.empresa_id = v_empresa
       for update;
    if not found then
      return privado.error('DATOS_INVALIDOS', 'El producto no existe');
    end if;

    if p_datos ? 'unidad_base'
       and p_datos ->> 'unidad_base' is distinct from v_anterior.unidad_base
       and exists (select 1 from public.movimientos_inventario m where m.producto_id = p_id) then
      return privado.error('DATOS_INVALIDOS',
        'No se puede cambiar la unidad base de un producto con movimientos');
    end if;

    update public.productos p set
      nombre       = case when p_datos ? 'nombre'       then trim(p_datos ->> 'nombre')               else p.nombre end,
      categoria_id = case when p_datos ? 'categoria_id' then (p_datos ->> 'categoria_id')::uuid       else p.categoria_id end,
      unidad_base  = case when p_datos ? 'unidad_base'  then p_datos ->> 'unidad_base'                else p.unidad_base end,
      tarifa_iva   = case when p_datos ? 'tarifa_iva'   then (p_datos ->> 'tarifa_iva')::numeric      else p.tarifa_iva end,
      stock_minimo = case when p_datos ? 'stock_minimo' then (p_datos ->> 'stock_minimo')::numeric    else p.stock_minimo end,
      activo       = case when p_datos ? 'activo'       then (p_datos ->> 'activo')::boolean          else p.activo end
     where p.id = p_id
    returning * into v_producto;

    -- Incluye los cambios de tarifa_iva que pide la Fase 3.
    if v_producto is distinct from v_anterior then
      insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes, despues)
      values (v_empresa, auth.uid(), 'PRODUCTO_EDITADO', 'productos', p_id,
              to_jsonb(v_anterior), to_jsonb(v_producto));
    end if;
  end if;

  return privado.ok(jsonb_build_object('id', v_producto.id));
exception
  when unique_violation then
    return privado.error('DUPLICADO', 'El código de barras ya está en uso');
  when check_violation or not_null_violation or invalid_text_representation
       or numeric_value_out_of_range then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS', null, jsonb_build_object('restriccion', nullif(v_detalle, '')));
end;
$$;

-- p_id nulo crea una presentación (p_datos.producto_id obligatorio).
-- Claves: nombre, factor, codigo_barras, precio_venta, se_vende, se_compra, activo.
create function public.guardar_presentacion(p_id uuid, p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa       uuid := privado.mi_empresa();
  v_anterior      public.presentaciones;
  v_presentacion  public.presentaciones;
  v_detalle       text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_datos) is distinct from 'object' then
    return privado.error('DATOS_INVALIDOS');
  end if;

  if p_id is null then
    if not exists (select 1 from public.productos p
                    where p.id = (p_datos ->> 'producto_id')::uuid and p.empresa_id = v_empresa) then
      return privado.error('DATOS_INVALIDOS', 'El producto no existe');
    end if;

    insert into public.presentaciones (empresa_id, producto_id, nombre, factor, codigo_barras,
                                       precio_venta, se_vende, se_compra, creado_por)
    values (v_empresa,
            (p_datos ->> 'producto_id')::uuid,
            trim(p_datos ->> 'nombre'),
            (p_datos ->> 'factor')::numeric,
            nullif(trim(p_datos ->> 'codigo_barras'), ''),
            (p_datos ->> 'precio_venta')::numeric,
            coalesce((p_datos ->> 'se_vende')::boolean, true),
            coalesce((p_datos ->> 'se_compra')::boolean, true),
            auth.uid())
    returning * into v_presentacion;
  else
    select * into v_anterior
      from public.presentaciones r
     where r.id = p_id and r.empresa_id = v_empresa
       for update;
    if not found then
      return privado.error('DATOS_INVALIDOS', 'La presentación no existe');
    end if;

    update public.presentaciones r set
      nombre        = case when p_datos ? 'nombre'        then trim(p_datos ->> 'nombre')                  else r.nombre end,
      factor        = case when p_datos ? 'factor'        then (p_datos ->> 'factor')::numeric             else r.factor end,
      codigo_barras = case when p_datos ? 'codigo_barras' then nullif(trim(p_datos ->> 'codigo_barras'), '') else r.codigo_barras end,
      precio_venta  = case when p_datos ? 'precio_venta'  then (p_datos ->> 'precio_venta')::numeric       else r.precio_venta end,
      se_vende      = case when p_datos ? 'se_vende'      then (p_datos ->> 'se_vende')::boolean           else r.se_vende end,
      se_compra     = case when p_datos ? 'se_compra'     then (p_datos ->> 'se_compra')::boolean          else r.se_compra end,
      activo        = case when p_datos ? 'activo'        then (p_datos ->> 'activo')::boolean             else r.activo end
     where r.id = p_id
    returning * into v_presentacion;

    -- El precio anterior queda en auditoría (Fase 3).
    if v_presentacion is distinct from v_anterior then
      insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes, despues)
      values (v_empresa, auth.uid(), 'PRESENTACION_EDITADA', 'presentaciones', p_id,
              to_jsonb(v_anterior), to_jsonb(v_presentacion));
    end if;
  end if;

  return privado.ok(jsonb_build_object('id', v_presentacion.id));
exception
  when unique_violation then
    return privado.error('DUPLICADO', 'El código de barras ya está en uso');
  when check_violation or not_null_violation or invalid_text_representation
       or numeric_value_out_of_range then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS', null, jsonb_build_object('restriccion', nullif(v_detalle, '')));
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Funciones de inventario (solo Dueño)
-- -----------------------------------------------------------------------------

-- Tipos y signo de p_cantidad (en unidad base):
--   APERTURA  > 0, con costo; solo si el producto no tiene movimientos
--   AJUSTE    ≠ 0, con motivo; sin costo entra al promedio vigente
--   MERMA     < 0, con motivo
-- Con p_clave_idempotencia, un reintento devuelve el movimiento ya creado.
create function public.ajustar_inventario(
  p_producto_id         uuid,
  p_tipo                text,
  p_cantidad            numeric,
  p_costo_unitario      numeric default null,
  p_motivo              text    default null,
  p_clave_idempotencia  uuid    default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_mov      public.movimientos_inventario;
  v_repetido boolean := false;
  v_detalle  text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;

  if p_clave_idempotencia is not null then
    select * into v_mov
      from public.movimientos_inventario m
     where m.empresa_id = v_empresa and m.clave_idempotencia = p_clave_idempotencia;
    v_repetido := found;
  end if;

  if not v_repetido then
    if p_tipo is null or p_tipo not in ('APERTURA', 'AJUSTE', 'MERMA') then
      return privado.error('DATOS_INVALIDOS', 'Tipo de ajuste no válido');
    end if;
    if p_tipo = 'APERTURA' then
      if p_cantidad is null or p_cantidad <= 0 or p_costo_unitario is null then
        return privado.error('DATOS_INVALIDOS', 'La apertura necesita cantidad positiva y costo');
      end if;
      if exists (select 1 from public.movimientos_inventario m
                  where m.producto_id = p_producto_id and m.empresa_id = v_empresa) then
        return privado.error('DATOS_INVALIDOS', 'El producto ya tiene movimientos: usa un ajuste');
      end if;
    elsif nullif(trim(p_motivo), '') is null then
      return privado.error('DATOS_INVALIDOS', 'El motivo es obligatorio');
    elsif p_tipo = 'MERMA' and not (p_cantidad < 0) then
      return privado.error('DATOS_INVALIDOS', 'La merma es una salida: cantidad negativa');
    end if;

    v_mov := privado.registrar_movimiento(
      v_empresa, p_producto_id, p_tipo, p_cantidad, p_costo_unitario,
      null, null, p_motivo, p_clave_idempotencia);
  end if;

  return privado.ok(jsonb_build_object(
    'movimiento_id',  v_mov.id,
    'repetido',       v_repetido,
    'saldo_cantidad', v_mov.saldo_cantidad::text,
    'saldo_valor',    v_mov.saldo_valor::text));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
  when unique_violation then
    -- Dos reintentos simultáneos con la misma clave: el segundo pierde la carrera.
    return privado.error('DUPLICADO');
end;
$$;

-- Stock valorizado. Valores como texto (D-019).
create function public.inventario_valorizado()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
begin
  if v_empresa is null or not privado.ve_costos() then
    return privado.error('SIN_PERMISO');
  end if;

  return privado.ok(jsonb_build_object(
    'productos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto_id',    p.id,
               'nombre',         p.nombre,
               'unidad_base',    p.unidad_base,
               'cantidad',       x.cantidad::text,
               'costo_promedio', x.costo_promedio::text,
               'valor_total',    x.valor_total::text)
             order by p.nombre)
        from public.productos p
        join public.existencias x on x.producto_id = p.id
       where p.empresa_id = v_empresa), '[]'::jsonb),
    'valor_total', (
      select coalesce(sum(x.valor_total), 0)::numeric(16,6)::text
        from public.existencias x
       where x.empresa_id = v_empresa)));
end;
$$;

-- Crea (p_conteo_id nulo) o completa un conteo en borrador.
-- p_detalles: [{"producto_id": "...", "cantidad_contada": 29}], en unidad base.
-- cantidad_sistema se guarda como referencia y se recalcula al confirmar.
create function public.guardar_conteo(
  p_conteo_id  uuid,
  p_detalles   jsonb,
  p_nota       text default null,
  p_fecha      date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_conteo   public.conteos;
  v_linea    record;
  v_lineas   int := 0;
  v_detalle  text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_detalles) is distinct from 'array' or jsonb_array_length(p_detalles) = 0 then
    return privado.error('DATOS_INVALIDOS', 'El conteo necesita al menos un producto');
  end if;

  if p_conteo_id is null then
    insert into public.conteos (empresa_id, fecha, nota, creado_por)
    select v_empresa,
           coalesce(p_fecha, (now() at time zone e.zona_horaria)::date),
           nullif(trim(p_nota), ''),
           auth.uid()
      from public.empresas e where e.id = v_empresa
    returning * into v_conteo;
  else
    select * into v_conteo
      from public.conteos c
     where c.id = p_conteo_id and c.empresa_id = v_empresa
       for update;
    if not found then
      return privado.error('DATOS_INVALIDOS', 'El conteo no existe');
    end if;
    if v_conteo.estado <> 'BORRADOR' then
      return privado.error('DATOS_INVALIDOS', 'El conteo ya está confirmado');
    end if;
    if p_nota is not null or p_fecha is not null then
      update public.conteos c
         set nota  = coalesce(nullif(trim(p_nota), ''), c.nota),
             fecha = coalesce(p_fecha, c.fecha)
       where c.id = v_conteo.id;
    end if;
  end if;

  for v_linea in
    select * from jsonb_to_recordset(p_detalles) as d(producto_id uuid, cantidad_contada numeric)
  loop
    if not exists (select 1 from public.productos p
                    where p.id = v_linea.producto_id and p.empresa_id = v_empresa) then
      perform privado.fallar('DATOS_INVALIDOS', 'El producto no existe',
                             jsonb_build_object('producto_id', v_linea.producto_id));
    end if;

    insert into public.conteo_detalles (empresa_id, conteo_id, producto_id,
                                        cantidad_sistema, cantidad_contada)
    values (v_empresa, v_conteo.id, v_linea.producto_id,
            coalesce((select x.cantidad from public.existencias x
                       where x.producto_id = v_linea.producto_id and x.empresa_id = v_empresa), 0),
            round(v_linea.cantidad_contada, 3))
    on conflict (conteo_id, producto_id) do update
      set cantidad_sistema = excluded.cantidad_sistema,
          cantidad_contada = excluded.cantidad_contada;
    v_lineas := v_lineas + 1;
  end loop;

  return privado.ok(jsonb_build_object('conteo_id', v_conteo.id, 'lineas', v_lineas));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
  when check_violation or not_null_violation or invalid_text_representation
       or numeric_value_out_of_range then
    return privado.error('DATOS_INVALIDOS', 'Las cantidades contadas deben ser cero o más');
end;
$$;

-- Lleva cada producto contado a la cantidad contada con un movimiento CONTEO
-- al costo promedio. Todo o nada; después el conteo queda congelado.
-- Confirmar de nuevo un conteo confirmado no hace nada (reintento seguro).
create function public.confirmar_conteo(p_conteo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa      uuid := privado.mi_empresa();
  v_conteo       public.conteos;
  v_linea        public.conteo_detalles;
  v_sistema      numeric;
  v_movimientos  int := 0;
  v_detalle      text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;

  select * into v_conteo
    from public.conteos c
   where c.id = p_conteo_id and c.empresa_id = v_empresa
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'El conteo no existe');
  end if;
  if v_conteo.estado = 'CONFIRMADO' then
    return privado.ok(jsonb_build_object('conteo_id', v_conteo.id, 'repetido', true, 'movimientos', 0));
  end if;
  if not exists (select 1 from public.conteo_detalles d where d.conteo_id = v_conteo.id) then
    return privado.error('DATOS_INVALIDOS', 'El conteo no tiene productos');
  end if;

  -- Orden fijo por producto para que dos operaciones no se bloqueen en cruz.
  for v_linea in
    select * from public.conteo_detalles d
     where d.conteo_id = v_conteo.id
     order by d.producto_id
  loop
    select x.cantidad into v_sistema
      from public.existencias x
     where x.producto_id = v_linea.producto_id and x.empresa_id = v_empresa
       for update;
    v_sistema := coalesce(v_sistema, 0);

    update public.conteo_detalles d set cantidad_sistema = v_sistema where d.id = v_linea.id;

    if v_linea.cantidad_contada <> v_sistema then
      perform privado.registrar_movimiento(
        v_empresa, v_linea.producto_id, 'CONTEO', v_linea.cantidad_contada - v_sistema, null,
        'conteos', v_conteo.id, coalesce(v_conteo.nota, 'Conteo físico'));
      v_movimientos := v_movimientos + 1;
    end if;
  end loop;

  update public.conteos c
     set estado = 'CONFIRMADO', confirmado_en = now(), confirmado_por = auth.uid()
   where c.id = v_conteo.id;

  return privado.ok(jsonb_build_object('conteo_id', v_conteo.id, 'repetido', false,
                                       'movimientos', v_movimientos));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. Permisos de las funciones
-- -----------------------------------------------------------------------------
revoke all on function
  privado.fallar(text, text, jsonb),
  privado.ve_costos(),
  privado.conteo_congelado(),
  privado.registrar_movimiento(uuid, uuid, text, numeric, numeric, text, uuid, text, uuid)
  from public, anon, authenticated;
-- Las políticas RLS de movimientos_inventario la llaman.
grant execute on function privado.ve_costos() to authenticated;

revoke all on function
  public.guardar_categoria(uuid, text),
  public.eliminar_categoria(uuid),
  public.guardar_producto(uuid, jsonb),
  public.guardar_presentacion(uuid, jsonb),
  public.ajustar_inventario(uuid, text, numeric, numeric, text, uuid),
  public.inventario_valorizado(),
  public.guardar_conteo(uuid, jsonb, text, date),
  public.confirmar_conteo(uuid)
  from public, anon;
grant execute on function
  public.guardar_categoria(uuid, text),
  public.eliminar_categoria(uuid),
  public.guardar_producto(uuid, jsonb),
  public.guardar_presentacion(uuid, jsonb),
  public.ajustar_inventario(uuid, text, numeric, numeric, text, uuid),
  public.inventario_valorizado(),
  public.guardar_conteo(uuid, jsonb, text, date),
  public.confirmar_conteo(uuid)
  to authenticated;
