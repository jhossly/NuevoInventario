-- =============================================================================
-- Compras por bultos, igual para productos que existen y que no (D-068)
--
-- Una línea puede venir de tres formas:
--   {"presentacion_id", ...}             como hasta ahora
--   {"producto_id", "factor", ...}       un producto que existe, por bultos de
--                                        «factor» unidades
--   {"nuevo": {"nombre", "factor", "precio_venta"?}, ...}   aún no existe (D-066)
-- y siempre "cantidad" (bultos), "costo_unitario" (por bulto, sin IVA),
-- "descuento"? y "tarifa_iva"?.
--
-- simular_compra calcula todas en su orden, con las mismas cuentas que
-- calcular_lineas_compra, y devuelve por línea lo que entra, lo que cuesta y lo
-- que se vendería. registrar_compra_con_nuevos busca para producto_id la
-- presentación de compra con ese contenido o crea «Caja N» (sin venta), como al
-- importar un XML.
-- =============================================================================

create or replace function public.simular_compra(p_lineas jsonb, p_margen numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa    public.empresas;
  v_iva_cero   boolean;
  v_lineas     jsonb := '[]';
  v_extras     jsonb := '[]';
  v_compra     jsonb := '[]';
  x            record;
  v_pid        uuid;
  v_pnombre    text;
  v_ptarifa    numeric;
  v_venta      record;
  v_ultima     record;
  v_nuevo      boolean;
  v_nombre     text;
  v_factor     numeric;
  v_cantidad   numeric;
  v_costo      numeric;
  v_descuento  numeric;
  v_tarifa     numeric;
  v_tarifa_vta numeric;
  v_pvp        numeric;
  v_subtotal   numeric;
  v_iva        numeric;
  v_base_cant  numeric;
  v_costo_base numeric;
  v_venta_tot  numeric;
  v_sugerido   numeric;
  v_detalle    text;
begin
  select * into v_empresa from public.empresas em where em.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_margen is null or p_margen < 0 or p_margen >= 0.9 then
    return privado.error('DATOS_INVALIDOS', 'El margen debe estar entre 0 % y 89 %');
  end if;
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    return privado.error('DATOS_INVALIDOS', 'Agrega al menos un producto');
  end if;
  v_iva_cero := privado.iva_cero_en(v_empresa.id, (now() at time zone v_empresa.zona_horaria)::date);

  for x in select e, o::int as o from jsonb_array_elements(p_lineas) with ordinality t(e, o) order by o loop
    v_nuevo := x.e ? 'nuevo';
    v_pid := null; v_pnombre := null; v_ptarifa := null; v_pvp := null;
    begin
      v_cantidad  := round((x.e ->> 'cantidad')::numeric, 3);
      v_costo     := round((x.e ->> 'costo_unitario')::numeric, 6);
      v_descuento := round(coalesce(nullif(x.e ->> 'descuento', '')::numeric, 0), 2);
      v_tarifa    := (x.e ->> 'tarifa_iva')::numeric;
      if v_nuevo then
        v_nombre := nullif(trim(x.e -> 'nuevo' ->> 'nombre'), '');
        v_factor := round(coalesce(nullif(x.e -> 'nuevo' ->> 'factor', ''), '1')::numeric, 3);
        v_pvp    := round(nullif(x.e -> 'nuevo' ->> 'precio_venta', '')::numeric, 4);
      elsif x.e ? 'presentacion_id' then
        select p.id, p.nombre, p.tarifa_iva, r.factor into v_pid, v_pnombre, v_ptarifa, v_factor
          from public.presentaciones r join public.productos p on p.id = r.producto_id
         where r.id = (x.e ->> 'presentacion_id')::uuid and r.empresa_id = v_empresa.id and r.activo and p.activo;
      else
        select p.id, p.nombre, p.tarifa_iva into v_pid, v_pnombre, v_ptarifa
          from public.productos p
         where p.id = (x.e ->> 'producto_id')::uuid and p.empresa_id = v_empresa.id and p.activo;
        v_factor := round(coalesce(nullif(x.e ->> 'factor', ''), '1')::numeric, 3);
      end if;
    exception
      when invalid_text_representation or numeric_value_out_of_range then
        perform privado.fallar('DATOS_INVALIDOS', 'Hay un número mal escrito', jsonb_build_object('linea', x.o));
    end;

    if v_nuevo and v_nombre is null then
      perform privado.fallar('DATOS_INVALIDOS', 'Falta el nombre del producto nuevo', jsonb_build_object('linea', x.o));
    end if;
    if not v_nuevo and v_pid is null then
      perform privado.fallar('DATOS_INVALIDOS', 'El producto no existe', jsonb_build_object('linea', x.o));
    end if;
    v_tarifa := coalesce(v_tarifa, case when v_nuevo then 0 else v_ptarifa end);
    if v_factor is null or v_factor <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'Las unidades por bulto deben ser más que cero',
                             jsonb_build_object('linea', x.o));
    end if;
    if v_cantidad is null or v_cantidad <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad debe ser mayor que cero', jsonb_build_object('linea', x.o));
    end if;
    if v_costo is null or v_costo < 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'Falta el costo o es negativo', jsonb_build_object('linea', x.o));
    end if;
    if v_pvp is not null and v_pvp < 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'El precio de venta no puede ser negativo', jsonb_build_object('linea', x.o));
    end if;
    if privado.codigo_tarifa_iva(v_tarifa) is null then
      perform privado.fallar('DATOS_INVALIDOS', 'Esa tarifa de IVA no existe', jsonb_build_object('linea', x.o));
    end if;

    -- Las cuentas de calcular_lineas_compra.
    v_subtotal := round(v_cantidad * v_costo, 2);
    if v_descuento < 0 or v_descuento > v_subtotal then
      perform privado.fallar('DATOS_INVALIDOS', 'El descuento no puede superar el subtotal', jsonb_build_object('linea', x.o));
    end if;
    v_iva       := round((v_subtotal - v_descuento) * v_tarifa / 100, 2);
    v_base_cant := round(v_cantidad * v_factor, 3);
    if v_base_cant <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad es demasiado pequeña', jsonb_build_object('linea', x.o));
    end if;
    v_costo_base := (v_subtotal - v_descuento + case when v_empresa.iva_compras_es_costo then v_iva else 0 end) / v_base_cant;

    -- Lo que se vendería y el precio para el margen pedido.
    if v_nuevo then
      v_tarifa_vta := v_tarifa;
      v_venta_tot  := privado.venta_neta_unidad(v_empresa, v_pvp, v_tarifa_vta) * v_base_cant;
      select 'Unidad'::text as nombre, 1::numeric as factor, v_pvp as precio_venta into v_venta;
      select null::numeric as costo_unitario_base, null::date as fecha, null::text as proveedor into v_ultima;
    else
      v_tarifa_vta := v_ptarifa;
      v_nombre     := v_pnombre;
      v_venta_tot  := privado.venta_neta_unidad(v_empresa, privado.precio_unidad_producto(v_pid), v_tarifa_vta)
                      * v_base_cant;
      select r.nombre, r.factor, r.precio_venta into v_venta
        from public.presentaciones r
       where r.producto_id = v_pid and r.activo and r.se_vende
       order by r.factor, r.creado_en
       limit 1;
      select d.costo_unitario_base, c.fecha, pr.nombre as proveedor into v_ultima
        from public.compra_detalles d
        join public.compras c on c.id = d.compra_id
        left join public.proveedores pr on pr.id = c.proveedor_id
       where d.producto_id = v_pid and c.empresa_id = v_empresa.id and c.estado = 'CONFIRMADA'
       order by c.fecha desc, c.creado_en desc, d.orden
       limit 1;
    end if;
    v_sugerido := case when v_venta.factor is not null then
      ceil(v_costo_base * v_venta.factor / (1 - p_margen)
           * case when v_empresa.precios_incluyen_iva and not v_iva_cero
                  then 1 + v_tarifa_vta / 100 else 1 end * 100) / 100 end;

    v_lineas := v_lineas || jsonb_build_array(jsonb_build_object(
      'orden', x.o, 'nombre', v_nombre, 'cantidad', v_base_cant,
      'costo', v_base_cant * v_costo_base, 'venta', v_venta_tot));
    v_compra := v_compra || jsonb_build_array(jsonb_build_object(
      'subtotal', v_subtotal, 'descuento', v_descuento, 'iva', v_iva));
    v_extras := v_extras || jsonb_build_array(jsonb_build_object(
      'orden',               x.o,
      'nuevo',               v_nuevo,
      'unidades',            v_base_cant::text,
      'subtotal',            v_subtotal::numeric(12,2)::text,
      'iva',                 v_iva::numeric(12,2)::text,
      'costo_total',         round(v_base_cant * v_costo_base, 2)::text,
      'venta_total',         round(v_venta_tot, 2)::text,
      'precio_unidad',       round(case when v_nuevo then v_pvp else privado.precio_unidad_producto(v_pid) end, 4)::text,
      'costo_unidad',        round(v_costo_base, 4)::text,
      'costo_anterior',      round(v_ultima.costo_unitario_base, 4)::text,
      'fecha_anterior',      v_ultima.fecha,
      'proveedor_anterior',  v_ultima.proveedor,
      'presentacion_venta',  v_venta.nombre,
      'precio_actual',       v_venta.precio_venta::text,
      'precio_sugerido',     round(v_sugerido, 2)::text));
  end loop;

  return privado.ok(privado.resumen_utilidad(v_lineas) || jsonb_build_object(
    'compra', (select jsonb_build_object(
                 'subtotal',  coalesce(sum((c ->> 'subtotal')::numeric), 0)::numeric(12,2)::text,
                 'descuento', coalesce(sum((c ->> 'descuento')::numeric), 0)::numeric(12,2)::text,
                 'iva',       coalesce(sum((c ->> 'iva')::numeric), 0)::numeric(12,2)::text,
                 'total',     coalesce(sum((c ->> 'subtotal')::numeric - (c ->> 'descuento')::numeric
                                           + (c ->> 'iva')::numeric), 0)::numeric(12,2)::text)
                 from jsonb_array_elements(v_compra) c),
    'detalle', v_extras));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
