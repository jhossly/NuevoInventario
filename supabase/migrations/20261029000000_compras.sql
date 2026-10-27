-- =============================================================================
-- Migración 0003: proveedores y compras
-- Fase 3 (diseño) / Fase 7 (implementación)
--
-- Crea:
--   * proveedores, compras, compra_detalles (con RLS; compras inmutables salvo
--     el paso a ANULADA)
--   * movimiento ANULACION_COMPRA y fecha de negocio en el motor de inventario
--   * privado.calcular_lineas_compra: única fuente de los cálculos de una compra
--   * funciones expuestas: guardar_proveedor, calcular_compra (vista previa,
--     no guarda), registrar_compra, anular_compra
--
-- Reglas de cálculo (Fase 3, D-011), por línea:
--   subtotal = cantidad × costo_unitario                 → 2 decimales
--   base     = subtotal − descuento (descuento en dinero, antes del IVA)
--   iva      = base × tarifa_iva ÷ 100                    → 2 decimales
--   costo del inventario = base + iva si iva_compras_es_costo, si no solo base
--   cantidad_base = cantidad × factor de la presentación  → 3 decimales
--   costo_unitario_base = costo del inventario ÷ cantidad_base (exacto al
--   registrar el movimiento; 6 decimales al guardarlo en la línea)
-- Totales de la compra = suma de las líneas ya redondeadas.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Inventario: anulación de compras y fecha de negocio en el motor
-- -----------------------------------------------------------------------------
alter table public.movimientos_inventario drop constraint movimientos_tipo_valido;
alter table public.movimientos_inventario add constraint movimientos_tipo_valido check (tipo in (
  'APERTURA', 'COMPRA', 'ANULACION_COMPRA', 'VENTA', 'DEVOLUCION_VENTA', 'ANULACION_VENTA',
  'AJUSTE', 'MERMA', 'CONTEO'));

-- Se agrega p_fecha (fecha del documento; por defecto hoy en la zona de la
-- empresa). Las funciones que ya lo llamaban siguen igual: plpgsql resuelve la
-- llamada al ejecutarse y p_fecha tiene valor por defecto.
drop function privado.registrar_movimiento(uuid, uuid, text, numeric, numeric, text, uuid, text, uuid);

create function privado.registrar_movimiento(
  p_empresa         uuid,
  p_producto        uuid,
  p_tipo            text,
  p_cantidad        numeric,
  p_costo_unitario  numeric default null,
  p_origen_tabla    text    default null,
  p_origen_id       uuid    default null,
  p_motivo          text    default null,
  p_clave           uuid    default null,
  p_fecha           date    default null)
returns public.movimientos_inventario
language plpgsql
set search_path = ''
as $$
declare
  v_cantidad   numeric := round(p_cantidad, 3);
  v_existencia public.existencias;
  v_costo      numeric;
  v_valor      numeric;
  v_fecha      date;
  v_mov        public.movimientos_inventario;
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

  select coalesce(p_fecha, (now() at time zone e.zona_horaria)::date) into v_fecha
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

revoke all on function
  privado.registrar_movimiento(uuid, uuid, text, numeric, numeric, text, uuid, text, uuid, date)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. Tablas
-- -----------------------------------------------------------------------------
create table public.proveedores (
  id                   uuid primary key default gen_random_uuid(),
  empresa_id           uuid not null references public.empresas (id) on delete restrict,
  tipo_identificacion  text not null,
  identificacion       text not null,
  nombre               text not null,
  telefono             text,
  activo               boolean not null default true,
  creado_en            timestamptz not null default now(),
  creado_por           uuid,
  constraint proveedores_tipo_valido check (tipo_identificacion in ('RUC', 'CEDULA', 'PASAPORTE')),
  constraint proveedores_identificacion_formato check (
    (tipo_identificacion = 'RUC'       and identificacion ~ '^[0-9]{13}$') or
    (tipo_identificacion = 'CEDULA'    and identificacion ~ '^[0-9]{10}$') or
    (tipo_identificacion = 'PASAPORTE' and identificacion ~ '^[A-Za-z0-9]{3,20}$')),
  constraint proveedores_nombre_no_vacio check (length(trim(nombre)) > 0),
  constraint proveedores_identificacion_unica unique (empresa_id, identificacion)
);

