-- =============================================================================
-- «¿Cuánto gano?» con productos que todavía no existen (D-066)
--
-- Una línea de p_lineas con "nuevo" no apunta a una presentación: describe un
-- producto que se piensa comprar por primera vez y no se crea nada.
--   {"nuevo": {"nombre", "factor" (unidades por bulto), "precio_venta"? (por
--    unidad, como se pondría en la percha)}, "cantidad", "costo_unitario"
--    (por bulto, sin IVA), "descuento"?, "tarifa_iva"?}
-- Las cuentas son las de calcular_lineas_compra. Para vender se usa la misma
-- tarifa de la compra, como al crear un producto desde la factura (D-058). Sin
-- precio, la línea se avisa y no suma; el precio sugerido sí sale.
-- Las respuestas van primero con las líneas de productos existentes y luego
-- las nuevas, cada grupo en su orden.
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
  v_existentes jsonb;
  v_nuevas     jsonb;
  v_n          int;
  v_lineas     jsonb := '[]';
  v_extras     jsonb := '[]';
  v_compra     jsonb := '[]';
  l            record;
  x            record;
  v_prod       record;
  v_venta      record;
  v_ultima     record;
  v_precio     numeric;
  v_nombre     text;
  v_factor     numeric;
  v_cantidad   numeric;
  v_costo      numeric;
  v_descuento  numeric;
  v_tarifa     numeric;
  v_pvp        numeric;
  v_subtotal   numeric;
  v_iva        numeric;
  v_base_cant  numeric;
  v_costo_base numeric;
  v_orden      int;
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

  select coalesce(jsonb_agg(e order by o) filter (where not e ? 'nuevo'), '[]'),
         coalesce(jsonb_agg(e order by o) filter (where e ? 'nuevo'), '[]')
    into v_existentes, v_nuevas
    from jsonb_array_elements(p_lineas) with ordinality t(e, o);
  v_n := jsonb_array_length(v_existentes);

  -- Productos que ya existen: las cuentas de una compra a mano.
  if v_n > 0 then
    for l in select * from privado.calcular_lineas_compra(v_empresa.id, v_existentes) order by orden loop
      select p.id, p.nombre, p.tarifa_iva into v_prod from public.productos p where p.id = l.producto_id;

      v_lineas := v_lineas || jsonb_build_array(jsonb_build_object(
        'orden',    l.orden,
        'nombre',   v_prod.nombre,
        'cantidad', l.cantidad_base,
        'costo',    l.cantidad_base * l.costo_unitario_base,
        'venta',    privado.venta_neta_unidad(v_empresa, privado.precio_unidad_producto(v_prod.id), v_prod.tarifa_iva)
                    * l.cantidad_base));
      v_compra := v_compra || jsonb_build_array(jsonb_build_object(
        'subtotal', l.subtotal, 'descuento', l.descuento, 'iva', l.iva));

      select r.nombre, r.factor, r.precio_venta into v_venta
        from public.presentaciones r
       where r.producto_id = v_prod.id and r.activo and r.se_vende
       order by r.factor, r.creado_en
       limit 1;

      select d.costo_unitario_base, c.fecha, pr.nombre as proveedor into v_ultima
        from public.compra_detalles d
        join public.compras c on c.id = d.compra_id
        left join public.proveedores pr on pr.id = c.proveedor_id
       where d.producto_id = v_prod.id and c.empresa_id = v_empresa.id and c.estado = 'CONFIRMADA'
       order by c.fecha desc, c.creado_en desc, d.orden
       limit 1;

      v_precio := case when v_venta.factor is not null then
        ceil(l.costo_unitario_base * v_venta.factor / (1 - p_margen)
             * case when v_empresa.precios_incluyen_iva and not v_iva_cero
                    then 1 + v_prod.tarifa_iva / 100 else 1 end * 100) / 100 end;

      v_extras := v_extras || jsonb_build_array(jsonb_build_object(
        'orden',               l.orden,
        'costo_unidad',        round(l.costo_unitario_base, 4)::text,
        'costo_anterior',      round(v_ultima.costo_unitario_base, 4)::text,
        'fecha_anterior',      v_ultima.fecha,
        'proveedor_anterior',  v_ultima.proveedor,
        'presentacion_venta',  v_venta.nombre,
        'precio_actual',       v_venta.precio_venta::text,
        'precio_sugerido',     round(v_precio, 2)::text));
    end loop;
  end if;

  -- Productos que todavía no existen: mismas cuentas, sin tocar el catálogo.
  for x in select e, o::int as o from jsonb_array_elements(v_nuevas) with ordinality t(e, o) loop
    v_orden := v_n + x.o;
    begin
      v_nombre    := nullif(trim(x.e -> 'nuevo' ->> 'nombre'), '');
      v_factor    := round(coalesce(nullif(x.e -> 'nuevo' ->> 'factor', ''), '1')::numeric, 3);
      v_pvp       := round(nullif(x.e -> 'nuevo' ->> 'precio_venta', '')::numeric, 4);
      v_cantidad  := round((x.e ->> 'cantidad')::numeric, 3);
      v_costo     := round((x.e ->> 'costo_unitario')::numeric, 6);
      v_descuento := round(coalesce(nullif(x.e ->> 'descuento', '')::numeric, 0), 2);
      v_tarifa    := coalesce((x.e ->> 'tarifa_iva')::numeric, 0);
    exception
      when invalid_text_representation or numeric_value_out_of_range then
        perform privado.fallar('DATOS_INVALIDOS', 'Hay un número mal escrito', jsonb_build_object('linea', v_orden));
    end;

    if v_nombre is null then
      perform privado.fallar('DATOS_INVALIDOS', 'Falta el nombre del producto nuevo', jsonb_build_object('linea', v_orden));
    end if;
    if v_factor is null or v_factor <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'Las unidades por bulto deben ser más que cero',
                             jsonb_build_object('linea', v_orden));
    end if;
    if v_cantidad is null or v_cantidad <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad debe ser mayor que cero', jsonb_build_object('linea', v_orden));
    end if;
    if v_costo is null or v_costo < 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'Falta el costo o es negativo', jsonb_build_object('linea', v_orden));
    end if;
    if v_pvp is not null and v_pvp < 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'El precio de venta no puede ser negativo', jsonb_build_object('linea', v_orden));
    end if;
    if privado.codigo_tarifa_iva(v_tarifa) is null then
      perform privado.fallar('DATOS_INVALIDOS', 'Esa tarifa de IVA no existe', jsonb_build_object('linea', v_orden));
    end if;

    v_subtotal := round(v_cantidad * v_costo, 2);
    if v_descuento < 0 or v_descuento > v_subtotal then
      perform privado.fallar('DATOS_INVALIDOS', 'El descuento no puede superar el subtotal', jsonb_build_object('linea', v_orden));
    end if;
    v_iva       := round((v_subtotal - v_descuento) * v_tarifa / 100, 2);
    v_base_cant := round(v_cantidad * v_factor, 3);
    if v_base_cant <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad es demasiado pequeña', jsonb_build_object('linea', v_orden));
    end if;
    v_costo_base := (v_subtotal - v_descuento + case when v_empresa.iva_compras_es_costo then v_iva else 0 end) / v_base_cant;

    v_lineas := v_lineas || jsonb_build_array(jsonb_build_object(
      'orden',    v_orden,
      'nombre',   v_nombre,
      'cantidad', v_base_cant,
      'costo',    v_base_cant * v_costo_base,
      'venta',    privado.venta_neta_unidad(v_empresa, v_pvp, v_tarifa) * v_base_cant));
    v_compra := v_compra || jsonb_build_array(jsonb_build_object(
      'subtotal', v_subtotal, 'descuento', v_descuento, 'iva', v_iva));

    v_extras := v_extras || jsonb_build_array(jsonb_build_object(
      'orden',               v_orden,
      'costo_unidad',        round(v_costo_base, 4)::text,
      'costo_anterior',      null,
      'fecha_anterior',      null,
      'proveedor_anterior',  null,
      'presentacion_venta',  'Unidad',
      'precio_actual',       v_pvp::text,
      'precio_sugerido',     round(ceil(v_costo_base / (1 - p_margen)
                                   * case when v_empresa.precios_incluyen_iva and not v_iva_cero
                                          then 1 + v_tarifa / 100 else 1 end * 100) / 100, 2)::text));
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
