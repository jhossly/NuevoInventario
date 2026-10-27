-- =============================================================================
-- Migración 0006: reportes y exportación para el contador
-- Fase 1 (requisitos) / Fase 10 (implementación)
--
-- Todo es de solo lectura y solo para el Dueño (Fase 4: «Ver auditoría y
-- reportes»). Los montos llegan como texto (D-019) y los cálculos y redondeos
-- se hacen aquí (D-011).
--
-- Reglas comunes (D-037):
--   * Ventas «netas» = ventas confirmadas del período − devoluciones de esas
--     mismas ventas. Las ventas anuladas no cuentan (su anulación ya devolvió
--     todo); la exportación sí las lista, marcadas, para la trazabilidad.
--   * Una venta pertenece al período por su fecha; sus devoluciones se restan
--     en el período de la venta (así el margen de un producto no queda
--     negativo por una devolución que cae en otro mes).
--   * Base sin IVA de una línea = subtotal − descuento.
--
-- Crea: empresas.limite_ingresos_rimpe; reporte_ventas, reporte_margen,
-- acumulado_rimpe, exportacion_contador.
-- =============================================================================

alter table public.empresas
  add column limite_ingresos_rimpe numeric(12,2) not null default 20000,
  add constraint empresas_limite_rimpe check (limite_ingresos_rimpe > 0);
comment on column public.empresas.limite_ingresos_rimpe is
  'Ingresos brutos anuales máximos de RIMPE Negocio Popular. Valor por defecto a confirmar con el contador.';

-- -----------------------------------------------------------------------------
-- Auxiliares privados
-- -----------------------------------------------------------------------------

-- Valida un período y devuelve un error formateado, o null si está bien.
create function privado.error_periodo(p_desde date, p_hasta date)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_desde is null or p_hasta is null then privado.error('DATOS_INVALIDOS', 'Indica desde y hasta')
    when p_desde > p_hasta then privado.error('DATOS_INVALIDOS', 'La fecha inicial es posterior a la final')
    when p_hasta - p_desde > 366 then privado.error('DATOS_INVALIDOS', 'El período no puede pasar de un año')
    else null
  end
$$;

-- Líneas vendidas netas de devoluciones, de ventas confirmadas en el período.
create function privado.lineas_netas(p_empresa uuid, p_desde date, p_hasta date)
returns table (venta_id uuid, fecha date, producto_id uuid, tarifa_iva numeric,
               cantidad_base numeric, base numeric, iva numeric, total numeric, costo numeric)
language sql
stable
set search_path = ''
as $$
  select d.venta_id, v.fecha, d.producto_id, d.tarifa_iva,
         d.cantidad_base - coalesce(x.cantidad_base, 0),
         (d.subtotal - d.descuento) - coalesce(x.subtotal, 0),
         d.iva - coalesce(x.iva, 0),
         d.total - coalesce(x.total, 0),
         d.costo_total - coalesce(x.costo, 0)
    from public.venta_detalles d
    join public.ventas v on v.id = d.venta_id
    left join lateral (
      select sum(dd.cantidad_base) as cantidad_base, sum(dd.subtotal) as subtotal, sum(dd.iva) as iva,
             sum(dd.total) as total, sum(dd.costo_total) as costo
        from public.devolucion_detalles dd where dd.venta_detalle_id = d.id) x on true
   where v.empresa_id = p_empresa and v.estado = 'CONFIRMADA'
     and v.fecha between p_desde and p_hasta
$$;

