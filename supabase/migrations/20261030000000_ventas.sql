-- =============================================================================
-- Migración 0004: clientes, ventas, anulaciones y devoluciones
-- Fase 3 (diseño) / Fase 8 (implementación)
--
-- Crea:
--   * clientes, ventas, venta_detalles, venta_pagos, devoluciones,
--     devolucion_detalles (con RLS; todo inmutable salvo anular o pedir anular)
--   * empresas.monto_max_consumidor_final y monto_max_sin_comprobante
--   * privado.calcular_lineas_venta: única fuente de los cálculos de una venta
--   * funciones expuestas: guardar_cliente, calcular_venta, registrar_venta,
--     solicitar_anulacion_venta, anular_venta, registrar_devolucion, costos_venta
--
-- Cálculo por línea (Fase 3, D-011), con precios_incluyen_iva = true:
--   bruto    = cantidad × precio de la presentación          → 2 decimales
--   total    = bruto − descuento (el descuento se escribe en dinero, IVA incluido)
--   base     = total ÷ (1 + tarifa)                           → 2 decimales
--   iva      = total − base
--   subtotal = bruto ÷ (1 + tarifa) (base antes del descuento) → 2 decimales
--   descuento guardado = subtotal − base (el descuento sin IVA)
-- Con precios_incluyen_iva = false el precio es sin IVA:
--   subtotal = cantidad × precio; base = subtotal − descuento;
--   iva = base × tarifa → 2 decimales; total = base + iva
-- En ambos casos total = subtotal − descuento + iva, y la venta suma sus líneas.
-- El costo de cada línea es el del movimiento VENTA (promedio vigente).
--
-- Caja y fiado llegan en la Fase 9: hoy se rechazan el pago FIADO y el
-- reintegro ABONO_FIADO, y ventas no tiene caja_id todavía.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Configuración del comprobante (valores a confirmar con el contador)
-- -----------------------------------------------------------------------------
alter table public.empresas
  add column monto_max_consumidor_final numeric(12,2) not null default 50,
  add column monto_max_sin_comprobante  numeric(12,2) not null default 0,
  add constraint empresas_montos_comprobante check (
    monto_max_consumidor_final >= 0 and monto_max_sin_comprobante >= 0);

comment on column public.empresas.monto_max_consumidor_final is
  'Factura a consumidor final sin identificar hasta este total (Decreto 586: USD 50).';
comment on column public.empresas.monto_max_sin_comprobante is
  'Venta sin comprobante permitida hasta este total. 0 = nunca (D-005), hasta que el contador lo indique.';

-- -----------------------------------------------------------------------------
-- 2. Tablas
-- -----------------------------------------------------------------------------
create table public.clientes (
  id                   uuid primary key default gen_random_uuid(),
  empresa_id           uuid not null references public.empresas (id) on delete restrict,
  tipo_identificacion  text,
  identificacion       text,
  nombre               text not null,
  telefono             text,
  correo               text,
  direccion            text,
  fiado_permitido      boolean not null default false,
  limite_fiado         numeric(12,2) not null default 0,
  activo               boolean not null default true,
  creado_en            timestamptz not null default now(),
  creado_por           uuid,
  constraint clientes_identificacion_completa check ((tipo_identificacion is null) = (identificacion is null)),
  constraint clientes_identificacion_formato check (
    tipo_identificacion is null or
    (tipo_identificacion = 'RUC'       and identificacion ~ '^[0-9]{13}$') or
    (tipo_identificacion = 'CEDULA'    and identificacion ~ '^[0-9]{10}$') or
    (tipo_identificacion = 'PASAPORTE' and identificacion ~ '^[A-Za-z0-9]{3,20}$')),
  constraint clientes_nombre_no_vacio check (length(trim(nombre)) > 0),
  constraint clientes_limite_fiado check (limite_fiado >= 0)
);
create unique index clientes_identificacion_unica
  on public.clientes (empresa_id, identificacion) where identificacion is not null;
create index clientes_nombre_trgm_idx on public.clientes using gin (nombre extensions.gin_trgm_ops);

create table public.ventas (
  id                    uuid primary key,
  empresa_id            uuid not null references public.empresas (id) on delete restrict,
  fecha                 date not null,
  cliente_id            uuid references public.clientes (id) on delete restrict,
  tipo_comprobante      text not null,
  subtotal              numeric(12,2) not null,
  descuento             numeric(12,2) not null,
  iva                   numeric(12,2) not null,
  total                 numeric(12,2) not null,
  costo_total           numeric(16,6) not null,
  -- Copia de la configuración al vender (como iva_es_costo en compras).
  precios_incluyen_iva  boolean not null,
  estado                text not null default 'CONFIRMADA',
  motivo_anulacion      text,
  anulada_en            timestamptz,
  anulada_por           uuid,
  solicitud_anulacion   text,
  solicitada_en         timestamptz,
  solicitada_por        uuid,
  clave_idempotencia    uuid not null,
  creado_en             timestamptz not null default now(),
  creado_por            uuid,
  constraint ventas_tipo_comprobante check (tipo_comprobante in ('NOTA_VENTA', 'FACTURA', 'NINGUNO_PERMITIDO')),
  constraint ventas_estado_valido check (estado in ('CONFIRMADA', 'ANULADA')),
  constraint ventas_total_no_negativo check (total >= 0),
  constraint ventas_totales_cuadran check (total = subtotal - descuento + iva),
  constraint ventas_anulacion_completa check (
    (estado = 'ANULADA') = (motivo_anulacion is not null and anulada_en is not null)),
  constraint ventas_idempotencia_unica unique (empresa_id, clave_idempotencia)
);
create index ventas_empresa_fecha_idx on public.ventas (empresa_id, fecha desc);
create index ventas_creado_por_idx on public.ventas (creado_por, fecha desc);
create index ventas_cliente_idx on public.ventas (cliente_id);

