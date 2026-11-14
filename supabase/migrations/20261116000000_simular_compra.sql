-- =============================================================================
-- Calculadora de compra: «¿Cuánto gano?» (D-065)
--
-- Las mismas cuentas de una compra a mano (calcular_lineas_compra, con el IVA
-- de cada línea) y de su utilidad estimada (D-058), sin registrar nada. Además,
-- por línea:
--   * lo que costó cada unidad en la última compra confirmada de ese producto
--   * el precio de hoy de la presentación vendible más pequeña
--   * el precio que daría el margen pedido sobre la venta sin IVA, redondeado
--     hacia arriba al centavo; con IVA si los precios lo incluyen y no rige
--     «IVA 0 %» (D-045)
-- p_lineas como en calcular_compra; p_margen es una fracción (0,20 = 20 %).
-- =============================================================================

create function public.simular_compra(p_lineas jsonb, p_margen numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa  public.empresas;
  v_iva_cero boolean;
  v_lineas   jsonb := '[]';
  v_extras   jsonb := '[]';
  v_compra   jsonb;
  l          record;
  v_prod     record;
  v_venta    record;
  v_ultima   record;
  v_precio   numeric;
  v_detalle  text;
begin
  select * into v_empresa from public.empresas em where em.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_margen is null or p_margen < 0 or p_margen >= 0.9 then
    return privado.error('DATOS_INVALIDOS', 'El margen debe estar entre 0 % y 89 %');
  end if;
  v_iva_cero := privado.iva_cero_en(v_empresa.id, (now() at time zone v_empresa.zona_horaria)::date);

  for l in select * from privado.calcular_lineas_compra(v_empresa.id, p_lineas) order by orden loop
    select p.id, p.nombre, p.tarifa_iva into v_prod from public.productos p where p.id = l.producto_id;

    v_lineas := v_lineas || jsonb_build_array(jsonb_build_object(
      'orden',    l.orden,
      'nombre',   v_prod.nombre,
      'cantidad', l.cantidad_base,
      'costo',    l.cantidad_base * l.costo_unitario_base,
      'venta',    privado.venta_neta_unidad(v_empresa, privado.precio_unidad_producto(v_prod.id), v_prod.tarifa_iva)
                  * l.cantidad_base));

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

  select jsonb_build_object(
           'subtotal',  coalesce(sum(subtotal), 0)::numeric(12,2)::text,
           'descuento', coalesce(sum(descuento), 0)::numeric(12,2)::text,
           'iva',       coalesce(sum(iva), 0)::numeric(12,2)::text,
           'total',     coalesce(sum(subtotal - descuento + iva), 0)::numeric(12,2)::text)
    into v_compra
    from privado.calcular_lineas_compra(v_empresa.id, p_lineas);

  return privado.ok(privado.resumen_utilidad(v_lineas)
                    || jsonb_build_object('compra', v_compra, 'detalle', v_extras));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
end;
$$;

revoke all on function public.simular_compra(jsonb, numeric) from public, anon;
grant execute on function public.simular_compra(jsonb, numeric) to authenticated;