-- -----------------------------------------------------------------------------
-- Resumen de ventas: totales del período, por día y por medio de pago
-- -----------------------------------------------------------------------------
create function public.reporte_ventas(p_desde date, p_hasta date)
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
               'ventas',       (select count(*) from public.ventas v
                                 where v.empresa_id = v_empresa and v.estado = 'CONFIRMADA'
                                   and v.fecha between p_desde and p_hasta),
               'anuladas',     (select count(*) from public.ventas v
                                 where v.empresa_id = v_empresa and v.estado = 'ANULADA'
                                   and v.fecha between p_desde and p_hasta),
               'base',         coalesce(sum(l.base), 0)::numeric(12,2)::text,
               'iva',          coalesce(sum(l.iva), 0)::numeric(12,2)::text,
               'total',        coalesce(sum(l.total), 0)::numeric(12,2)::text,
               'costo',        coalesce(sum(l.costo), 0)::numeric(16,2)::text,
               'utilidad',     coalesce(sum(l.base - l.costo), 0)::numeric(16,2)::text,
               'margen',       case when sum(l.base) > 0
                                    then round(sum(l.base - l.costo) / sum(l.base), 4)::text end)
        from privado.lineas_netas(v_empresa, p_desde, p_hasta) l),
    'por_dia', coalesce((
      select jsonb_agg(jsonb_build_object(
               'fecha', d.fecha, 'total', d.total::numeric(12,2)::text, 'base', d.base::numeric(12,2)::text)
             order by d.fecha)
        from (select l.fecha, sum(l.total) as total, sum(l.base) as base
                from privado.lineas_netas(v_empresa, p_desde, p_hasta) l group by l.fecha) d), '[]'::jsonb),
    -- Cobrado por medio de pago (sin restar devoluciones: es lo que entró).
    'por_medio', coalesce((
      select jsonb_object_agg(m.medio, m.monto::numeric(12,2)::text)
        from (select p.medio, sum(p.monto) as monto
                from public.venta_pagos p join public.ventas v on v.id = p.venta_id
               where v.empresa_id = v_empresa and v.estado = 'CONFIRMADA'
                 and v.fecha between p_desde and p_hasta
               group by p.medio) m), '{}'::jsonb),
    'devoluciones', (
      select coalesce(sum(d.total), 0)::numeric(12,2)::text
        from public.devoluciones d
       where d.empresa_id = v_empresa and d.fecha between p_desde and p_hasta)));
end;
$$;

-- -----------------------------------------------------------------------------
-- Margen por producto (HU-05)
-- -----------------------------------------------------------------------------
-- margen  = utilidad ÷ ventas sin IVA   (lo que queda de cada dólar vendido)
-- recargo = utilidad ÷ costo            (cuánto se sube sobre el costo)
-- Ambos como fracción con 4 decimales; la interfaz los muestra como porcentaje.
create function public.reporte_margen(p_desde date, p_hasta date)
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

  return privado.ok(jsonb_build_object('productos', coalesce((
    select jsonb_agg(jsonb_build_object(
             'producto_id', p.id,
             'nombre',      p.nombre,
             'unidad_base', p.unidad_base,
             'cantidad',    r.cantidad::numeric(14,3)::text,
             'ventas',      r.ventas::numeric(12,2)::text,
             'costo',       r.costo::numeric(16,2)::text,
             'utilidad',    (r.ventas - r.costo)::numeric(16,2)::text,
             'margen',      case when r.ventas > 0 then round((r.ventas - r.costo) / r.ventas, 4)::text end,
             'recargo',     case when r.costo > 0 then round((r.ventas - r.costo) / r.costo, 4)::text end)
           order by r.ventas - r.costo desc, p.nombre)
      from (select l.producto_id, sum(l.cantidad_base) as cantidad, sum(l.base) as ventas, sum(l.costo) as costo
              from privado.lineas_netas(v_empresa, p_desde, p_hasta) l
             group by l.producto_id) r
      join public.productos p on p.id = r.producto_id
     where r.cantidad <> 0 or r.ventas <> 0), '[]'::jsonb)));
end;
$$;