create table public.venta_detalles (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null references public.empresas (id) on delete restrict,
  venta_id         uuid not null references public.ventas (id) on delete restrict,
  orden            int not null,
  presentacion_id  uuid not null references public.presentaciones (id) on delete restrict,
  producto_id      uuid not null references public.productos (id) on delete restrict,
  cantidad         numeric(14,3) not null,
  precio_unitario  numeric(12,2) not null,
  tarifa_iva       numeric(5,2) not null,
  subtotal         numeric(12,2) not null,
  descuento        numeric(12,2) not null,
  iva              numeric(12,2) not null,
  total            numeric(12,2) not null,
  cantidad_base    numeric(14,3) not null,
  costo_unitario   numeric(16,6) not null,
  costo_total      numeric(16,6) not null,
  constraint venta_detalles_valores check (
    cantidad > 0 and cantidad_base > 0 and precio_unitario >= 0 and descuento >= 0
    and total >= 0 and total = subtotal - descuento + iva),
  constraint venta_detalles_orden_unico unique (venta_id, orden)
);
create index venta_detalles_venta_idx on public.venta_detalles (venta_id);
create index venta_detalles_producto_idx on public.venta_detalles (producto_id);

create table public.venta_pagos (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas (id) on delete restrict,
  venta_id    uuid not null references public.ventas (id) on delete restrict,
  medio       text not null,
  monto       numeric(12,2) not null,
  constraint venta_pagos_medio check (medio in ('EFECTIVO', 'TRANSFERENCIA', 'TARJETA', 'FIADO')),
  constraint venta_pagos_monto check (monto > 0)
);
create index venta_pagos_venta_idx on public.venta_pagos (venta_id);

create table public.devoluciones (
  id                  uuid primary key,
  empresa_id          uuid not null references public.empresas (id) on delete restrict,
  venta_id            uuid not null references public.ventas (id) on delete restrict,
  fecha               date not null,
  motivo              text not null,
  subtotal            numeric(12,2) not null,
  iva                 numeric(12,2) not null,
  total               numeric(12,2) not null,
  forma_reintegro     text not null,
  clave_idempotencia  uuid not null,
  creado_en           timestamptz not null default now(),
  creado_por          uuid,
  constraint devoluciones_forma check (forma_reintegro in ('EFECTIVO', 'ABONO_FIADO')),
  constraint devoluciones_totales check (total = subtotal + iva and total >= 0),
  constraint devoluciones_idempotencia_unica unique (empresa_id, clave_idempotencia)
);
create index devoluciones_venta_idx on public.devoluciones (venta_id);

create table public.devolucion_detalles (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references public.empresas (id) on delete restrict,
  devolucion_id     uuid not null references public.devoluciones (id) on delete restrict,
  venta_detalle_id  uuid not null references public.venta_detalles (id) on delete restrict,
  cantidad          numeric(14,3) not null,
  cantidad_base     numeric(14,3) not null,
  subtotal          numeric(12,2) not null,
  iva               numeric(12,2) not null,
  total             numeric(12,2) not null,
  costo_unitario    numeric(16,6) not null,
  costo_total       numeric(16,6) not null,
  constraint devolucion_detalles_valores check (cantidad > 0 and cantidad_base > 0 and total = subtotal + iva)
);
create index devolucion_detalles_detalle_idx on public.devolucion_detalles (venta_detalle_id);

-- Líneas, pagos y devoluciones no cambian nunca.
create trigger venta_detalles_solo_insercion before update or delete on public.venta_detalles
  for each row execute function privado.impedir_cambios();
create trigger venta_pagos_solo_insercion before update or delete on public.venta_pagos
  for each row execute function privado.impedir_cambios();
create trigger devoluciones_solo_insercion before update or delete on public.devoluciones
  for each row execute function privado.impedir_cambios();
create trigger devolucion_detalles_solo_insercion before update or delete on public.devolucion_detalles
  for each row execute function privado.impedir_cambios();

-- Una venta confirmada solo puede: recibir una solicitud de anulación, o
-- pasar a ANULADA. Una anulada ya no cambia. Nunca se borra.
create function privado.venta_cambios_permitidos()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_libres text[] := array['estado', 'motivo_anulacion', 'anulada_en', 'anulada_por',
                           'solicitud_anulacion', 'solicitada_en', 'solicitada_por'];
begin
  if tg_op = 'DELETE' then
    raise exception 'Una venta no se borra: se anula' using errcode = 'P0001';
  end if;
  if old.estado <> 'CONFIRMADA'
     or new.estado not in ('CONFIRMADA', 'ANULADA')
     or (to_jsonb(old) - v_libres) is distinct from (to_jsonb(new) - v_libres) then
    raise exception 'Una venta confirmada no se edita: solo se anula o se devuelve' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger ventas_cambios_permitidos before update or delete on public.ventas
  for each row execute function privado.venta_cambios_permitidos();

-- -----------------------------------------------------------------------------
-- 3. Permisos y RLS
-- -----------------------------------------------------------------------------
revoke all on public.clientes, public.ventas, public.venta_detalles, public.venta_pagos,
              public.devoluciones, public.devolucion_detalles
  from anon, authenticated;

