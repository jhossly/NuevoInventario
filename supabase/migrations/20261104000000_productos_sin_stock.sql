-- =============================================================================
-- Productos sin control de stock: recargas y servicios (D-046)
--
-- Una recarga telefónica o un servicio se vende sin tener existencias. El
-- producto lleva controla_stock = false y entonces:
--   * vender, anular, devolver, comprar y anular compras no mueven stock ni
--     escriben el kardex: el motor devuelve el movimiento calculado sin
--     guardarlo, para que cada línea conserve su costo;
--   * el costo por unidad es existencias.ultimo_costo (oculto al Vendedor,
--     D-020): lo fija el Dueño en el producto o lo actualiza cada compra; sin
--     costo, se vende a costo 0;
--   * apertura, ajuste, merma y conteo se rechazan.
-- =============================================================================

alter table public.productos add column controla_stock boolean not null default true;

-- -----------------------------------------------------------------------------
-- 1. Motor de inventario
-- -----------------------------------------------------------------------------
create or replace function privado.registrar_movimiento(
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
  v_controla   boolean;
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
  select p.controla_stock into v_controla
    from public.productos p
   where p.id = p_producto and p.empresa_id = p_empresa;
  if not found then
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

  -- Sin control de stock: nada se guarda en el libro ni en el saldo.
  if not v_controla then
    if p_tipo not in ('VENTA', 'ANULACION_VENTA', 'DEVOLUCION_VENTA', 'COMPRA', 'ANULACION_COMPRA') then
      perform privado.fallar('DATOS_INVALIDOS', 'Este producto no controla stock: no se ajusta ni se cuenta');
    end if;
    v_costo := coalesce(p_costo_unitario, v_existencia.ultimo_costo, 0);
    if p_tipo = 'COMPRA' then
      update public.existencias x
         set ultimo_costo = round(v_costo, 6), actualizado_en = now()
       where x.id = v_existencia.id;
    end if;
    v_mov.empresa_id     := p_empresa;
    v_mov.producto_id    := p_producto;
    v_mov.fecha          := v_fecha;
    v_mov.tipo           := p_tipo;
    v_mov.cantidad       := v_cantidad;
    v_mov.costo_unitario := round(v_costo, 6);
    v_mov.valor          := round(v_cantidad * v_costo, 6);
    v_mov.saldo_cantidad := 0;
    v_mov.saldo_valor    := 0;
    v_mov.origen_tabla   := p_origen_tabla;
    v_mov.origen_id      := p_origen_id;
    return v_mov;
  end if;

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
-- 2. Guardar producto: controla_stock y costo_servicio
-- -----------------------------------------------------------------------------
-- Claves nuevas de p_datos: controla_stock (solo se apaga con stock en cero) y
-- costo_servicio (costo por unidad de un producto sin stock; vacío lo borra).
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
  if (p_datos ->> 'costo_servicio')::numeric < 0 then
    return privado.error('DATOS_INVALIDOS', 'El costo no puede ser negativo');
  end if;

  if p_id is null then
    insert into public.productos (empresa_id, nombre, categoria_id, unidad_base, tarifa_iva, codigo_iva,
                                  stock_minimo, codigo_principal, codigo_auxiliar, informacion_adicional,
                                  controla_stock, creado_por)
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
            coalesce((p_datos ->> 'controla_stock')::boolean, true),
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

    insert into public.existencias (empresa_id, producto_id, ultimo_costo)
    values (v_empresa, v_producto.id,
            case when not v_producto.controla_stock then round((p_datos ->> 'costo_servicio')::numeric, 6) end);

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
    if v_anterior.controla_stock and (p_datos ->> 'controla_stock')::boolean is false
       and exists (select 1 from public.existencias x where x.producto_id = p_id and x.cantidad <> 0) then
      return privado.error('DATOS_INVALIDOS',
        'Para dejar de controlar el stock, primero llévalo a cero con un ajuste');
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
      controla_stock = case when p_datos ? 'controla_stock'
                            then (p_datos ->> 'controla_stock')::boolean                              else p.controla_stock end,
      codigo_principal = case when p_datos ? 'codigo_principal'
                              then nullif(trim(p_datos ->> 'codigo_principal'), '')                   else p.codigo_principal end,
      codigo_auxiliar  = case when p_datos ? 'codigo_auxiliar'
                              then nullif(trim(p_datos ->> 'codigo_auxiliar'), '')                    else p.codigo_auxiliar end,
      informacion_adicional = case when p_datos ? 'informacion_adicional'
                              then nullif(trim(p_datos ->> 'informacion_adicional'), '')              else p.informacion_adicional end
     where p.id = p_id
    returning * into v_producto;

    if not v_producto.controla_stock and p_datos ? 'costo_servicio' then
      update public.existencias x
         set ultimo_costo = round((p_datos ->> 'costo_servicio')::numeric, 6), actualizado_en = now()
       where x.producto_id = p_id;
    end if;

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
-- 3. Inventario valorizado: dice qué productos no controlan stock y su costo
-- -----------------------------------------------------------------------------
create or replace function public.inventario_valorizado()
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
               'controla_stock', p.controla_stock,
               'cantidad',       x.cantidad::text,
               'costo_promedio', x.costo_promedio::text,
               'ultimo_costo',   x.ultimo_costo::text,
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