-- -----------------------------------------------------------------------------
-- Acumulado del año frente al límite de RIMPE Negocio Popular
-- -----------------------------------------------------------------------------
-- Ingresos = ventas netas sin IVA del año calendario.
create function public.acumulado_rimpe(p_anio int)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa  public.empresas;
  v_desde    date;
  v_hasta    date;
  v_total    numeric;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_anio is null or p_anio < 2000 or p_anio > 2100 then
    return privado.error('DATOS_INVALIDOS', 'Año no válido');
  end if;
  v_desde := make_date(p_anio, 1, 1);
  v_hasta := make_date(p_anio, 12, 31);

  select coalesce(sum(l.base), 0) into v_total from privado.lineas_netas(v_empresa.id, v_desde, v_hasta) l;

  return privado.ok(jsonb_build_object(
    'anio',       p_anio,
    'limite',     v_empresa.limite_ingresos_rimpe::text,
    'acumulado',  v_total::numeric(12,2)::text,
    'porcentaje', round(v_total / v_empresa.limite_ingresos_rimpe, 4)::text,
    'disponible', greatest(v_empresa.limite_ingresos_rimpe - v_total, 0)::numeric(12,2)::text,
    'por_mes', (
      select jsonb_agg(jsonb_build_object('mes', m, 'base', coalesce(x.base, 0)::numeric(12,2)::text) order by m)
        from generate_series(1, 12) m
        left join (select extract(month from l.fecha)::int as mes, sum(l.base) as base
                     from privado.lineas_netas(v_empresa.id, v_desde, v_hasta) l group by 1) x on x.mes = m)));
end;
$$;

