-- =============================================================================
-- Productos con los datos del SRI e IVA de ventas por fecha (D-044, D-045)
--
-- 1. El producto guarda lo que pide el formulario «Nuevo producto» del portal
--    del SRI: código principal y auxiliar (hasta 25 caracteres), información
--    adicional y la tarifa de IVA como código del SRI (codigoPorcentaje):
--    0 %, 5 %, 15 %, No objeto de impuesto o Exento de IVA.
-- 2. Al importar una factura del SRI, una línea sin producto se asocia sola si
--    su código es el código principal o auxiliar de un producto.
-- 3. El IVA que se cobra en las ventas depende de la fecha: el Dueño fija
--    «desde tal día las ventas van con IVA 0 %» (o vuelven a la tarifa de cada
--    producto). La tarifa del producto no se toca: se usa cuando se vuelva a
--    cobrar IVA. Las ventas ya hechas no cambian.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Datos del SRI en el producto
-- -----------------------------------------------------------------------------
-- Tarifa de un codigoPorcentaje del SRI (tabla 17 de la ficha técnica).
create function privado.tarifa_codigo_iva(p_codigo text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case p_codigo
           when '0' then 0 when '2' then 12 when '3' then 14 when '4' then 15
           when '5' then 5 when '6' then 0 when '7' then 0 when '10' then 13
         end::numeric;
$$;

-- Código de una tarifa. El 0 % es «0»; No objeto y Exento solo se eligen.
create function privado.codigo_tarifa_iva(p_tarifa numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_tarifa
           when 0 then '0' when 12 then '2' when 14 then '3' when 15 then '4'
           when 5 then '5' when 13 then '10'
         end;
$$;

alter table public.productos
  add column codigo_principal      text,
  add column codigo_auxiliar       text,
  add column informacion_adicional text,
  add column codigo_iva            text;

update public.productos p set codigo_iva = privado.codigo_tarifa_iva(p.tarifa_iva);

alter table public.productos
  alter column codigo_iva set not null,
  add constraint productos_codigo_principal_largo check (length(trim(codigo_principal)) between 1 and 25),
  add constraint productos_codigo_auxiliar_largo check (length(trim(codigo_auxiliar)) between 1 and 25),
  add constraint productos_informacion_adicional_largo check (length(trim(informacion_adicional)) between 1 and 300),
  add constraint productos_codigo_iva_valido check (codigo_iva in ('0', '2', '3', '4', '5', '6', '7', '10')),
  add constraint productos_tarifa_de_codigo check (tarifa_iva = privado.tarifa_codigo_iva(codigo_iva));

create unique index productos_codigo_principal_unico
  on public.productos (empresa_id, codigo_principal) where codigo_principal is not null;
create index productos_codigo_auxiliar_idx
  on public.productos (empresa_id, codigo_auxiliar) where codigo_auxiliar is not null;

-- Tarifa y código van juntos: quien cambia uno arrastra el otro. Así siguen
-- sirviendo las llamadas que solo mandan tarifa_iva.
create function privado.producto_tarifa_y_codigo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.codigo_iva is null then
      new.codigo_iva := privado.codigo_tarifa_iva(new.tarifa_iva);
    else
      new.tarifa_iva := privado.tarifa_codigo_iva(new.codigo_iva);
    end if;
  elsif new.codigo_iva is distinct from old.codigo_iva then
    new.tarifa_iva := privado.tarifa_codigo_iva(new.codigo_iva);
  elsif new.tarifa_iva is distinct from old.tarifa_iva then
    new.codigo_iva := privado.codigo_tarifa_iva(new.tarifa_iva);
  end if;
  return new;
end;
$$;

create trigger productos_tarifa_y_codigo before insert or update on public.productos
  for each row execute function privado.producto_tarifa_y_codigo();

-- Se reemplaza para recibir los campos nuevos. Claves de p_datos: nombre,
-- categoria_id, unidad_base, codigo_iva (o tarifa_iva), stock_minimo, activo,
-- codigo_principal, codigo_auxiliar, informacion_adicional; al crear también
-- precio_venta y codigo_barras de la presentación base.
create or replace function public.guardar_producto(p_id uuid, p_datos jsonb)
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
    insert into public.productos (empresa_id, nombre, categoria_id, unidad_base, tarifa_iva, codigo_iva,
                                  stock_minimo, codigo_principal, codigo_auxiliar, informacion_adicional,
                                  creado_por)
    values (v_empresa,
            trim(p_datos ->> 'nombre'),
            (p_datos ->> 'categoria_id')::uuid,
            coalesce(p_datos ->> 'unidad_base', 'UND'),
            coalesce((p_datos ->> 'tarifa_iva')::numeric, privado.tarifa_codigo_iva(p_datos ->> 'codigo_iva')),
            p_datos ->> 'codigo_iva',
            coalesce((p_datos ->> 'stock_minimo')::numeric, 0),
            nullif(trim(p_datos ->> 'codigo_principal'), ''),
            nullif(trim(p_datos ->> 'codigo_auxiliar'), ''),
            nullif(trim(p_datos ->> 'informacion_adicional'), ''),
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
      tarifa_iva   = case when p_datos ? 'tarifa_iva' and not p_datos ? 'codigo_iva'
                          then (p_datos ->> 'tarifa_iva')::numeric                                    else p.tarifa_iva end,
      codigo_iva   = case when p_datos ? 'codigo_iva'   then p_datos ->> 'codigo_iva'                 else p.codigo_iva end,
      stock_minimo = case when p_datos ? 'stock_minimo' then (p_datos ->> 'stock_minimo')::numeric    else p.stock_minimo end,
      activo       = case when p_datos ? 'activo'       then (p_datos ->> 'activo')::boolean          else p.activo end,
      codigo_principal = case when p_datos ? 'codigo_principal'
                              then nullif(trim(p_datos ->> 'codigo_principal'), '')                   else p.codigo_principal end,
      codigo_auxiliar  = case when p_datos ? 'codigo_auxiliar'
                              then nullif(trim(p_datos ->> 'codigo_auxiliar'), '')                    else p.codigo_auxiliar end,
      informacion_adicional = case when p_datos ? 'informacion_adicional'
                              then nullif(trim(p_datos ->> 'informacion_adicional'), '')              else p.informacion_adicional end
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
    get stacked diagnostics v_detalle = constraint_name;
    if v_detalle = 'productos_codigo_principal_unico' then
      return privado.error('DUPLICADO', 'El código principal ya está en uso');
    end if;
    return privado.error('DUPLICADO', 'El código de barras ya está en uso');
  when check_violation or not_null_violation or invalid_text_representation
       or numeric_value_out_of_range then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS', null, jsonb_build_object('restriccion', nullif(v_detalle, '')));
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Código del SRI en las líneas de venta
-- -----------------------------------------------------------------------------
-- Con tarifa 0 % no se distingue si fue 0 %, No objeto o Exento; el contador
-- los declara por separado. Se guarda el código con que salió cada línea.
alter table public.venta_detalles add column codigo_iva text;

alter table public.venta_detalles disable trigger venta_detalles_solo_insercion;
update public.venta_detalles d
   set codigo_iva = coalesce(
         (select p.codigo_iva from public.productos p
           where p.id = d.producto_id and d.tarifa_iva = 0 and p.codigo_iva in ('6', '7')),
         privado.codigo_tarifa_iva(d.tarifa_iva));
alter table public.venta_detalles enable trigger venta_detalles_solo_insercion;

create function privado.venta_detalle_codigo_iva()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.codigo_iva is null then
    new.codigo_iva := coalesce(
      (select p.codigo_iva from public.productos p
        where p.id = new.producto_id and new.tarifa_iva = 0 and p.codigo_iva in ('6', '7')),
      privado.codigo_tarifa_iva(new.tarifa_iva));
  end if;
  return new;
end;
$$;

create trigger venta_detalles_codigo_iva before insert on public.venta_detalles
  for each row execute function privado.venta_detalle_codigo_iva();

alter table public.venta_detalles
  alter column codigo_iva set not null,
  add constraint venta_detalles_codigo_iva check (tarifa_iva = privado.tarifa_codigo_iva(codigo_iva));

grant select (codigo_iva) on public.venta_detalles to authenticated;

-- -----------------------------------------------------------------------------
-- 3. Facturas del SRI: asociar por código principal o auxiliar
-- -----------------------------------------------------------------------------
-- Después de la memoria de códigos y del código de barras (importar_comprobante),
-- una línea que sigue sin producto busca el código en los productos activos y
-- toma su presentación base.
create function privado.comprobante_linea_por_codigo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.presentacion_id is null and new.codigo is not null then
    select r.id into new.presentacion_id
      from public.productos p
      join public.presentaciones r on r.producto_id = p.id and r.factor = 1 and r.activo
     where p.empresa_id = new.empresa_id and p.activo
       and (p.codigo_principal = new.codigo or p.codigo_auxiliar = new.codigo)
     order by (p.codigo_principal = new.codigo) desc nulls last, r.creado_en
     limit 1;
  end if;
  return new;
end;
$$;

create trigger comprobante_lineas_por_codigo before insert on public.comprobante_lineas
  for each row execute function privado.comprobante_linea_por_codigo();

-- -----------------------------------------------------------------------------
-- 4. IVA de ventas por fecha
-- -----------------------------------------------------------------------------
-- Cada fila rige desde su fecha hasta la siguiente. Sin filas, se cobra la
-- tarifa de cada producto. Solo se fijan fechas de hoy en adelante: las
-- ventas pasadas ya se calcularon y no cambian.
create table public.iva_ventas_periodos (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas (id) on delete restrict,
  desde       date not null,
  iva_cero    boolean not null,
  nota        text,
  creado_en   timestamptz not null default now(),
  creado_por  uuid,
  constraint iva_ventas_periodos_unico unique (empresa_id, desde),
  constraint iva_ventas_periodos_nota check (length(nota) <= 200)
);

revoke all on public.iva_ventas_periodos from anon, authenticated;
grant select on public.iva_ventas_periodos to authenticated;
alter table public.iva_ventas_periodos enable row level security;
-- El Vendedor también lo lee: «Vender» avisa que las ventas van con IVA 0 %.
create policy iva_ventas_periodos_lectura on public.iva_ventas_periodos
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

create function privado.iva_cero_en(p_empresa uuid, p_fecha date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select v.iva_cero from public.iva_ventas_periodos v
                    where v.empresa_id = p_empresa and v.desde <= p_fecha
                    order by v.desde desc limit 1), false);
$$;

-- Fija (o corrige, si ya hay una fila con esa fecha) el IVA desde p_desde.
create function public.fijar_iva_ventas(p_desde date, p_iva_cero boolean, p_nota text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  public.empresas;
  v_hoy      date;
  v_anterior public.iva_ventas_periodos;
  v_periodo  public.iva_ventas_periodos;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  v_hoy := (now() at time zone v_empresa.zona_horaria)::date;
  if p_desde is null or p_iva_cero is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la fecha o si se cobra IVA');
  end if;
  if p_desde < v_hoy then
    return privado.error('DATOS_INVALIDOS', 'La fecha no puede ser anterior a hoy: las ventas pasadas no cambian');
  end if;
  if length(p_nota) > 200 then
    return privado.error('DATOS_INVALIDOS', 'La nota es demasiado larga');
  end if;

  select * into v_anterior from public.iva_ventas_periodos v
   where v.empresa_id = v_empresa.id and v.desde = p_desde
     for update;

  insert into public.iva_ventas_periodos (empresa_id, desde, iva_cero, nota, creado_por)
  values (v_empresa.id, p_desde, p_iva_cero, nullif(trim(p_nota), ''), auth.uid())
  on conflict (empresa_id, desde) do update
     set iva_cero = excluded.iva_cero, nota = excluded.nota,
         creado_en = now(), creado_por = excluded.creado_por
  returning * into v_periodo;

  insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes, despues)
  values (v_empresa.id, auth.uid(), 'IVA_VENTAS_FIJADO', 'iva_ventas_periodos', v_periodo.id,
          case when v_anterior.id is not null then to_jsonb(v_anterior) end, to_jsonb(v_periodo));

  return privado.ok(jsonb_build_object('id', v_periodo.id));
end;
$$;

-- Quita un cambio que todavía no empieza (uno de hoy ya puede tener ventas).
create function public.quitar_iva_ventas(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  public.empresas;
  v_periodo  public.iva_ventas_periodos;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  delete from public.iva_ventas_periodos v
   where v.id = p_id and v.empresa_id = v_empresa.id
     and v.desde > (now() at time zone v_empresa.zona_horaria)::date
  returning * into v_periodo;
  if v_periodo.id is null then
    return privado.error('DATOS_INVALIDOS', 'Solo se quita un cambio que todavía no empieza');
  end if;

  insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes)
  values (v_empresa.id, auth.uid(), 'IVA_VENTAS_QUITADO', 'iva_ventas_periodos', v_periodo.id, to_jsonb(v_periodo));

  return privado.ok(jsonb_build_object('id', v_periodo.id));
end;
$$;

-- Se reemplaza el cálculo de líneas: mientras rija «IVA 0 %», toda línea sale
-- con tarifa 0 y sin IVA. Con precios que incluyen IVA, el cliente paga lo
-- mismo y todo es base; sin ellos, paga solo la base.
create or replace function privado.calcular_lineas_venta(p_empresa uuid, p_rol text, p_lineas jsonb)
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
  v_cero     boolean;
begin
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    perform privado.fallar('DATOS_INVALIDOS', 'La venta necesita al menos un producto');
  end if;

  select * into v_empresa from public.empresas e where e.id = p_empresa;
  v_cero := privado.iva_cero_en(p_empresa, (now() at time zone v_empresa.zona_horaria)::date);

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
    v_linea.tarifa_iva      := case when v_cero then 0 else v_pres.tarifa_iva end;
    v_factor                := 1 + v_linea.tarifa_iva / 100;
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
      v_linea.iva       := round(v_base * v_linea.tarifa_iva / 100, 2);
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


-- -----------------------------------------------------------------------------
-- 5. Permisos de las funciones
-- -----------------------------------------------------------------------------
revoke all on function
  privado.tarifa_codigo_iva(text),
  privado.codigo_tarifa_iva(numeric),
  privado.producto_tarifa_y_codigo(),
  privado.venta_detalle_codigo_iva(),
  privado.comprobante_linea_por_codigo(),
  privado.iva_cero_en(uuid, date)
  from public, anon, authenticated;

revoke all on function
  public.fijar_iva_ventas(date, boolean, text),
  public.quitar_iva_ventas(uuid)
  from public, anon;
grant execute on function
  public.fijar_iva_ventas(date, boolean, text),
  public.quitar_iva_ventas(uuid)
  to authenticated;