create table public.compras (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references public.empresas (id) on delete restrict,
  proveedor_id        uuid references public.proveedores (id) on delete restrict,
  fecha               date not null,
  numero_documento    text,
  con_respaldo        boolean not null,
  subtotal            numeric(12,2) not null,
  descuento           numeric(12,2) not null,
  iva                 numeric(12,2) not null,
  total               numeric(12,2) not null,
  -- Copia de la configuración al registrar: el reporte de una compra antigua
  -- no cambia si el contador cambia la regla después.
  iva_es_costo        boolean not null,
  estado              text not null default 'CONFIRMADA',
  motivo_anulacion    text,
  anulada_en          timestamptz,
  anulada_por         uuid,
  clave_idempotencia  uuid not null,
  creado_en           timestamptz not null default now(),
  creado_por          uuid,
  constraint compras_estado_valido check (estado in ('CONFIRMADA', 'ANULADA')),
  constraint compras_respaldo_completo check (
    not con_respaldo or (proveedor_id is not null and numero_documento is not null)),
  constraint compras_totales_cuadran check (total = subtotal - descuento + iva),
  constraint compras_anulacion_completa check (
    (estado = 'ANULADA') = (motivo_anulacion is not null and anulada_en is not null)),
  constraint compras_idempotencia_unica unique (empresa_id, clave_idempotencia)
);
-- El mismo documento de un proveedor no se registra dos veces, salvo que la
-- primera vez se haya anulado.
create unique index compras_documento_unico
  on public.compras (empresa_id, proveedor_id, numero_documento)
  where estado = 'CONFIRMADA' and numero_documento is not null;
create index compras_empresa_fecha_idx on public.compras (empresa_id, fecha desc);
create index compras_proveedor_idx on public.compras (proveedor_id);

create table public.compra_detalles (
  id                   uuid primary key default gen_random_uuid(),
  empresa_id           uuid not null references public.empresas (id) on delete restrict,
  compra_id            uuid not null references public.compras (id) on delete restrict,
  orden                int not null,
  presentacion_id      uuid not null references public.presentaciones (id) on delete restrict,
  producto_id          uuid not null references public.productos (id) on delete restrict,
  cantidad             numeric(14,3) not null,
  costo_unitario       numeric(16,6) not null,
  descuento            numeric(12,2) not null default 0,
  tarifa_iva           numeric(5,2) not null,
  subtotal             numeric(12,2) not null,
  iva                  numeric(12,2) not null,
  cantidad_base        numeric(14,3) not null,
  costo_unitario_base  numeric(16,6) not null,
  constraint compra_detalles_valores check (
    cantidad > 0 and costo_unitario >= 0 and descuento >= 0 and descuento <= subtotal
    and cantidad_base > 0 and iva >= 0),
  constraint compra_detalles_orden_unico unique (compra_id, orden)
);
create index compra_detalles_compra_idx on public.compra_detalles (compra_id);
create index compra_detalles_producto_idx on public.compra_detalles (producto_id);

-- Las líneas no cambian nunca; la compra solo puede pasar de CONFIRMADA a ANULADA.
create trigger compra_detalles_solo_insercion
  before update or delete on public.compra_detalles
  for each row execute function privado.impedir_cambios();

create function privado.compra_solo_anulacion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Una compra no se borra: se anula' using errcode = 'P0001';
  end if;
  if old.estado <> 'CONFIRMADA' or new.estado <> 'ANULADA'
     or (to_jsonb(old) - array['estado', 'motivo_anulacion', 'anulada_en', 'anulada_por'])
        is distinct from
        (to_jsonb(new) - array['estado', 'motivo_anulacion', 'anulada_en', 'anulada_por']) then
    raise exception 'Una compra confirmada no se edita: solo se anula' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger compras_solo_anulacion
  before update or delete on public.compras
  for each row execute function privado.compra_solo_anulacion();

