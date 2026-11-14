-- =============================================================================
-- Compra a mano que crea los productos que faltan (D-067)
--
-- Las líneas son las de registrar_compra; una línea con "nuevo" describe un
-- producto que todavía no está en el catálogo, como en «¿Cuánto gano?» (D-066):
--   {"nuevo": {"nombre", "factor" (unidades por bulto), "precio_venta"?},
--    "cantidad", "costo_unitario", "descuento"?, "tarifa_iva"?}
-- Antes de registrar se crea el producto (medida Unidad, tarifa de la compra,
-- precio por unidad si se dio) y, si el bulto trae más de una unidad, la
-- presentación «Caja N» que no se vende, igual que al importar un XML (D-054).
-- Si ya hay un producto activo con ese nombre se usa ese. Todo en un paso: si la
-- compra no se registra, no queda ningún producto creado.
--
-- Los productos creados así quedan «por completar» (código, precio, categoría,
-- foto…) hasta que el Dueño los marca como revisados.
-- =============================================================================

alter table public.productos add column por_completar boolean not null default false;

create function public.registrar_compra_con_nuevos(
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
      if not x.e ? 'nuevo' then
        v_lineas := v_lineas || jsonb_build_array(x.e);
        continue;
      end if;

      begin
        v_nombre := left(nullif(trim(x.e -> 'nuevo' ->> 'nombre'), ''), 200);
        v_factor := round(coalesce(nullif(x.e -> 'nuevo' ->> 'factor', ''), '1')::numeric, 3);
        v_tarifa := coalesce((x.e ->> 'tarifa_iva')::numeric, 0);
        v_precio := nullif(trim(x.e -> 'nuevo' ->> 'precio_venta'), '');
      exception
        when invalid_text_representation or numeric_value_out_of_range then
          perform privado.fallar('DATOS_INVALIDOS', 'Hay un número mal escrito', jsonb_build_object('linea', x.o));
      end;
      if v_nombre is null then
        perform privado.fallar('DATOS_INVALIDOS', 'Falta el nombre del producto nuevo', jsonb_build_object('linea', x.o));
      end if;
      if v_factor is null or v_factor <= 0 then
        perform privado.fallar('DATOS_INVALIDOS', 'Las unidades por bulto deben ser más que cero',
                               jsonb_build_object('linea', x.o));
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

      -- Presentación con ese contenido: la que haya o una nueva «Caja N».
      select r.id into v_pres from public.presentaciones r
       where r.producto_id = v_producto and r.factor = v_factor and r.activo
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
        (x.e - 'nuevo') || jsonb_build_object('presentacion_id', v_pres, 'tarifa_iva', v_tarifa));
    end loop;

    v_r := public.registrar_compra(p_proveedor_id, p_con_respaldo, p_numero_documento, p_fecha,
                                   v_lineas, p_clave_idempotencia);
    -- Si la compra no entra, se deshacen los productos creados.
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

-- El Dueño revisó el producto: deja de aparecer «por completar».
create function public.marcar_producto_revisado(p_producto_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  update public.productos p set por_completar = false
   where p.id = p_producto_id and p.empresa_id = v_empresa;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'El producto no existe');
  end if;
  return privado.ok();
end;
$$;

revoke all on function
  public.registrar_compra_con_nuevos(uuid, boolean, text, date, jsonb, uuid),
  public.marcar_producto_revisado(uuid)
  from public, anon;
grant execute on function
  public.registrar_compra_con_nuevos(uuid, boolean, text, date, jsonb, uuid),
  public.marcar_producto_revisado(uuid)
  to authenticated;
