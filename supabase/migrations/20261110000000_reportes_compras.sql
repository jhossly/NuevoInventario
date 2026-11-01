-- =============================================================================
-- Reportes de compras y resumen por mes (D-055)
--
-- Las compras cuentan por la fecha de su documento y solo las confirmadas. El
-- resumen mensual pone lado a lado ventas y compras, y muestra aparte las
-- facturas de venta subidas que todavía no tienen venta: no suman a las ventas
-- porque aún no se sabe si ya estaban registradas (D-012), pero no se pierden.
-- =============================================================================

create function public.reporte_compras(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_error   jsonb := privado.error_periodo(p_desde, p_hasta);
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if v_error is not null then
    return v_error;
  end if;

  return privado.ok(jsonb_build_object(
    'totales', (
      select jsonb_build_object(
               'compras',  count(*) filter (where c.estado = 'CONFIRMADA'),
               'anuladas', count(*) filter (where c.estado = 'ANULADA'),
               'sin_iva',  coalesce(sum(c.subtotal - c.descuento) filter (where c.estado = 'CONFIRMADA'), 0)::numeric(12,2)::text,
               'iva',      coalesce(sum(c.iva) filter (where c.estado = 'CONFIRMADA'), 0)::numeric(12,2)::text,
               'otros',    coalesce(sum(c.otros_impuestos) filter (where c.estado = 'CONFIRMADA'), 0)::numeric(12,2)::text,
               'total',    coalesce(sum(c.total) filter (where c.estado = 'CONFIRMADA'), 0)::numeric(12,2)::text)
        from public.compras c
       where c.empresa_id = v_empresa and c.fecha between p_desde and p_hasta),
    'por_proveedor', coalesce((
      select jsonb_agg(jsonb_build_object(
               'proveedor_id', x.proveedor_id,
               'nombre',       coalesce(x.nombre, 'Sin proveedor'),
               'compras',      x.compras,
               'sin_iva',      x.sin_iva::numeric(12,2)::text,
               'iva',          x.iva::numeric(12,2)::text,
               'total',        x.total::numeric(12,2)::text,
               'ultima',       x.ultima)
             order by x.total desc, x.nombre)
        from (select c.proveedor_id, v.nombre, count(*) as compras, sum(c.subtotal - c.descuento) as sin_iva,
                     sum(c.iva) as iva, sum(c.total) as total, max(c.fecha) as ultima
                from public.compras c
                left join public.proveedores v on v.id = c.proveedor_id
               where c.empresa_id = v_empresa and c.estado = 'CONFIRMADA'
                 and c.fecha between p_desde and p_hasta
               group by c.proveedor_id, v.nombre) x), '[]'::jsonb),
    'por_producto', coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto_id', x.producto_id,
               'nombre',      x.nombre,
               'unidad_base', x.unidad_base,
               'cantidad',    x.cantidad::text,
               'total',       x.total::numeric(12,2)::text)
             order by x.total desc, x.nombre)
        from (select d.producto_id, p.nombre, p.unidad_base, sum(d.cantidad_base) as cantidad,
                     sum(d.subtotal - d.descuento + d.iva + d.otros_impuestos) as total
                from public.compra_detalles d
                join public.compras c on c.id = d.compra_id
                join public.productos p on p.id = d.producto_id
               where c.empresa_id = v_empresa and c.estado = 'CONFIRMADA'
                 and c.fecha between p_desde and p_hasta
               group by d.producto_id, p.nombre, p.unidad_base
               order by total desc
               limit 15) x), '[]'::jsonb)));
end;
$$;

-- Los doce meses del año, también los que no tienen movimiento.
create function public.resumen_mensual(p_anio int)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_desde   date;
  v_hasta   date;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_anio is null or p_anio not between 2000 and 2100 then
    return privado.error('DATOS_INVALIDOS', 'El año no es válido');
  end if;
  v_desde := make_date(p_anio, 1, 1);
  v_hasta := make_date(p_anio, 12, 31);

  return privado.ok(jsonb_build_object(
    'anio', p_anio,
    'meses', (
      select jsonb_agg(jsonb_build_object(
               'mes',            m.mes,
               'ventas',         coalesce(v.total, 0)::numeric(12,2)::text,
               'utilidad',       coalesce(v.utilidad, 0)::numeric(16,2)::text,
               'compras',        coalesce(c.total, 0)::numeric(12,2)::text,
               'num_compras',    coalesce(c.cuantas, 0),
               'sin_registrar',  coalesce(f.total, 0)::numeric(12,2)::text,
               'num_sin_registrar', coalesce(f.cuantas, 0))
             order by m.mes)
        from generate_series(1, 12) m(mes)
        left join (select extract(month from l.fecha)::int as mes, sum(l.total) as total, sum(l.base - l.costo) as utilidad
                     from privado.lineas_netas(v_empresa, v_desde, v_hasta) l group by 1) v on v.mes = m.mes
        left join (select extract(month from x.fecha)::int as mes, sum(x.total) as total, count(*) as cuantas
                     from public.compras x
                    where x.empresa_id = v_empresa and x.estado = 'CONFIRMADA'
                      and x.fecha between v_desde and v_hasta group by 1) c on c.mes = m.mes
        left join (select extract(month from x.fecha_emision)::int as mes, sum(x.total) as total, count(*) as cuantas
                     from public.comprobantes x
                    where x.empresa_id = v_empresa and x.venta_id is null
                      and x.fecha_emision between v_desde and v_hasta group by 1) f on f.mes = m.mes)));
end;
$$;

revoke all on function public.reporte_compras(date, date), public.resumen_mensual(int) from public, anon;
grant execute on function public.reporte_compras(date, date), public.resumen_mensual(int) to authenticated;