-- -----------------------------------------------------------------------------
-- 3. Permisos y RLS
-- -----------------------------------------------------------------------------
revoke all on public.proveedores, public.compras, public.compra_detalles from anon, authenticated;
grant select on public.proveedores, public.compras, public.compra_detalles to authenticated;

alter table public.proveedores     enable row level security;
alter table public.compras         enable row level security;
alter table public.compra_detalles enable row level security;

-- Compras y proveedores son del Dueño (Fase 4). Las compras además llevan costos.
create policy proveedores_lectura on public.proveedores
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');

create policy compras_lectura on public.compras
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');

create policy compra_detalles_lectura on public.compra_detalles
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');

-- -----------------------------------------------------------------------------
-- 4. Auxiliares privados
-- -----------------------------------------------------------------------------

-- "1-1-123" y "001-001-000000123" son el mismo documento del SRI.
create function privado.normalizar_documento(p_numero text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_numero is null or trim(p_numero) = '' then null
    when trim(p_numero) ~ '^[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,9}$' then
      lpad(split_part(trim(p_numero), '-', 1), 3, '0') || '-' ||
      lpad(split_part(trim(p_numero), '-', 2), 3, '0') || '-' ||
      lpad(split_part(trim(p_numero), '-', 3), 9, '0')
    else upper(trim(p_numero))
  end
$$;

create type privado.linea_compra as (
  orden                int,
  presentacion_id      uuid,
  producto_id          uuid,
  cantidad             numeric,
  costo_unitario       numeric,
  descuento            numeric,
  tarifa_iva           numeric,
  subtotal             numeric,
  iva                  numeric,
  cantidad_base        numeric,
  costo_unitario_base  numeric   -- exacto, sin redondear
);

-- p_lineas: [{"presentacion_id", "cantidad", "costo_unitario", "descuento"?}]
-- cantidad en unidades de la presentación; costo_unitario por presentación,
-- sin IVA. Un error indica la línea (1, 2, …) en el detalle.
create function privado.calcular_lineas_compra(p_empresa uuid, p_lineas jsonb)
returns setof privado.linea_compra
language plpgsql
set search_path = ''
as $$
declare
  v_iva_es_costo boolean;
  v_entrada      record;
  v_pres         record;
  v_linea        privado.linea_compra;
  v_base         numeric;
begin
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    perform privado.fallar('DATOS_INVALIDOS', 'La compra necesita al menos una línea');
  end if;

  select e.iva_compras_es_costo into v_iva_es_costo from public.empresas e where e.id = p_empresa;

  for v_entrada in
    select l.ordinality::int as orden, l.value as datos
      from jsonb_array_elements(p_lineas) with ordinality l
  loop
    begin
      v_linea.orden          := v_entrada.orden;
      v_linea.presentacion_id := (v_entrada.datos ->> 'presentacion_id')::uuid;
      v_linea.cantidad       := round((v_entrada.datos ->> 'cantidad')::numeric, 3);
      v_linea.costo_unitario := round((v_entrada.datos ->> 'costo_unitario')::numeric, 6);
      v_linea.descuento      := round(coalesce((v_entrada.datos ->> 'descuento')::numeric, 0), 2);
    exception
      when invalid_text_representation or numeric_value_out_of_range then
        perform privado.fallar('DATOS_INVALIDOS', 'Hay un número mal escrito',
                               jsonb_build_object('linea', v_entrada.orden));
    end;

    select r.factor, r.producto_id, p.tarifa_iva
      into v_pres
      from public.presentaciones r
      join public.productos p on p.id = r.producto_id
     where r.id = v_linea.presentacion_id
       and r.empresa_id = p_empresa
       and r.activo and r.se_compra and p.activo;
    if not found then
      perform privado.fallar('DATOS_INVALIDOS', 'La presentación no existe o no se compra',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;

    if v_linea.cantidad is null or v_linea.cantidad <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad debe ser mayor que cero',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    if v_linea.costo_unitario is null or v_linea.costo_unitario < 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'Falta el costo o es negativo',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;

    v_linea.producto_id   := v_pres.producto_id;
    v_linea.tarifa_iva    := v_pres.tarifa_iva;
    v_linea.subtotal      := round(v_linea.cantidad * v_linea.costo_unitario, 2);
    if v_linea.descuento < 0 or v_linea.descuento > v_linea.subtotal then
      perform privado.fallar('DATOS_INVALIDOS', 'El descuento no puede superar el subtotal',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    v_base                := v_linea.subtotal - v_linea.descuento;
    v_linea.iva           := round(v_base * v_linea.tarifa_iva / 100, 2);
    v_linea.cantidad_base := round(v_linea.cantidad * v_pres.factor, 3);
    if v_linea.cantidad_base <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad es demasiado pequeña',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    v_linea.costo_unitario_base :=
      (v_base + case when v_iva_es_costo then v_linea.iva else 0 end) / v_linea.cantidad_base;

    return next v_linea;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Funciones expuestas (solo Dueño)
-- -----------------------------------------------------------------------------

-- p_id nulo crea. Claves: tipo_identificacion, identificacion, nombre, telefono, activo.
create function public.guardar_proveedor(p_id uuid, p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_id       uuid;
  v_detalle  text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_datos) is distinct from 'object' then
    return privado.error('DATOS_INVALIDOS');
  end if;

  if p_id is null then
    insert into public.proveedores (empresa_id, tipo_identificacion, identificacion, nombre, telefono, creado_por)
    values (v_empresa,
            coalesce(p_datos ->> 'tipo_identificacion', 'RUC'),
            trim(p_datos ->> 'identificacion'),
            trim(p_datos ->> 'nombre'),
            nullif(trim(p_datos ->> 'telefono'), ''),
            auth.uid())
    returning id into v_id;
  else
    update public.proveedores v set
      tipo_identificacion = case when p_datos ? 'tipo_identificacion' then p_datos ->> 'tipo_identificacion' else v.tipo_identificacion end,
      identificacion      = case when p_datos ? 'identificacion' then trim(p_datos ->> 'identificacion') else v.identificacion end,
      nombre              = case when p_datos ? 'nombre'         then trim(p_datos ->> 'nombre')         else v.nombre end,
      telefono            = case when p_datos ? 'telefono'       then nullif(trim(p_datos ->> 'telefono'), '') else v.telefono end,
      activo              = case when p_datos ? 'activo'         then (p_datos ->> 'activo')::boolean    else v.activo end
     where v.id = p_id and v.empresa_id = v_empresa
    returning id into v_id;
    if v_id is null then
      return privado.error('DATOS_INVALIDOS', 'El proveedor no existe');
    end if;
  end if;

  return privado.ok(jsonb_build_object('id', v_id));
exception
  when unique_violation then
    return privado.error('DUPLICADO', 'Ya existe un proveedor con esa identificación');
  when check_violation or not_null_violation or invalid_text_representation then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS',
      case v_detalle
        when 'proveedores_identificacion_formato' then 'El RUC tiene 13 dígitos y la cédula 10'
        else null
      end,
      jsonb_build_object('restriccion', nullif(v_detalle, '')));
end;
$$;

-- Vista previa: los mismos cálculos que registrar_compra, sin guardar nada.
-- Valores como texto (D-019).
create function public.calcular_compra(p_lineas jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_detalle  text;
  v_lineas   jsonb;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'orden',               l.orden,
           'subtotal',            round(l.subtotal, 2)::text,
           'descuento',           round(l.descuento, 2)::text,
           'iva',                 round(l.iva, 2)::text,
           'cantidad_base',       round(l.cantidad_base, 3)::text,
           'costo_unitario_base', round(l.costo_unitario_base, 6)::text)
         order by l.orden), '[]'::jsonb)
    into v_lineas
    from privado.calcular_lineas_compra(v_empresa, p_lineas) l;

  return privado.ok(jsonb_build_object(
    'lineas',    v_lineas,
    'subtotal',  (select coalesce(sum((x ->> 'subtotal')::numeric), 0)::numeric(12,2)::text from jsonb_array_elements(v_lineas) x),
    'descuento', (select coalesce(sum((x ->> 'descuento')::numeric), 0)::numeric(12,2)::text from jsonb_array_elements(v_lineas) x),
    'iva',       (select coalesce(sum((x ->> 'iva')::numeric), 0)::numeric(12,2)::text from jsonb_array_elements(v_lineas) x),
    'total',     (select coalesce(sum((x ->> 'subtotal')::numeric - (x ->> 'descuento')::numeric
                                      + (x ->> 'iva')::numeric), 0)::numeric(12,2)::text
                    from jsonb_array_elements(v_lineas) x)));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
