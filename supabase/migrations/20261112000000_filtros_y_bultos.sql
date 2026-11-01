-- =============================================================================
-- Productos por proveedor y bultos por peso (D-057)
--
-- Un producto no tiene un proveedor fijo: se deduce de sus compras confirmadas.
-- Al importar una factura, el bulto puede nombrarse por su contenido
-- («Saco 10 kg», «Paquete 5 lb») en vez de «Caja N».
-- =============================================================================

create function public.proveedores_de_productos()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  return privado.ok(coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'nombre', x.nombre, 'productos', x.productos) order by x.nombre)
      from (select v.id, v.nombre, jsonb_agg(distinct d.producto_id) as productos
              from public.proveedores v
              join public.compras c on c.proveedor_id = v.id and c.estado = 'CONFIRMADA'
              join public.compra_detalles d on d.compra_id = c.id
             where v.empresa_id = v_empresa
             group by v.id, v.nombre) x), '[]'::jsonb));
end;
$$;

revoke all on function public.proveedores_de_productos() from public, anon;
grant execute on function public.proveedores_de_productos() to authenticated;

-- Clave nueva en cada línea de p_lineas: presentacion (nombre del bulto).
create or replace function public.registrar_compra_de_factura(p_xml text, p_lineas jsonb, p_clave_idempotencia uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa    public.empresas;
  v_datos      jsonb;
  v_hoy        date;
  v_proveedor  uuid;
  v_compra     public.compras;
  v_existente  public.compras;
  v_id         uuid := gen_random_uuid();
  v_r          jsonb;
  x            jsonb;   -- línea del XML
  e            jsonb;   -- lo que dijo quien revisó
  v_producto   uuid;
  v_pres       uuid;
  v_factor     numeric;
  v_recibida   numeric;
  v_parte      numeric;
  v_barras     text;
  v_subtotal   numeric;
  v_descuento  numeric;
  v_iva        numeric;
  v_otros      numeric;
  v_base_unit  numeric;
  v_orden      int := 0;
  v_creados    int := 0;
  v_filas      jsonb := '[]';
  v_detalle    text;
begin
  select * into v_empresa from public.empresas em where em.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la clave de idempotencia');
  end if;
  select * into v_existente from public.compras c
   where c.empresa_id = v_empresa.id and c.clave_idempotencia = p_clave_idempotencia;
  if found then
    return privado.ok(jsonb_build_object('compra_id', v_existente.id, 'repetido', true,
                                         'total', v_existente.total::text, 'productos_nuevos', 0));
  end if;
  if jsonb_typeof(p_lineas) is distinct from 'array' then
    return privado.error('DATOS_INVALIDOS');
  end if;

  v_datos := privado.leer_xml_proveedor(v_empresa, p_xml);
  v_hoy := (now() at time zone v_empresa.zona_horaria)::date;
  if (v_datos ->> 'fecha')::date > v_hoy then
    return privado.error('DATOS_INVALIDOS', 'La fecha no puede ser futura');
  end if;

  -- Proveedor: se reconoce por el RUC o se crea.
  select v.id into v_proveedor from public.proveedores v
   where v.empresa_id = v_empresa.id and v.identificacion = v_datos ->> 'ruc';
  if v_proveedor is null then
    v_r := public.guardar_proveedor(null, jsonb_build_object(
      'tipo_identificacion', 'RUC', 'identificacion', v_datos ->> 'ruc', 'nombre', v_datos ->> 'razon_social'));
    if (v_r ->> 'ok') is distinct from 'true' then
      perform privado.fallar('DATOS_INVALIDOS', 'No se pudo crear el proveedor');
    end if;
    v_proveedor := (v_r -> 'data' ->> 'id')::uuid;
  end if;

  for x in select l from jsonb_array_elements(v_datos -> 'lineas') l order by (l ->> 'orden')::int loop
    select l into e from jsonb_array_elements(p_lineas) l where (l ->> 'orden')::int = (x ->> 'orden')::int limit 1;
    if e is null then
      perform privado.fallar('DATOS_INVALIDOS', (x ->> 'descripcion') || ': falta revisar esta línea');
    end if;

    begin
      v_recibida := round((e ->> 'cantidad_recibida')::numeric, 3);
      v_factor   := coalesce((e ->> 'factor')::numeric, 1);
    exception when invalid_text_representation or numeric_value_out_of_range then
      perform privado.fallar('DATOS_INVALIDOS', (x ->> 'descripcion') || ': número mal escrito');
    end;
    if v_recibida is null or v_recibida < 0 or v_factor <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', (x ->> 'descripcion') || ': revisa la cantidad');
    end if;
    continue when v_recibida = 0;

    -- Producto: uno que ya existe o uno nuevo.
    v_producto := null;
    if e ? 'nuevo' then
      -- La misma factura puede repetir un producto: no se crea dos veces.
      select r.producto_id into v_producto
        from public.codigos_proveedor c
        join public.presentaciones r on r.id = c.presentacion_id
       where c.empresa_id = v_empresa.id and c.proveedor_id = v_proveedor and c.codigo = x ->> 'codigo';
      if v_producto is null then
        select p.id into v_producto from public.productos p
         where p.empresa_id = v_empresa.id and p.activo
           and lower(p.nombre) = lower(trim(coalesce(e -> 'nuevo' ->> 'nombre', x ->> 'descripcion')))
         limit 1;
      end if;
    end if;

    if v_producto is not null then
      null;
    elsif e ? 'nuevo' then
      v_r := public.guardar_producto(null, jsonb_build_object(
        'nombre',         left(trim(coalesce(e -> 'nuevo' ->> 'nombre', x ->> 'descripcion')), 200),
        'unidad_base',    coalesce(e -> 'nuevo' ->> 'unidad_base', 'UND'),
        'codigo_iva',     coalesce(x ->> 'codigo_iva', '0'),
        'precio_venta',   nullif(e -> 'nuevo' ->> 'precio_venta', ''),
        'controla_stock', coalesce((e -> 'nuevo' ->> 'controla_stock')::boolean, true)));
      if (v_r ->> 'ok') is distinct from 'true' then
        perform privado.fallar('DATOS_INVALIDOS',
          (x ->> 'descripcion') || ': ' || coalesce(v_r -> 'error' ->> 'mensaje', 'no se pudo crear el producto'));
      end if;
      v_producto := (v_r -> 'data' ->> 'id')::uuid;
      v_creados := v_creados + 1;
    else
      select p.id into v_producto from public.productos p
       where p.id = (e ->> 'producto_id')::uuid and p.empresa_id = v_empresa.id;
      if v_producto is null then
        perform privado.fallar('DATOS_INVALIDOS', (x ->> 'descripcion') || ': elige el producto');
      end if;
    end if;

    -- Presentación con ese contenido: la que haya o una nueva «Caja N».
    select r.id into v_pres from public.presentaciones r
     where r.producto_id = v_producto and r.factor = v_factor and r.activo
     order by r.creado_en limit 1;
    if v_pres is null then
      v_r := public.guardar_presentacion(null, jsonb_build_object(
        'producto_id', v_producto, 'factor', v_factor, 'se_vende', false,
        'nombre', coalesce(nullif(trim(e ->> 'presentacion'), ''),
                           'Caja ' || trim(trailing '.' from trim(trailing '0' from v_factor::text)))));
      if (v_r ->> 'ok') is distinct from 'true' then
        perform privado.fallar('DATOS_INVALIDOS',
          (x ->> 'descripcion') || ': ' || coalesce(v_r -> 'error' ->> 'mensaje', 'no se pudo crear la presentación'));
      end if;
      v_pres := (v_r -> 'data' ->> 'id')::uuid;
    end if;

    -- El código de barras del proveedor, si está libre, queda en esta presentación.
    v_barras := case when x ->> 'codigo_auxiliar' ~ '^[0-9]{8,14}$' then x ->> 'codigo_auxiliar'
                     when x ->> 'codigo' ~ '^[0-9]{8,14}$' then x ->> 'codigo' end;
    if v_barras is not null
       and not exists (select 1 from public.presentaciones r
                        where r.empresa_id = v_empresa.id and r.codigo_barras = v_barras) then
      update public.presentaciones r set codigo_barras = v_barras
       where r.id = v_pres and r.codigo_barras is null;
    end if;

    if x ->> 'codigo' is not null then
      insert into public.codigos_proveedor (empresa_id, proveedor_id, codigo, presentacion_id)
      values (v_empresa.id, v_proveedor, x ->> 'codigo', v_pres)
      on conflict (empresa_id, proveedor_id, codigo)
      do update set presentacion_id = excluded.presentacion_id, actualizado_en = now();
    end if;

    -- Montos del XML, en proporción a lo que llegó.
    v_parte     := v_recibida / (x ->> 'cantidad')::numeric;
    v_subtotal  := round(((x ->> 'base')::numeric + (x ->> 'descuento')::numeric) * v_parte, 2);
    v_descuento := round((x ->> 'descuento')::numeric * v_parte, 2);
    v_iva       := round((x ->> 'iva')::numeric * v_parte, 2);
    v_otros     := round((x ->> 'otros_impuestos')::numeric * v_parte, 2);
    v_orden     := v_orden + 1;
    v_base_unit := (v_subtotal - v_descuento + v_otros
                    + case when v_empresa.iva_compras_es_costo then v_iva else 0 end) / (v_recibida * v_factor);

    v_filas := v_filas || jsonb_build_array(jsonb_build_object(
      'orden', v_orden, 'presentacion_id', v_pres, 'producto_id', v_producto, 'cantidad', v_recibida,
      'costo_unitario', round(v_subtotal / v_recibida, 6), 'descuento', v_descuento,
      'tarifa_iva', (x ->> 'tarifa_iva')::numeric, 'subtotal', v_subtotal, 'iva', v_iva, 'otros', v_otros,
      'cantidad_base', round(v_recibida * v_factor, 3), 'costo_base', round(v_base_unit, 6),
      'descripcion', x ->> 'descripcion'));
  end loop;

  if v_orden = 0 then
    perform privado.fallar('DATOS_INVALIDOS', 'No llegó nada: la compra necesita al menos una línea');
  end if;

  -- Una compra confirmada no se edita: la cabecera entra ya con sus totales.
  insert into public.compras (id, empresa_id, proveedor_id, fecha, numero_documento, con_respaldo,
                              subtotal, descuento, iva, otros_impuestos, total, iva_es_costo, clave_idempotencia,
                              clave_acceso, total_factura, xml, creado_por)
  select v_id, v_empresa.id, v_proveedor, (v_datos ->> 'fecha')::date,
         privado.normalizar_documento(v_datos ->> 'numero'), true,
         f.subtotal, f.descuento, f.iva, f.otros, f.subtotal - f.descuento + f.iva + f.otros,
         v_empresa.iva_compras_es_costo, p_clave_idempotencia,
         v_datos ->> 'clave_acceso', (v_datos ->> 'total')::numeric, p_xml, auth.uid()
    from (select sum((l ->> 'subtotal')::numeric) as subtotal, sum((l ->> 'descuento')::numeric) as descuento,
                 sum((l ->> 'iva')::numeric) as iva, sum((l ->> 'otros')::numeric) as otros
            from jsonb_array_elements(v_filas) l) f
  returning * into v_compra;

  insert into public.compra_detalles (empresa_id, compra_id, orden, presentacion_id, producto_id, cantidad,
                                      costo_unitario, descuento, tarifa_iva, subtotal, iva, otros_impuestos,
                                      cantidad_base, costo_unitario_base, descripcion_factura)
  select v_empresa.id, v_id, (l ->> 'orden')::int, (l ->> 'presentacion_id')::uuid, (l ->> 'producto_id')::uuid,
         (l ->> 'cantidad')::numeric, (l ->> 'costo_unitario')::numeric, (l ->> 'descuento')::numeric,
         (l ->> 'tarifa_iva')::numeric, (l ->> 'subtotal')::numeric, (l ->> 'iva')::numeric,
         (l ->> 'otros')::numeric, (l ->> 'cantidad_base')::numeric, (l ->> 'costo_base')::numeric, l ->> 'descripcion'
    from jsonb_array_elements(v_filas) l;

  -- Entradas al inventario en orden de producto (evita bloqueos cruzados).
  for v_producto, v_recibida, v_base_unit in
    select d.producto_id, d.cantidad_base, d.costo_unitario_base
      from public.compra_detalles d where d.compra_id = v_id order by d.producto_id, d.orden
  loop
    perform privado.registrar_movimiento(
      v_empresa.id, v_producto, 'COMPRA', v_recibida, v_base_unit,
      'compras', v_id, null, null, v_compra.fecha);
  end loop;

  return privado.ok(jsonb_build_object('compra_id', v_id, 'repetido', false, 'total', v_compra.total::text,
                                       'total_factura', v_datos ->> 'total', 'productos_nuevos', v_creados));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
  when unique_violation then
    return privado.error('DUPLICADO', 'Esta factura ya está registrada como compra');
end;
$$;