-- -----------------------------------------------------------------------------
-- Exportación para el contador
-- -----------------------------------------------------------------------------
-- Un documento por fila, con la base separada en 0 % y gravada (> 0 %).
-- Ventas y compras anuladas se listan con su estado y no suman en el resumen.
create function public.exportacion_contador(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_error   jsonb := privado.error_periodo(p_desde, p_hasta);
  v_ventas  jsonb;
  v_compras jsonb;
  v_devol   jsonb;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if v_error is not null then
    return v_error;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'fecha',            v.fecha,
           'venta',            left(v.id::text, 8),
           'comprobante',      v.tipo_comprobante,
           'cliente',          coalesce(c.nombre, 'Consumidor final'),
           'identificacion',   coalesce(c.identificacion, ''),
           'base_0',           b.base_0::numeric(12,2)::text,
           'base_gravada',     b.base_gravada::numeric(12,2)::text,
           'iva',              v.iva::text,
           'total',            v.total::text,
           'estado',           v.estado)
         order by v.fecha, v.creado_en), '[]'::jsonb)
    into v_ventas
    from public.ventas v
    left join public.clientes c on c.id = v.cliente_id
    cross join lateral (
      select coalesce(sum(d.subtotal - d.descuento) filter (where d.tarifa_iva = 0), 0) as base_0,
             coalesce(sum(d.subtotal - d.descuento) filter (where d.tarifa_iva > 0), 0) as base_gravada
        from public.venta_detalles d where d.venta_id = v.id) b
   where v.empresa_id = v_empresa and v.fecha between p_desde and p_hasta;

  select coalesce(jsonb_agg(jsonb_build_object(
           'fecha',          o.fecha,
           'venta',          left(o.venta_id::text, 8),
           'motivo',         o.motivo,
           'reintegro',      o.forma_reintegro,
           'base_0',         b.base_0::numeric(12,2)::text,
           'base_gravada',   b.base_gravada::numeric(12,2)::text,
           'iva',            o.iva::text,
           'total',          o.total::text)
         order by o.fecha, o.creado_en), '[]'::jsonb)
    into v_devol
    from public.devoluciones o
    cross join lateral (
      select coalesce(sum(dd.subtotal) filter (where d.tarifa_iva = 0), 0) as base_0,
             coalesce(sum(dd.subtotal) filter (where d.tarifa_iva > 0), 0) as base_gravada
        from public.devolucion_detalles dd join public.venta_detalles d on d.id = dd.venta_detalle_id
       where dd.devolucion_id = o.id) b
   where o.empresa_id = v_empresa and o.fecha between p_desde and p_hasta;

  select coalesce(jsonb_agg(jsonb_build_object(
           'fecha',            m.fecha,
           'proveedor',        coalesce(p.nombre, 'Sin proveedor'),
           'identificacion',   coalesce(p.identificacion, ''),
           'documento',        coalesce(m.numero_documento, ''),
           'respaldo',         case when m.con_respaldo then 'SI' else 'NO' end,
           'base_0',           b.base_0::numeric(12,2)::text,
           'base_gravada',     b.base_gravada::numeric(12,2)::text,
           'iva',              m.iva::text,
           'total',            m.total::text,
           'estado',           m.estado)
         order by m.fecha, m.creado_en), '[]'::jsonb)
    into v_compras
    from public.compras m
    left join public.proveedores p on p.id = m.proveedor_id
    cross join lateral (
      select coalesce(sum(d.subtotal - d.descuento) filter (where d.tarifa_iva = 0), 0) as base_0,
             coalesce(sum(d.subtotal - d.descuento) filter (where d.tarifa_iva > 0), 0) as base_gravada
        from public.compra_detalles d where d.compra_id = m.id) b
   where m.empresa_id = v_empresa and m.fecha between p_desde and p_hasta;

  return privado.ok(jsonb_build_object(
    'ventas',       v_ventas,
    'devoluciones', v_devol,
    'compras',      v_compras,
    -- Resumen de IVA del período: solo documentos confirmados.
    'resumen', jsonb_build_object(
      'ventas_base_0',        (select coalesce(sum((x ->> 'base_0')::numeric), 0)::numeric(12,2)::text
                                 from jsonb_array_elements(v_ventas) x where x ->> 'estado' = 'CONFIRMADA'),
      'ventas_base_gravada',  (select coalesce(sum((x ->> 'base_gravada')::numeric), 0)::numeric(12,2)::text
                                 from jsonb_array_elements(v_ventas) x where x ->> 'estado' = 'CONFIRMADA'),
      'ventas_iva',           (select coalesce(sum((x ->> 'iva')::numeric), 0)::numeric(12,2)::text
                                 from jsonb_array_elements(v_ventas) x where x ->> 'estado' = 'CONFIRMADA'),
      'devoluciones_base_0',  (select coalesce(sum((x ->> 'base_0')::numeric), 0)::numeric(12,2)::text
                                 from jsonb_array_elements(v_devol) x),
      'devoluciones_base_gravada', (select coalesce(sum((x ->> 'base_gravada')::numeric), 0)::numeric(12,2)::text
                                 from jsonb_array_elements(v_devol) x),
      'devoluciones_iva',     (select coalesce(sum((x ->> 'iva')::numeric), 0)::numeric(12,2)::text
                                 from jsonb_array_elements(v_devol) x),
      'compras_base_0',       (select coalesce(sum((x ->> 'base_0')::numeric), 0)::numeric(12,2)::text
                                 from jsonb_array_elements(v_compras) x where x ->> 'estado' = 'CONFIRMADA'),
      'compras_base_gravada', (select coalesce(sum((x ->> 'base_gravada')::numeric), 0)::numeric(12,2)::text
                                 from jsonb_array_elements(v_compras) x where x ->> 'estado' = 'CONFIRMADA'),
      'compras_iva',          (select coalesce(sum((x ->> 'iva')::numeric), 0)::numeric(12,2)::text
                                 from jsonb_array_elements(v_compras) x where x ->> 'estado' = 'CONFIRMADA'))));
end;
$$;

-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
revoke all on function
  privado.error_periodo(date, date),
  privado.lineas_netas(uuid, date, date)
  from public, anon, authenticated;

revoke all on function
  public.reporte_ventas(date, date),
  public.reporte_margen(date, date),
  public.acumulado_rimpe(int),
  public.exportacion_contador(date, date)
  from public, anon;
grant execute on function
  public.reporte_ventas(date, date),
  public.reporte_margen(date, date),
  public.acumulado_rimpe(int),
  public.exportacion_contador(date, date)
  to authenticated;