grant select on public.clientes, public.venta_pagos, public.devoluciones, public.devolucion_detalles
  to authenticated;

-- El Vendedor no ve costos (D-015). Como en existencias (D-020), los costos
-- se ocultan por columna y el Dueño los pide con public.costos_venta().
grant select (id, empresa_id, fecha, cliente_id, tipo_comprobante, subtotal, descuento, iva, total,
              precios_incluyen_iva, estado, motivo_anulacion, anulada_en, anulada_por,
              solicitud_anulacion, solicitada_en, solicitada_por, clave_idempotencia,
              creado_en, creado_por)
  on public.ventas to authenticated;
grant select (id, empresa_id, venta_id, orden, presentacion_id, producto_id, cantidad, precio_unitario,
              tarifa_iva, subtotal, descuento, iva, total, cantidad_base)
  on public.venta_detalles to authenticated;

alter table public.clientes            enable row level security;
alter table public.ventas              enable row level security;
alter table public.venta_detalles      enable row level security;
alter table public.venta_pagos         enable row level security;
alter table public.devoluciones        enable row level security;
alter table public.devolucion_detalles enable row level security;

-- Ambos roles necesitan clientes: el Vendedor identifica al comprador de una factura.
create policy clientes_lectura on public.clientes
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

-- El Dueño ve todas las ventas; el Vendedor solo las suyas.
create policy ventas_lectura on public.ventas
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa())
         and ((select privado.mi_rol()) = 'DUENO' or creado_por = (select auth.uid())));

-- Líneas y pagos siguen a su venta (la subconsulta aplica la RLS de ventas).
create policy venta_detalles_lectura on public.venta_detalles
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa())
         and exists (select 1 from public.ventas v where v.id = venta_id));

create policy venta_pagos_lectura on public.venta_pagos
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa())
         and exists (select 1 from public.ventas v where v.id = venta_id));

create policy devoluciones_lectura on public.devoluciones
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');

create policy devolucion_detalles_lectura on public.devolucion_detalles
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');

-- -----------------------------------------------------------------------------
-- 4. Cálculo de líneas (privado)
-- -----------------------------------------------------------------------------
create type privado.linea_venta as (
  orden            int,
  presentacion_id  uuid,
  producto_id      uuid,
  nombre           text,
  cantidad         numeric,
  precio_unitario  numeric,
  tarifa_iva       numeric,
  subtotal         numeric,
  descuento        numeric,
  iva              numeric,
  total            numeric,
  cantidad_base    numeric
);

-- p_lineas: [{"presentacion_id", "cantidad", "descuento"?}]; el precio sale
-- del catálogo. El descuento es dinero sobre lo que paga el cliente (con IVA
-- si los precios lo incluyen). El Vendedor tiene un tope de descuento.
create function privado.calcular_lineas_venta(p_empresa uuid, p_rol text, p_lineas jsonb)
returns setof privado.linea_venta
language plpgsql
set search_path = ''
as $$
declare
  v_empresa  public.empresas;
  v_entrada  record;
  v_pres     record;
  v_linea    privado.linea_venta;
  v_ingresado numeric;
  v_bruto    numeric;
  v_factor   numeric;
  v_base     numeric;
