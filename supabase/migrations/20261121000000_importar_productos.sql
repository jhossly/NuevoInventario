-- =============================================================================
-- Importar productos desde el libro de Excel del dueño (D-071)
--
-- p_filas: [{"nombre", "codigo"?, "categoria"?, "stock"?, "costo"?}]
--   * No duplica: si el código ya es de un producto (principal, auxiliar o de
--     barras) o ya hay uno activo con ese nombre, la fila se salta.
--   * El código va como código principal; la categoría se busca por nombre o
--     se crea (en el libro, el nombre de la hoja: el distribuidor).
--   * El stock entra como apertura solo si es mayor que cero y trae costo por
--     unidad; si no, el producto queda sin stock.
--   * Todos quedan «por completar» (precio, foto…) con la tarifa p_tarifa_iva.
-- Todo en un paso: si una fila falla, no se crea nada y se dice cuál.
-- =============================================================================

create function public.importar_productos(p_filas jsonb, p_tarifa_iva numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa    uuid := privado.mi_empresa();
  x            record;
  v_nombre     text;
  v_codigo     text;
  v_categoria  text;
  v_cat_id     uuid;
  v_stock      numeric;
  v_costo      numeric;
  v_producto   uuid;
  v_r          jsonb;
  v_creados    int := 0;
  v_con_stock  int := 0;
  v_existentes int := 0;
  v_detalle    text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_filas) is distinct from 'array' or jsonb_array_length(p_filas) = 0 then
    return privado.error('DATOS_INVALIDOS', 'No hay productos para importar');
  end if;
  if privado.codigo_tarifa_iva(p_tarifa_iva) is null then
    return privado.error('DATOS_INVALIDOS', 'Esa tarifa de IVA no existe');
  end if;

  begin
    for x in select e, o::int as o from jsonb_array_elements(p_filas) with ordinality t(e, o) order by o loop
      v_nombre    := left(regexp_replace(trim(coalesce(x.e ->> 'nombre', '')), '\s+', ' ', 'g'), 200);
      v_codigo    := nullif(trim(coalesce(x.e ->> 'codigo', '')), '');
      v_categoria := nullif(left(trim(coalesce(x.e ->> 'categoria', '')), 100), '');
      begin
        v_stock := round(nullif(trim(coalesce(x.e ->> 'stock', '')), '')::numeric, 3);
        v_costo := round(nullif(trim(coalesce(x.e ->> 'costo', '')), '')::numeric, 6);
      exception
        when invalid_text_representation or numeric_value_out_of_range then
          perform privado.fallar('DATOS_INVALIDOS', 'Hay un número mal escrito', jsonb_build_object('linea', x.o));
      end;

      if v_nombre = '' then
        perform privado.fallar('DATOS_INVALIDOS', 'Falta el nombre', jsonb_build_object('linea', x.o));
      end if;
      if length(v_codigo) > 25 then
        perform privado.fallar('DATOS_INVALIDOS', 'El código pasa de 25 caracteres', jsonb_build_object('linea', x.o));
      end if;
      if v_costo < 0 then
        perform privado.fallar('DATOS_INVALIDOS', 'El costo no puede ser negativo', jsonb_build_object('linea', x.o));
      end if;

      -- Ya existe: por código (en cualquier producto) o por nombre (en los activos).
      if exists (
           select 1 from public.productos p
            where p.empresa_id = v_empresa
              and ((v_codigo is not null and (p.codigo_principal = v_codigo or p.codigo_auxiliar = v_codigo
                                               or exists (select 1 from public.presentaciones r
                                                           where r.producto_id = p.id and r.codigo_barras = v_codigo)))
                   or (p.activo and lower(p.nombre) = lower(v_nombre)))) then
        v_existentes := v_existentes + 1;
        continue;
      end if;

      v_cat_id := null;
      if v_categoria is not null then
        select c.id into v_cat_id from public.categorias c
         where c.empresa_id = v_empresa and lower(c.nombre) = lower(v_categoria);
        if v_cat_id is null then
          insert into public.categorias (empresa_id, nombre, creado_por)
          values (v_empresa, v_categoria, auth.uid())
          returning id into v_cat_id;
        end if;
      end if;

      v_r := public.guardar_producto(null, jsonb_build_object(
        'nombre',           v_nombre,
        'codigo_principal', v_codigo,
        'categoria_id',     v_cat_id,
        'unidad_base',      'UND',
        'codigo_iva',       privado.codigo_tarifa_iva(p_tarifa_iva)));
      if (v_r ->> 'ok') is distinct from 'true' then
        perform privado.fallar('DATOS_INVALIDOS',
          v_nombre || ': ' || coalesce(v_r -> 'error' ->> 'mensaje', 'no se pudo crear'), jsonb_build_object('linea', x.o));
      end if;
      v_producto := (v_r -> 'data' ->> 'id')::uuid;
      update public.productos p set por_completar = true where p.id = v_producto;
      v_creados := v_creados + 1;

      if v_stock > 0 and v_costo is not null then
        v_r := public.ajustar_inventario(v_producto, 'APERTURA', v_stock, v_costo, 'Importado del Excel');
        if (v_r ->> 'ok') is distinct from 'true' then
          perform privado.fallar('DATOS_INVALIDOS',
            v_nombre || ': ' || coalesce(v_r -> 'error' ->> 'mensaje', 'no se pudo poner el stock'),
            jsonb_build_object('linea', x.o));
        end if;
        v_con_stock := v_con_stock + 1;
      end if;
    end loop;
  exception
    when sqlstate 'NG001' then
      get stacked diagnostics v_detalle = pg_exception_detail;
      return v_detalle::jsonb;
  end;

  return privado.ok(jsonb_build_object('creados', v_creados, 'con_stock', v_con_stock, 'existentes', v_existentes));
end;
$$;

revoke all on function public.importar_productos(jsonb, numeric) from public, anon;
grant execute on function public.importar_productos(jsonb, numeric) to authenticated;
