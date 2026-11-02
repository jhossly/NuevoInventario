-- =============================================================================
-- Utilidad estimada de una compra (D-058)
--
-- Cuánto quedaría si todo lo comprado se vende a los precios actuales. Es una
-- estimación: no guarda nada y no cambia ni el costo ni el precio.
--
--   venta neta = precio de venta sin IVA, por unidad base
--   costo      = lo que costó cada unidad base en esta compra
--   utilidad   = (venta neta − costo) × unidades
--
-- El precio es el de la presentación vendible más pequeña del producto. Si hay
-- «IVA 0 %» vigente (D-045), el precio completo es venta.
-- =============================================================================

-- Precio sin IVA de una unidad base; null si el producto no tiene precio.
create function privado.venta_neta_unidad(
  p_empresa public.empresas, p_precio_unidad numeric, p_tarifa numeric)
returns numeric
language sql
stable
set search_path = ''
as $$
  select case
    when p_precio_unidad is null then null
    when not p_empresa.precios_incluyen_iva then p_precio_unidad
    when privado.iva_cero_en(p_empresa.id, (now() at time zone p_empresa.zona_horaria)::date) then p_precio_unidad
    else p_precio_unidad / (1 + p_tarifa / 100)
  end;
$$;

create function privado.precio_unidad_producto(p_producto uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select r.precio_venta / r.factor
    from public.presentaciones r
   where r.producto_id = p_producto and r.activo and r.se_vende and r.precio_venta is not null
   order by r.factor, r.creado_en
   limit 1;
$$;

-- Totales de un jsonb [{costo, venta}]: solo suman las líneas con precio.
create function privado.resumen_utilidad(p_lineas jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with t as (
    select coalesce(sum((l ->> 'costo')::numeric) filter (where l ->> 'venta' is not null), 0) as costo,
           coalesce(sum((l ->> 'venta')::numeric) filter (where l ->> 'venta' is not null), 0) as venta,
           count(*) filter (where l ->> 'venta' is null) as sin_precio
      from jsonb_array_elements(p_lineas) l)
  select jsonb_build_object(
           'lineas', (select coalesce(jsonb_agg(jsonb_build_object(
                        'orden',          (l ->> 'orden')::int,
                        'nombre',         l ->> 'nombre',
                        'cantidad',       (l ->> 'cantidad')::numeric::text,
                        'costo_unidad',   round((l ->> 'costo')::numeric / (l ->> 'cantidad')::numeric, 4)::text,
                        'venta_unidad',   round((l ->> 'venta')::numeric / (l ->> 'cantidad')::numeric, 4)::text,
                        'utilidad',       round((l ->> 'venta')::numeric - (l ->> 'costo')::numeric, 2)::text,
                        'margen',         case when (l ->> 'venta')::numeric > 0
                                               then round(((l ->> 'venta')::numeric - (l ->> 'costo')::numeric)
                                                          / (l ->> 'venta')::numeric, 4)::text end)
                        order by (l ->> 'orden')::int), '[]'::jsonb)
                        from jsonb_array_elements(p_lineas) l),
           'costo',      round(t.costo, 2)::text,
           'venta',      round(t.venta, 2)::text,
           'utilidad',   round(t.venta - t.costo, 2)::text,
           'margen',     case when t.venta > 0 then round((t.venta - t.costo) / t.venta, 4)::text end,
           'sin_precio', t.sin_precio)
    from t;
$$;

-- Antes de guardar: mismas cuentas que registrar_compra_de_factura, sobre lo que
-- quien revisa indicó. p_lineas como en esa función.
create function public.estimar_utilidad_factura(p_xml text, p_lineas jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa  public.empresas;
  v_datos    jsonb;
  x          jsonb;
  e          jsonb;
  v_recibida numeric;
  v_factor   numeric;
  v_parte    numeric;
  v_costo    numeric;
  v_precio   numeric;
  v_tarifa   numeric;
  v_salida   jsonb := '[]';
  v_detalle  text;
begin
  select * into v_empresa from public.empresas em where em.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_lineas) is distinct from 'array' then
    return privado.error('DATOS_INVALIDOS');
  end if;

  v_datos := privado.leer_xml_proveedor(v_empresa, p_xml);

  for x in select l from jsonb_array_elements(v_datos -> 'lineas') l order by (l ->> 'orden')::int loop
    select l into e from jsonb_array_elements(p_lineas) l where (l ->> 'orden')::int = (x ->> 'orden')::int limit 1;
    continue when e is null;
    begin
      v_recibida := round((e ->> 'cantidad_recibida')::numeric, 3);
      v_factor   := coalesce((e ->> 'factor')::numeric, 1);
    exception when invalid_text_representation or numeric_value_out_of_range then
      continue;
    end;
    continue when v_recibida is null or v_recibida <= 0 or v_factor <= 0;

    v_parte := v_recibida / (x ->> 'cantidad')::numeric;
    v_costo := round(((x ->> 'base')::numeric) * v_parte, 2) + round((x ->> 'otros_impuestos')::numeric * v_parte, 2)
               + case when v_empresa.iva_compras_es_costo then round((x ->> 'iva')::numeric * v_parte, 2) else 0 end;

    if e ? 'nuevo' then
      v_precio := nullif(e -> 'nuevo' ->> 'precio_venta', '')::numeric;
      v_tarifa := (x ->> 'tarifa_iva')::numeric;
    else
      select privado.precio_unidad_producto(p.id), p.tarifa_iva into v_precio, v_tarifa
        from public.productos p
       where p.id = (e ->> 'producto_id')::uuid and p.empresa_id = v_empresa.id;
    end if;

    v_salida := v_salida || jsonb_build_array(jsonb_build_object(
      'orden',    (x ->> 'orden')::int,
      'nombre',   x ->> 'descripcion',
      'cantidad', round(v_recibida * v_factor, 3),
      'costo',    v_costo,
      'venta',    privado.venta_neta_unidad(v_empresa, v_precio, v_tarifa) * round(v_recibida * v_factor, 3)));
  end loop;

  return privado.ok(privado.resumen_utilidad(v_salida));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
  when invalid_text_representation then
    return privado.error('DATOS_INVALIDOS', 'Hay un número mal escrito');
end;
$$;

-- Una compra ya registrada, a los precios de hoy.
create function public.utilidad_estimada_compra(p_compra_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa public.empresas;
  v_salida  jsonb;
begin
  select * into v_empresa from public.empresas em where em.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if not exists (select 1 from public.compras c where c.id = p_compra_id and c.empresa_id = v_empresa.id) then
    return privado.error('DATOS_INVALIDOS', 'La compra no existe');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'orden',    d.orden,
           'nombre',   p.nombre,
           'cantidad', d.cantidad_base,
           'costo',    d.cantidad_base * d.costo_unitario_base,
           'venta',    privado.venta_neta_unidad(v_empresa, privado.precio_unidad_producto(p.id), p.tarifa_iva)
                       * d.cantidad_base)), '[]'::jsonb)
    into v_salida
    from public.compra_detalles d
    join public.productos p on p.id = d.producto_id
   where d.compra_id = p_compra_id;

  return privado.ok(privado.resumen_utilidad(v_salida));
end;
$$;

revoke all on function
  privado.venta_neta_unidad(public.empresas, numeric, numeric),
  privado.precio_unidad_producto(uuid),
  privado.resumen_utilidad(jsonb)
  from public, anon, authenticated;

revoke all on function
  public.estimar_utilidad_factura(text, jsonb),
  public.utilidad_estimada_compra(uuid)
  from public, anon;
grant execute on function
  public.estimar_utilidad_factura(text, jsonb),
  public.utilidad_estimada_compra(uuid)
  to authenticated;