begin
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    perform privado.fallar('DATOS_INVALIDOS', 'La venta necesita al menos un producto');
  end if;

  select * into v_empresa from public.empresas e where e.id = p_empresa;

  for v_entrada in
    select l.ordinality::int as orden, l.value as datos
      from jsonb_array_elements(p_lineas) with ordinality l
  loop
    begin
      v_linea.orden           := v_entrada.orden;
      v_linea.presentacion_id := (v_entrada.datos ->> 'presentacion_id')::uuid;
      v_linea.cantidad        := round((v_entrada.datos ->> 'cantidad')::numeric, 3);
      v_ingresado             := round(coalesce((v_entrada.datos ->> 'descuento')::numeric, 0), 2);
    exception
      when invalid_text_representation or numeric_value_out_of_range then
        perform privado.fallar('DATOS_INVALIDOS', 'Hay un número mal escrito',
                               jsonb_build_object('linea', v_entrada.orden));
    end;

    select r.factor, r.precio_venta, r.producto_id, p.tarifa_iva,
           p.nombre || case when r.factor <> 1 then ' — ' || r.nombre else '' end as nombre
      into v_pres
      from public.presentaciones r
      join public.productos p on p.id = r.producto_id
     where r.id = v_linea.presentacion_id
       and r.empresa_id = p_empresa
       and r.activo and r.se_vende and p.activo;
    if not found then
      perform privado.fallar('DATOS_INVALIDOS', 'El producto no existe o no se vende',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    if v_pres.precio_venta is null then
      perform privado.fallar('DATOS_INVALIDOS', v_pres.nombre || ' no tiene precio de venta',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    if v_linea.cantidad is null or v_linea.cantidad <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad debe ser mayor que cero',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;

    v_linea.producto_id     := v_pres.producto_id;
    v_linea.nombre          := v_pres.nombre;
    v_linea.precio_unitario := v_pres.precio_venta;
    v_linea.tarifa_iva      := v_pres.tarifa_iva;
    v_factor                := 1 + v_pres.tarifa_iva / 100;
    v_bruto                 := round(v_linea.cantidad * v_pres.precio_venta, 2);

    if v_ingresado < 0 or v_ingresado > v_bruto then
      perform privado.fallar('DATOS_INVALIDOS', 'El descuento no puede superar el valor de la línea',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    if p_rol = 'VENDEDOR' and v_ingresado > round(v_bruto * v_empresa.descuento_max_vendedor / 100, 2) then
      perform privado.fallar('DATOS_INVALIDOS',
        'El descuento supera el máximo permitido ('
          || trim(trailing '.' from trim(trailing '0' from v_empresa.descuento_max_vendedor::text)) || ' %)',
        jsonb_build_object('linea', v_entrada.orden));
    end if;

    if v_empresa.precios_incluyen_iva then
      v_linea.total     := v_bruto - v_ingresado;
      v_base            := round(v_linea.total / v_factor, 2);
      v_linea.iva       := v_linea.total - v_base;
      v_linea.subtotal  := round(v_bruto / v_factor, 2);
      v_linea.descuento := v_linea.subtotal - v_base;
    else
      v_linea.subtotal  := v_bruto;
      v_linea.descuento := v_ingresado;
      v_base            := v_bruto - v_ingresado;
      v_linea.iva       := round(v_base * v_pres.tarifa_iva / 100, 2);
      v_linea.total     := v_base + v_linea.iva;
    end if;

    v_linea.cantidad_base := round(v_linea.cantidad * v_pres.factor, 3);
    if v_linea.cantidad_base <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad es demasiado pequeña',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;

    return next v_linea;
  end loop;
end;
$$;

-- Hace legible un STOCK_INSUFICIENTE del motor: nombre del producto y cuánto queda.
create function privado.explicar_error_venta(p_detalle text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_error  jsonb := p_detalle::jsonb;
  v_nombre text;
begin
  if v_error -> 'error' ->> 'codigo' = 'STOCK_INSUFICIENTE' then
    select p.nombre into v_nombre
      from public.productos p
     where p.id = (v_error -> 'error' -> 'detalle' ->> 'producto_id')::uuid;
    return privado.error('STOCK_INSUFICIENTE',
      'No hay stock suficiente de ' || coalesce(v_nombre, 'un producto')
        || ' (quedan ' || trim(trailing '.' from trim(trailing '0' from
                            (v_error -> 'error' -> 'detalle' ->> 'disponible'))) || ')',
      v_error -> 'error' -> 'detalle');
  end if;
  return v_error;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Clientes
-- -----------------------------------------------------------------------------
-- Ambos roles crean y editan clientes; el fiado solo lo autoriza el Dueño.
-- Claves: tipo_identificacion, identificacion, nombre, telefono, correo,
-- direccion, activo; fiado_permitido y limite_fiado (solo Dueño).
create function public.guardar_cliente(p_id uuid, p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_rol      text := privado.mi_rol();
  v_id       uuid;
  v_detalle  text;
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_datos) is distinct from 'object' then
    return privado.error('DATOS_INVALIDOS');
  end if;
  if v_rol <> 'DUENO' and (p_datos ? 'fiado_permitido' or p_datos ? 'limite_fiado') then
    return privado.error('SIN_PERMISO', 'Solo el Dueño autoriza el fiado');
  end if;

  if p_id is null then
    insert into public.clientes (empresa_id, tipo_identificacion, identificacion, nombre, telefono, correo,
                                 direccion, fiado_permitido, limite_fiado, creado_por)
    values (v_empresa,
            nullif(p_datos ->> 'tipo_identificacion', ''),
            nullif(trim(p_datos ->> 'identificacion'), ''),
            trim(p_datos ->> 'nombre'),
            nullif(trim(p_datos ->> 'telefono'), ''),
            nullif(lower(trim(p_datos ->> 'correo')), ''),
            nullif(trim(p_datos ->> 'direccion'), ''),
            coalesce((p_datos ->> 'fiado_permitido')::boolean, false),
            coalesce((p_datos ->> 'limite_fiado')::numeric, 0),
            auth.uid())
    returning id into v_id;
  else
    update public.clientes c set
      tipo_identificacion = case when p_datos ? 'tipo_identificacion' then nullif(p_datos ->> 'tipo_identificacion', '') else c.tipo_identificacion end,
      identificacion      = case when p_datos ? 'identificacion'  then nullif(trim(p_datos ->> 'identificacion'), '') else c.identificacion end,
      nombre              = case when p_datos ? 'nombre'          then trim(p_datos ->> 'nombre')                   else c.nombre end,
      telefono            = case when p_datos ? 'telefono'        then nullif(trim(p_datos ->> 'telefono'), '')     else c.telefono end,
      correo              = case when p_datos ? 'correo'          then nullif(lower(trim(p_datos ->> 'correo')), '') else c.correo end,
      direccion           = case when p_datos ? 'direccion'       then nullif(trim(p_datos ->> 'direccion'), '')    else c.direccion end,
      activo              = case when p_datos ? 'activo'          then (p_datos ->> 'activo')::boolean              else c.activo end,
      fiado_permitido     = case when p_datos ? 'fiado_permitido' then (p_datos ->> 'fiado_permitido')::boolean     else c.fiado_permitido end,
      limite_fiado        = case when p_datos ? 'limite_fiado'    then (p_datos ->> 'limite_fiado')::numeric        else c.limite_fiado end
     where c.id = p_id and c.empresa_id = v_empresa
    returning id into v_id;
    if v_id is null then
      return privado.error('DATOS_INVALIDOS', 'El cliente no existe');
    end if;
  end if;

  return privado.ok(jsonb_build_object('id', v_id));
exception
  when unique_violation then
    return privado.error('DUPLICADO', 'Ya existe un cliente con esa identificación');
  when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS',
      case v_detalle
        when 'clientes_identificacion_formato'   then 'El RUC tiene 13 dígitos y la cédula 10'
        when 'clientes_identificacion_completa'  then 'Indica el tipo y el número de identificación'
        else null
      end,
      jsonb_build_object('restriccion', nullif(v_detalle, '')));
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Ventas
-- -----------------------------------------------------------------------------

-- Vista previa para el punto de venta: los mismos cálculos, sin guardar ni
-- mostrar costos. La pueden usar ambos roles.
create function public.calcular_venta(p_lineas jsonb)
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
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'orden',           l.orden,
           'nombre',          l.nombre,
           'precio_unitario', l.precio_unitario::numeric(12,2)::text,
           'subtotal',        l.subtotal::numeric(12,2)::text,
           'descuento',       l.descuento::numeric(12,2)::text,
           'iva',             l.iva::numeric(12,2)::text,
           'total',           l.total::numeric(12,2)::text)
         order by l.orden), '[]'::jsonb)
    into v_lineas
    from privado.calcular_lineas_venta(v_empresa, privado.mi_rol(), p_lineas) l;

  return privado.ok(jsonb_build_object(
    'lineas',    v_lineas,
    'subtotal',  (select sum((x ->> 'subtotal')::numeric)::numeric(12,2)::text  from jsonb_array_elements(v_lineas) x),
    'descuento', (select sum((x ->> 'descuento')::numeric)::numeric(12,2)::text from jsonb_array_elements(v_lineas) x),
    'iva',       (select sum((x ->> 'iva')::numeric)::numeric(12,2)::text       from jsonb_array_elements(v_lineas) x),
    'total',     (select sum((x ->> 'total')::numeric)::numeric(12,2)::text     from jsonb_array_elements(v_lineas) x)));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
