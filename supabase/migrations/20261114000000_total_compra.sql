-- =============================================================================
-- Total de la compra antes de guardar (D-059)
--
-- La estimación devuelve también lo que costaría la compra con lo recibido, con
-- las mismas cuentas que registrar_compra_de_factura.
-- =============================================================================

create or replace function public.estimar_utilidad_factura(p_xml text, p_lineas jsonb)
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
  v_subtotal numeric := 0;
  v_descuento numeric := 0;
  v_iva      numeric := 0;
  v_otros    numeric := 0;
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

    v_subtotal  := v_subtotal + round(((x ->> 'base')::numeric + (x ->> 'descuento')::numeric) * v_parte, 2);
    v_descuento := v_descuento + round((x ->> 'descuento')::numeric * v_parte, 2);
    v_iva       := v_iva + round((x ->> 'iva')::numeric * v_parte, 2);
    v_otros     := v_otros + round((x ->> 'otros_impuestos')::numeric * v_parte, 2);

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

  return privado.ok(privado.resumen_utilidad(v_salida) || jsonb_build_object('compra', jsonb_build_object(
    'subtotal',      v_subtotal::numeric(12,2)::text,
    'descuento',     v_descuento::numeric(12,2)::text,
    'iva',           v_iva::numeric(12,2)::text,
    'otros',         v_otros::numeric(12,2)::text,
    'total',         (v_subtotal - v_descuento + v_iva + v_otros)::numeric(12,2)::text,
    'total_factura', v_datos ->> 'total')));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
  when invalid_text_representation then
    return privado.error('DATOS_INVALIDOS', 'Hay un número mal escrito');
end;
$$;