end;
$$;

create or replace function public.registrar_compra_con_nuevos(
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
  v_empresa   uuid := privado.mi_empresa();
  v_compra    public.compras;
  v_lineas    jsonb := '[]';
  x           record;
  v_nombre    text;
  v_factor    numeric;
  v_tarifa    numeric;
  v_precio    text;
  v_producto  uuid;
  v_pres      uuid;
  v_r         jsonb;
  v_creados   int := 0;
  v_detalle   text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la clave de idempotencia');
  end if;
  -- Un reintento no vuelve a crear productos.
  select * into v_compra from public.compras c
   where c.empresa_id = v_empresa and c.clave_idempotencia = p_clave_idempotencia;
  if found then
    return privado.ok(jsonb_build_object('compra_id', v_compra.id, 'repetido', true,
                                         'total', v_compra.total::text, 'creados', 0));
  end if;
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    return privado.error('DATOS_INVALIDOS', 'La compra necesita al menos una línea');
  end if;

  begin
    for x in select e, o::int as o from jsonb_array_elements(p_lineas) with ordinality t(e, o) order by o loop
      if x.e ? 'presentacion_id' then
        v_lineas := v_lineas || jsonb_build_array(x.e);
        continue;
      end if;

      v_producto := null;
      v_tarifa := null;
      begin
        if x.e ? 'nuevo' then
          v_nombre := left(nullif(trim(x.e -> 'nuevo' ->> 'nombre'), ''), 200);
          v_factor := round(coalesce(nullif(x.e -> 'nuevo' ->> 'factor', ''), '1')::numeric, 3);
          v_precio := nullif(trim(x.e -> 'nuevo' ->> 'precio_venta'), '');
        else
          select p.id, p.nombre into v_producto, v_nombre from public.productos p
           where p.id = (x.e ->> 'producto_id')::uuid and p.empresa_id = v_empresa and p.activo;
          v_factor := round(coalesce(nullif(x.e ->> 'factor', ''), '1')::numeric, 3);
        end if;
        v_tarifa := (x.e ->> 'tarifa_iva')::numeric;
      exception
        when invalid_text_representation or numeric_value_out_of_range then
          perform privado.fallar('DATOS_INVALIDOS', 'Hay un número mal escrito', jsonb_build_object('linea', x.o));
      end;
      if v_factor is null or v_factor <= 0 then
        perform privado.fallar('DATOS_INVALIDOS', 'Las unidades por bulto deben ser más que cero',
                               jsonb_build_object('linea', x.o));
      end if;

      if x.e ? 'nuevo' then
        v_tarifa := coalesce(v_tarifa, 0);
        if v_nombre is null then
          perform privado.fallar('DATOS_INVALIDOS', 'Falta el nombre del producto nuevo', jsonb_build_object('linea', x.o));
        end if;
        if privado.codigo_tarifa_iva(v_tarifa) is null then
          perform privado.fallar('DATOS_INVALIDOS', 'Esa tarifa de IVA no existe', jsonb_build_object('linea', x.o));
        end if;
        -- Si ya existe con ese nombre (o la misma compra lo repite), se usa ese.
        select p.id into v_producto from public.productos p
         where p.empresa_id = v_empresa and p.activo and lower(p.nombre) = lower(v_nombre)
         order by p.creado_en limit 1;
        if v_producto is null then
          v_r := public.guardar_producto(null, jsonb_build_object(
            'nombre',       v_nombre,
            'unidad_base',  'UND',
            'codigo_iva',   privado.codigo_tarifa_iva(v_tarifa),
            'precio_venta', v_precio));
          if (v_r ->> 'ok') is distinct from 'true' then
            perform privado.fallar('DATOS_INVALIDOS',
              v_nombre || ': ' || coalesce(v_r -> 'error' ->> 'mensaje', 'no se pudo crear el producto'),
              jsonb_build_object('linea', x.o));
          end if;
          v_producto := (v_r -> 'data' ->> 'id')::uuid;
          update public.productos p set por_completar = true where p.id = v_producto;
          v_creados := v_creados + 1;
        end if;
      elsif v_producto is null then
        perform privado.fallar('DATOS_INVALIDOS', 'El producto no existe', jsonb_build_object('linea', x.o));
      end if;

      -- Presentación de compra con ese contenido: la que haya o una nueva «Caja N».
      select r.id into v_pres from public.presentaciones r
       where r.producto_id = v_producto and r.factor = v_factor and r.activo and r.se_compra
       order by r.creado_en limit 1;
      if v_pres is null then
        v_r := public.guardar_presentacion(null, jsonb_build_object(
          'producto_id', v_producto, 'factor', v_factor, 'se_vende', false,
          'nombre', 'Caja ' || trim(trailing '.' from trim(trailing '0' from v_factor::text))));
        if (v_r ->> 'ok') is distinct from 'true' then
          perform privado.fallar('DATOS_INVALIDOS',
            v_nombre || ': ' || coalesce(v_r -> 'error' ->> 'mensaje', 'no se pudo crear la presentación'),
            jsonb_build_object('linea', x.o));
        end if;
        v_pres := (v_r -> 'data' ->> 'id')::uuid;
      end if;

      v_lineas := v_lineas || jsonb_build_array(
        (x.e - 'nuevo' - 'producto_id' - 'factor') || jsonb_build_object('presentacion_id', v_pres)
        || case when v_tarifa is null then '{}'::jsonb else jsonb_build_object('tarifa_iva', v_tarifa) end);
    end loop;

    v_r := public.registrar_compra(p_proveedor_id, p_con_respaldo, p_numero_documento, p_fecha,
                                   v_lineas, p_clave_idempotencia);
    -- Si la compra no entra, se deshacen los productos y presentaciones creados.
    if (v_r ->> 'ok') is distinct from 'true' then
      raise exception using errcode = 'NG002', detail = v_r::text;
    end if;
  exception
    when sqlstate 'NG001' then
      get stacked diagnostics v_detalle = pg_exception_detail;
      return v_detalle::jsonb;
    when sqlstate 'NG002' then
      get stacked diagnostics v_detalle = pg_exception_detail;
      return v_detalle::jsonb;
  end;

  return privado.ok((v_r -> 'data') || jsonb_build_object('creados', v_creados));
end;
$$;