end;
$$;

-- Registra la venta, sus pagos y las salidas de inventario en una sola
-- transacción. p_pagos: [{"medio", "monto"}]; nulo = todo en efectivo.
-- Con la misma p_clave_idempotencia, un segundo toque devuelve la misma venta.
create function public.registrar_venta(
  p_lineas              jsonb,
  p_pagos               jsonb,
  p_cliente_id          uuid,
  p_tipo_comprobante    text,
  p_clave_idempotencia  uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa   public.empresas;
  v_rol       text := privado.mi_rol();
  v_id        uuid := gen_random_uuid();
  v_fecha     date;
  v_tipo      text := coalesce(p_tipo_comprobante, 'NOTA_VENTA');
  v_cliente   public.clientes;
  v_existente public.ventas;
  v_lineas    privado.linea_venta[];
  v_linea     privado.linea_venta;
  v_total     numeric;
  v_pagos     jsonb;
  v_pagado    numeric;
  v_mov       public.movimientos_inventario;
  v_costos    jsonb := '{}';
  v_detalle   text;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la clave de idempotencia');
  end if;

  select * into v_existente
    from public.ventas v
   where v.empresa_id = v_empresa.id and v.clave_idempotencia = p_clave_idempotencia;
  if found then
    return privado.ok(jsonb_build_object('venta_id', v_existente.id, 'repetido', true,
                                         'total', v_existente.total::text));
  end if;

  if v_tipo not in ('NOTA_VENTA', 'FACTURA', 'NINGUNO_PERMITIDO') then
    return privado.error('DATOS_INVALIDOS', 'Tipo de comprobante no válido');
  end if;
  if p_cliente_id is not null then
    select * into v_cliente from public.clientes c
     where c.id = p_cliente_id and c.empresa_id = v_empresa.id and c.activo;
    if not found then
      return privado.error('DATOS_INVALIDOS', 'El cliente no existe o está inactivo');
    end if;
  end if;

  select array_agg(l order by l.orden) into v_lineas
    from privado.calcular_lineas_venta(v_empresa.id, v_rol, p_lineas) l;
  select sum(l.total) into v_total from unnest(v_lineas) l;

  -- Comprobante (D-005; montos configurables por el contador)
  if v_tipo = 'FACTURA' and v_total > v_empresa.monto_max_consumidor_final
     and v_cliente.identificacion is null then
    return privado.error('DATOS_INVALIDOS',
      'Una factura de más de ' || v_empresa.monto_max_consumidor_final::text
        || ' necesita un cliente con RUC o cédula');
  end if;
  if v_tipo = 'NINGUNO_PERMITIDO' and v_total > v_empresa.monto_max_sin_comprobante then
    return privado.error('DATOS_INVALIDOS', 'Esta venta necesita comprobante');
  end if;

  -- Pagos
  v_pagos := coalesce(p_pagos, case when v_total > 0
                                    then jsonb_build_array(jsonb_build_object('medio', 'EFECTIVO', 'monto', v_total))
                                    else '[]'::jsonb end);
  if jsonb_typeof(v_pagos) <> 'array' then
    return privado.error('DATOS_INVALIDOS', 'Pagos mal formados');
  end if;
  if exists (select 1 from jsonb_array_elements(v_pagos) p where p ->> 'medio' = 'FIADO') then
    return privado.error('DATOS_INVALIDOS', 'La venta al fiado todavía no está disponible');
  end if;
  begin
    select coalesce(sum(round((p ->> 'monto')::numeric, 2)), 0) into v_pagado
      from jsonb_array_elements(v_pagos) p;
  exception
    when invalid_text_representation or numeric_value_out_of_range then
      return privado.error('DATOS_INVALIDOS', 'Un monto de pago está mal escrito');
  end;
  if v_pagado <> v_total then
    return privado.error('DATOS_INVALIDOS', 'Los pagos no suman el total de la venta',
      jsonb_build_object('total', v_total::numeric(12,2)::text, 'pagado', v_pagado::numeric(12,2)::text));
  end if;

  v_fecha := (now() at time zone v_empresa.zona_horaria)::date;

  -- Salidas de inventario primero (en orden de producto, para no bloquearse en
  -- cruz con otra venta): así cada línea guarda el costo con que salió.
  for v_linea in select * from unnest(v_lineas) l order by l.producto_id, l.orden loop
    v_mov := privado.registrar_movimiento(
      v_empresa.id, v_linea.producto_id, 'VENTA', -v_linea.cantidad_base, null,
      'ventas', v_id, null, null, v_fecha);
    v_costos := v_costos || jsonb_build_object(v_linea.orden::text, jsonb_build_object(
      'costo_unitario', v_mov.costo_unitario, 'costo_total', -v_mov.valor));
  end loop;

  insert into public.ventas (id, empresa_id, fecha, cliente_id, tipo_comprobante, subtotal, descuento,
                             iva, total, costo_total, precios_incluyen_iva, clave_idempotencia, creado_por)
  select v_id, v_empresa.id, v_fecha, p_cliente_id, v_tipo,
         sum(l.subtotal), sum(l.descuento), sum(l.iva), sum(l.total),
         sum((v_costos -> l.orden::text ->> 'costo_total')::numeric),
         v_empresa.precios_incluyen_iva, p_clave_idempotencia, auth.uid()
    from unnest(v_lineas) l;

  insert into public.venta_detalles (empresa_id, venta_id, orden, presentacion_id, producto_id, cantidad,
                                     precio_unitario, tarifa_iva, subtotal, descuento, iva, total,
                                     cantidad_base, costo_unitario, costo_total)
  select v_empresa.id, v_id, l.orden, l.presentacion_id, l.producto_id, l.cantidad,
         l.precio_unitario, l.tarifa_iva, l.subtotal, l.descuento, l.iva, l.total, l.cantidad_base,
         (v_costos -> l.orden::text ->> 'costo_unitario')::numeric,
         (v_costos -> l.orden::text ->> 'costo_total')::numeric
    from unnest(v_lineas) l;

  insert into public.venta_pagos (empresa_id, venta_id, medio, monto)
  select v_empresa.id, v_id, p ->> 'medio', round((p ->> 'monto')::numeric, 2)
    from jsonb_array_elements(v_pagos) p;

  return privado.ok(jsonb_build_object('venta_id', v_id, 'repetido', false, 'total', v_total::numeric(12,2)::text));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return privado.explicar_error_venta(v_detalle);
  when check_violation then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS',
      case v_detalle when 'venta_pagos_monto' then 'Cada pago debe ser mayor que cero'
                     when 'venta_pagos_medio' then 'Medio de pago no válido'
                     else null end);
  when unique_violation then
    -- Dos toques simultáneos con la misma clave: el primero ya confirmó la
    -- venta (la unicidad esperó a que terminara); se devuelve esa misma.
    select * into v_existente from public.ventas v
     where v.empresa_id = v_empresa.id and v.clave_idempotencia = p_clave_idempotencia;
    if found then
      return privado.ok(jsonb_build_object('venta_id', v_existente.id, 'repetido', true,
                                           'total', v_existente.total::text));
    end if;
    return privado.error('DUPLICADO');