end;
$$;

-- Registra y confirma la compra en un solo paso: líneas, totales y entradas de
-- inventario. Con la misma p_clave_idempotencia, un reintento devuelve la
-- compra ya creada.
create function public.registrar_compra(
  p_proveedor_id        uuid,
  p_con_respaldo        boolean,
  p_numero_documento    text,
  p_fecha               date,
  p_lineas              jsonb,
  p_clave_idempotencia  uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa    uuid := privado.mi_empresa();
  v_hoy        date;
  v_fecha      date;
  v_documento  text := privado.normalizar_documento(p_numero_documento);
  v_compra     public.compras;
  v_lineas     privado.linea_compra[];
  v_linea      privado.linea_compra;
  v_detalle    text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la clave de idempotencia');
  end if;

  select * into v_compra
    from public.compras c
   where c.empresa_id = v_empresa and c.clave_idempotencia = p_clave_idempotencia;
  if found then
    return privado.ok(jsonb_build_object('compra_id', v_compra.id, 'repetido', true,
                                         'total', v_compra.total::text));
  end if;

  if p_con_respaldo is null then
    return privado.error('DATOS_INVALIDOS', 'Indica si la compra tiene respaldo');
  end if;
  if p_con_respaldo and (p_proveedor_id is null or v_documento is null) then
    return privado.error('DATOS_INVALIDOS',
      'Una compra con respaldo necesita proveedor y número de documento');
  end if;
  if p_proveedor_id is not null and not exists (
       select 1 from public.proveedores v
        where v.id = p_proveedor_id and v.empresa_id = v_empresa and v.activo) then
    return privado.error('DATOS_INVALIDOS', 'El proveedor no existe o está inactivo');
  end if;

  select (now() at time zone e.zona_horaria)::date into v_hoy from public.empresas e where e.id = v_empresa;
  v_fecha := coalesce(p_fecha, v_hoy);
  if v_fecha > v_hoy then
    return privado.error('DATOS_INVALIDOS', 'La fecha no puede ser futura');
  end if;

  select array_agg(l order by l.orden) into v_lineas
    from privado.calcular_lineas_compra(v_empresa, p_lineas) l;

  insert into public.compras (empresa_id, proveedor_id, fecha, numero_documento, con_respaldo,
                              subtotal, descuento, iva, total, iva_es_costo,
                              clave_idempotencia, creado_por)
  select v_empresa, p_proveedor_id, v_fecha, v_documento, p_con_respaldo,
         sum(l.subtotal), sum(l.descuento), sum(l.iva),
         sum(l.subtotal) - sum(l.descuento) + sum(l.iva),
         e.iva_compras_es_costo, p_clave_idempotencia, auth.uid()
    from unnest(v_lineas) l
    join public.empresas e on e.id = v_empresa
   group by e.iva_compras_es_costo
  returning * into v_compra;

  insert into public.compra_detalles (empresa_id, compra_id, orden, presentacion_id, producto_id,
                                      cantidad, costo_unitario, descuento, tarifa_iva, subtotal,
                                      iva, cantidad_base, costo_unitario_base)
  select v_empresa, v_compra.id, l.orden, l.presentacion_id, l.producto_id,
         l.cantidad, l.costo_unitario, l.descuento, l.tarifa_iva, l.subtotal,
         l.iva, l.cantidad_base, round(l.costo_unitario_base, 6)
    from unnest(v_lineas) l;

  -- Entradas al inventario en orden de producto (evita bloqueos cruzados).
  for v_linea in select * from unnest(v_lineas) l order by l.producto_id, l.orden loop
    perform privado.registrar_movimiento(
      v_empresa, v_linea.producto_id, 'COMPRA', v_linea.cantidad_base, v_linea.costo_unitario_base,
      'compras', v_compra.id, null, null, v_fecha);
  end loop;

  return privado.ok(jsonb_build_object('compra_id', v_compra.id, 'repetido', false,
                                       'total', v_compra.total::text));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
  when unique_violation then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DUPLICADO',
      case v_detalle
        when 'compras_documento_unico' then 'Ese documento de ese proveedor ya está registrado'
        else null
      end);