end;
$$;

-- El Vendedor no anula (HU-03): pide la anulación de una venta suya y el Dueño decide.
create function public.solicitar_anulacion_venta(p_venta_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_rol      text := privado.mi_rol();
  v_venta    public.ventas;
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;
  if nullif(trim(p_motivo), '') is null then
    return privado.error('DATOS_INVALIDOS', 'El motivo es obligatorio');
  end if;

  select * into v_venta from public.ventas v
   where v.id = p_venta_id and v.empresa_id = v_empresa
     and (v_rol = 'DUENO' or v.creado_por = auth.uid())
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La venta no existe');
  end if;
  if v_venta.estado <> 'CONFIRMADA' then
    return privado.error('DATOS_INVALIDOS', 'La venta ya está anulada');
  end if;

  update public.ventas v
     set solicitud_anulacion = trim(p_motivo), solicitada_en = now(), solicitada_por = auth.uid()
   where v.id = v_venta.id;

  return privado.ok(jsonb_build_object('venta_id', v_venta.id));
end;
$$;

-- Devuelve al inventario cada línea al costo con que salió (Fase 3, como una
-- devolución completa). Una venta con devoluciones no se anula: se devuelve el resto.
create function public.anular_venta(p_venta_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_venta    public.ventas;
  v_linea    public.venta_detalles;
  v_detalle  text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO', 'Solo el Dueño anula ventas; puedes solicitar la anulación');
  end if;
  if nullif(trim(p_motivo), '') is null then
    return privado.error('DATOS_INVALIDOS', 'El motivo es obligatorio');
  end if;

  select * into v_venta from public.ventas v
   where v.id = p_venta_id and v.empresa_id = v_empresa
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La venta no existe');
  end if;
  if v_venta.estado = 'ANULADA' then
    return privado.ok(jsonb_build_object('venta_id', v_venta.id, 'repetido', true));
  end if;
  if exists (select 1 from public.devoluciones d where d.venta_id = v_venta.id) then
    return privado.error('DATOS_INVALIDOS', 'La venta tiene devoluciones: devuelve lo que falta en lugar de anular');
  end if;

  for v_linea in
    select * from public.venta_detalles d where d.venta_id = v_venta.id order by d.producto_id, d.orden
  loop
    perform privado.registrar_movimiento(
      v_empresa, v_linea.producto_id, 'ANULACION_VENTA', v_linea.cantidad_base, v_linea.costo_unitario,
      'ventas', v_venta.id, trim(p_motivo));
  end loop;

  update public.ventas v
     set estado = 'ANULADA', motivo_anulacion = trim(p_motivo), anulada_en = now(), anulada_por = auth.uid()
   where v.id = v_venta.id;

  insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes, despues)
  values (v_empresa, auth.uid(), 'VENTA_ANULADA', 'ventas', v_venta.id,
          jsonb_build_object('estado', 'CONFIRMADA', 'total', v_venta.total),
          jsonb_build_object('estado', 'ANULADA', 'motivo', trim(p_motivo)));

  return privado.ok(jsonb_build_object('venta_id', v_venta.id, 'repetido', false));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
end;
$$;

-- p_lineas: [{"venta_detalle_id", "cantidad"}], cantidad en unidades de la
-- presentación vendida. No se devuelve más de lo vendido. Montos y unidades
-- base son proporcionales; la última devolución de una línea toma exactamente
-- lo que faltaba, para que la suma cuadre con la venta.
create function public.registrar_devolucion(
  p_venta_id            uuid,
  p_lineas              jsonb,
  p_motivo              text,
  p_forma_reintegro     text,
  p_clave_idempotencia  uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa    public.empresas;
  v_venta      public.ventas;
  v_existente  public.devoluciones;
  v_id         uuid := gen_random_uuid();
  v_fecha      date;
  v_entrada    record;
  v_d          public.venta_detalles;
  v_previo     record;
  v_cantidad   numeric;
  v_cant_base  numeric;
  v_total      numeric;
  v_subtotal   numeric;
  v_calculo    jsonb := '[]';
  v_mov        public.movimientos_inventario;
  v_detalle    text;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la clave de idempotencia');
  end if;

  select * into v_existente from public.devoluciones d
   where d.empresa_id = v_empresa.id and d.clave_idempotencia = p_clave_idempotencia;
  if found then
    return privado.ok(jsonb_build_object('devolucion_id', v_existente.id, 'repetido', true,
                                         'total', v_existente.total::text));
  end if;

  if nullif(trim(p_motivo), '') is null then
    return privado.error('DATOS_INVALIDOS', 'El motivo es obligatorio');
  end if;
  if coalesce(p_forma_reintegro, 'EFECTIVO') = 'ABONO_FIADO' then
    return privado.error('DATOS_INVALIDOS', 'El abono a fiado todavía no está disponible');
  end if;
  if coalesce(p_forma_reintegro, 'EFECTIVO') <> 'EFECTIVO' then
    return privado.error('DATOS_INVALIDOS', 'Forma de reintegro no válida');
  end if;
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    return privado.error('DATOS_INVALIDOS', 'Indica qué se devuelve');
  end if;

  -- Bloquea la venta: dos devoluciones a la vez no pueden pasar del total vendido.
  select * into v_venta from public.ventas v
   where v.id = p_venta_id and v.empresa_id = v_empresa.id
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La venta no existe');
  end if;
  if v_venta.estado <> 'CONFIRMADA' then
    return privado.error('DATOS_INVALIDOS', 'La venta está anulada');
  end if;
  if (select count(*) from jsonb_array_elements(p_lineas) l)
     <> (select count(distinct l ->> 'venta_detalle_id') from jsonb_array_elements(p_lineas) l) then
    return privado.error('DATOS_INVALIDOS', 'Una línea de la venta aparece dos veces');
  end if;

  v_fecha := (now() at time zone v_empresa.zona_horaria)::date;

  -- 1) Validar y calcular cada línea (la cabecera necesita los totales y la
  --    tabla es de solo inserción).
  for v_entrada in
    select (l ->> 'venta_detalle_id')::uuid as detalle_id, l ->> 'cantidad' as cantidad
      from jsonb_array_elements(p_lineas) l
     order by 1
  loop
    select * into v_d from public.venta_detalles d
     where d.id = v_entrada.detalle_id and d.venta_id = v_venta.id;
    if not found then
      perform privado.fallar('DATOS_INVALIDOS', 'La línea no pertenece a esta venta');
    end if;

    v_cantidad := round(v_entrada.cantidad::numeric, 3);
    select coalesce(sum(x.cantidad), 0) as cantidad, coalesce(sum(x.cantidad_base), 0) as cantidad_base,
           coalesce(sum(x.total), 0) as total, coalesce(sum(x.subtotal), 0) as subtotal
      into v_previo
      from public.devolucion_detalles x where x.venta_detalle_id = v_d.id;

    if v_cantidad is null or v_cantidad <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad a devolver debe ser mayor que cero');
    end if;
    if v_cantidad > v_d.cantidad - v_previo.cantidad then
      perform privado.fallar('DATOS_INVALIDOS',
        'No se puede devolver más de lo vendido (quedan '
          || trim(trailing '.' from trim(trailing '0' from (v_d.cantidad - v_previo.cantidad)::text)) || ')');
    end if;

    if v_cantidad = v_d.cantidad - v_previo.cantidad then
      v_cant_base := v_d.cantidad_base - v_previo.cantidad_base;
      v_total     := v_d.total - v_previo.total;
      v_subtotal  := (v_d.subtotal - v_d.descuento) - v_previo.subtotal;
    else
      v_cant_base := round(v_d.cantidad_base * v_cantidad / v_d.cantidad, 3);
      v_total     := round(v_d.total * v_cantidad / v_d.cantidad, 2);
      v_subtotal  := round((v_d.subtotal - v_d.descuento) * v_cantidad / v_d.cantidad, 2);
    end if;
    if v_cant_base <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad a devolver es demasiado pequeña');
    end if;

    v_calculo := v_calculo || jsonb_build_array(jsonb_build_object(
      'detalle_id', v_d.id, 'producto_id', v_d.producto_id, 'costo_unitario', v_d.costo_unitario,
      'cantidad', v_cantidad, 'cantidad_base', v_cant_base, 'subtotal', v_subtotal, 'total', v_total));
  end loop;

  -- 2) Cabecera con sus totales.
  insert into public.devoluciones (id, empresa_id, venta_id, fecha, motivo, subtotal, iva, total,
                                   forma_reintegro, clave_idempotencia, creado_por)
  select v_id, v_empresa.id, v_venta.id, v_fecha, trim(p_motivo),
         sum((c ->> 'subtotal')::numeric), sum((c ->> 'total')::numeric - (c ->> 'subtotal')::numeric),
         sum((c ->> 'total')::numeric), 'EFECTIVO', p_clave_idempotencia, auth.uid()
    from jsonb_array_elements(v_calculo) c;

  -- 3) Entradas al inventario al costo con que salió cada línea, y sus líneas.
  for v_entrada in
    select c from jsonb_array_elements(v_calculo) c order by c ->> 'producto_id', c ->> 'detalle_id'
  loop
    v_mov := privado.registrar_movimiento(
      v_empresa.id, (v_entrada.c ->> 'producto_id')::uuid, 'DEVOLUCION_VENTA',
      (v_entrada.c ->> 'cantidad_base')::numeric, (v_entrada.c ->> 'costo_unitario')::numeric,
      'devoluciones', v_id, trim(p_motivo), null, v_fecha);

    insert into public.devolucion_detalles (empresa_id, devolucion_id, venta_detalle_id, cantidad, cantidad_base,
                                            subtotal, iva, total, costo_unitario, costo_total)
    values (v_empresa.id, v_id, (v_entrada.c ->> 'detalle_id')::uuid,
            (v_entrada.c ->> 'cantidad')::numeric, (v_entrada.c ->> 'cantidad_base')::numeric,
            (v_entrada.c ->> 'subtotal')::numeric,
            (v_entrada.c ->> 'total')::numeric - (v_entrada.c ->> 'subtotal')::numeric,
            (v_entrada.c ->> 'total')::numeric,
            (v_entrada.c ->> 'costo_unitario')::numeric, v_mov.valor);
  end loop;

  return privado.ok(jsonb_build_object('devolucion_id', v_id, 'repetido', false,
    'total', (select sum((c ->> 'total')::numeric)::numeric(12,2)::text from jsonb_array_elements(v_calculo) c)));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
  when invalid_text_representation or numeric_value_out_of_range then
    return privado.error('DATOS_INVALIDOS', 'Hay un número mal escrito');
  when unique_violation then
    select * into v_existente from public.devoluciones d
     where d.empresa_id = v_empresa.id and d.clave_idempotencia = p_clave_idempotencia;
    if found then
      return privado.ok(jsonb_build_object('devolucion_id', v_existente.id, 'repetido', true,
                                           'total', v_existente.total::text));
    end if;
    return privado.error('DUPLICADO');