end;
$$;

-- Saca del inventario lo que entró con la compra, al costo promedio vigente
-- (D-023). Si ya se vendió parte, no alcanza el stock y hay que usar un ajuste.
create function public.anular_compra(p_compra_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_compra   public.compras;
  v_linea    record;
  v_detalle  text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if nullif(trim(p_motivo), '') is null then
    return privado.error('DATOS_INVALIDOS', 'El motivo es obligatorio');
  end if;

  select * into v_compra
    from public.compras c
   where c.id = p_compra_id and c.empresa_id = v_empresa
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La compra no existe');
  end if;
  if v_compra.estado = 'ANULADA' then
    return privado.ok(jsonb_build_object('compra_id', v_compra.id, 'repetido', true));
  end if;

  -- Una salida por producto, sumando sus líneas.
  for v_linea in
    select d.producto_id, sum(d.cantidad_base) as cantidad_base
      from public.compra_detalles d
     where d.compra_id = v_compra.id
     group by d.producto_id
     order by d.producto_id
  loop
    perform privado.registrar_movimiento(
      v_empresa, v_linea.producto_id, 'ANULACION_COMPRA', -v_linea.cantidad_base, null,
      'compras', v_compra.id, trim(p_motivo));
  end loop;

  update public.compras c
     set estado = 'ANULADA', motivo_anulacion = trim(p_motivo),
         anulada_en = now(), anulada_por = auth.uid()
   where c.id = v_compra.id;

  insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes, despues)
  values (v_empresa, auth.uid(), 'COMPRA_ANULADA', 'compras', v_compra.id,
          jsonb_build_object('estado', 'CONFIRMADA'),
          jsonb_build_object('estado', 'ANULADA', 'motivo', trim(p_motivo)));

  return privado.ok(jsonb_build_object('compra_id', v_compra.id, 'repetido', false));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    if (v_detalle::jsonb -> 'error' ->> 'codigo') = 'STOCK_INSUFICIENTE' then
      return privado.error('STOCK_INSUFICIENTE',
        'Ya salió parte de esta compra del inventario: corrígela con un ajuste',
        v_detalle::jsonb -> 'error' -> 'detalle');
    end if;
    return v_detalle::jsonb;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Permisos de las funciones
-- -----------------------------------------------------------------------------
revoke all on function
  privado.compra_solo_anulacion(),
  privado.normalizar_documento(text),
  privado.calcular_lineas_compra(uuid, jsonb)
  from public, anon, authenticated;

revoke all on function
  public.guardar_proveedor(uuid, jsonb),
  public.calcular_compra(jsonb),
  public.registrar_compra(uuid, boolean, text, date, jsonb, uuid),
  public.anular_compra(uuid, text)
  from public, anon;
grant execute on function
  public.guardar_proveedor(uuid, jsonb),
  public.calcular_compra(jsonb),
  public.registrar_compra(uuid, boolean, text, date, jsonb, uuid),
  public.anular_compra(uuid, text)
  to authenticated;