end;
$$;

-- Costos y utilidad de una venta, para quien ve costos (D-015, D-020).
create function public.costos_venta(p_venta_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_venta    public.ventas;
begin
  if v_empresa is null or not privado.ve_costos() then
    return privado.error('SIN_PERMISO');
  end if;

  select * into v_venta from public.ventas v where v.id = p_venta_id and v.empresa_id = v_empresa;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La venta no existe');
  end if;

  return privado.ok(jsonb_build_object(
    'costo_total', v_venta.costo_total::text,
    -- Utilidad sobre la venta sin IVA (Fase 3: 9,00 − 7,365882).
    'utilidad',    (v_venta.subtotal - v_venta.descuento - v_venta.costo_total)::text,
    'lineas', (select coalesce(jsonb_agg(jsonb_build_object(
                        'orden', d.orden,
                        'costo_unitario', d.costo_unitario::text,
                        'costo_total', d.costo_total::text) order by d.orden), '[]'::jsonb)
                 from public.venta_detalles d where d.venta_id = v_venta.id)));
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Permisos de las funciones
-- -----------------------------------------------------------------------------
revoke all on function
  privado.venta_cambios_permitidos(),
  privado.calcular_lineas_venta(uuid, text, jsonb),
  privado.explicar_error_venta(text)
  from public, anon, authenticated;

revoke all on function
  public.guardar_cliente(uuid, jsonb),
  public.calcular_venta(jsonb),
  public.registrar_venta(jsonb, jsonb, uuid, text, uuid),
  public.solicitar_anulacion_venta(uuid, text),
  public.anular_venta(uuid, text),
  public.registrar_devolucion(uuid, jsonb, text, text, uuid),
  public.costos_venta(uuid)
  from public, anon;
grant execute on function
  public.guardar_cliente(uuid, jsonb),
  public.calcular_venta(jsonb),
  public.registrar_venta(jsonb, jsonb, uuid, text, uuid),
  public.solicitar_anulacion_venta(uuid, text),
  public.anular_venta(uuid, text),
  public.registrar_devolucion(uuid, jsonb, text, text, uuid),
  public.costos_venta(uuid)
  to authenticated;
