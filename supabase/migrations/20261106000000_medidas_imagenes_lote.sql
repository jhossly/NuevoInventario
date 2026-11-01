-- =============================================================================
-- Medidas propias, imagen del producto y productos en lote (D-048, D-049, D-050)
--
-- 1. Medidas: además de Unidad y Kilo, cada bodega crea las suyas (Paquete,
--    Funda, Litro…). unidad_base guarda el código de la medida, que es su
--    abreviatura en mayúsculas.
-- 2. Imagen: se guarda en Storage (depósito público «productos») y el producto
--    solo lleva la ruta. La lista de productos viaja a cada celular: con la
--    imagen dentro de la fila pesaría megas (a diferencia del logo, D-047).
-- 3. Lote: crear de una vez los productos de las líneas de facturas del SRI
--    que no tienen producto.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Medidas
-- -----------------------------------------------------------------------------
create table public.unidades_medida (
  empresa_id  uuid not null references public.empresas (id) on delete restrict,
  codigo      text not null,
  nombre      text not null,
  creado_en   timestamptz not null default now(),
  primary key (empresa_id, codigo),
  constraint unidades_medida_codigo check (codigo ~ '^[A-Z0-9ÁÉÍÓÚÑ.]{1,8}$'),
  constraint unidades_medida_nombre check (length(trim(nombre)) between 1 and 40)
);

revoke all on public.unidades_medida from anon, authenticated;
grant select on public.unidades_medida to authenticated;
alter table public.unidades_medida enable row level security;
create policy unidades_medida_lectura on public.unidades_medida
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

create function privado.crear_medidas_iniciales()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into public.unidades_medida (empresa_id, codigo, nombre)
  values (new.id, 'UND', 'Unidad'), (new.id, 'KG', 'Kilo'),
         (new.id, 'PAQ', 'Paquete'), (new.id, 'LT', 'Litro');
  return new;
end;
$$;

create trigger empresas_medidas_iniciales after insert on public.empresas
  for each row execute function privado.crear_medidas_iniciales();

insert into public.unidades_medida (empresa_id, codigo, nombre)
select e.id, m.codigo, m.nombre
  from public.empresas e,
       (values ('UND', 'Unidad'), ('KG', 'Kilo'), ('PAQ', 'Paquete'), ('LT', 'Litro')) m(codigo, nombre);

alter table public.productos
  drop constraint productos_unidad_valida,
  add constraint productos_unidad_fk foreign key (empresa_id, unidad_base)
    references public.unidades_medida (empresa_id, codigo) on delete restrict,
  add column imagen text,
  add constraint productos_imagen_largo check (length(imagen) <= 200);

-- p_codigo es la abreviatura (paq, fda…). Si ya existe, cambia su nombre.
create function public.guardar_medida(p_codigo text, p_nombre text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_codigo  text := upper(trim(p_codigo));
  v_detalle text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  insert into public.unidades_medida (empresa_id, codigo, nombre)
  values (v_empresa, v_codigo, trim(p_nombre))
  on conflict (empresa_id, codigo) do update set nombre = excluded.nombre;
  return privado.ok(jsonb_build_object('codigo', v_codigo));
exception
  when check_violation or not_null_violation then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS',
      case v_detalle
        when 'unidades_medida_codigo' then 'La abreviatura lleva de 1 a 8 letras o números, sin espacios'
        else 'Escribe el nombre de la medida' end);
end;
$$;

-- Unidad y Kilo no se borran: el sistema las usa por defecto.
create function public.eliminar_medida(p_codigo text)
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
  if p_codigo in ('UND', 'KG') then
    return privado.error('DATOS_INVALIDOS', 'Unidad y Kilo no se eliminan');
  end if;
  if exists (select 1 from public.productos p where p.empresa_id = v_empresa and p.unidad_base = p_codigo) then
    return privado.error('DATOS_INVALIDOS', 'Hay productos con esta medida: cámbiales la medida primero');
  end if;
  delete from public.unidades_medida m where m.empresa_id = v_empresa and m.codigo = p_codigo;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La medida no existe');
  end if;
  return privado.ok(jsonb_build_object('codigo', p_codigo));
end;
$$;

revoke all on function privado.crear_medidas_iniciales() from public, anon, authenticated;
revoke all on function public.guardar_medida(text, text), public.eliminar_medida(text) from public, anon;
grant execute on function public.guardar_medida(text, text), public.eliminar_medida(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Imágenes de productos en Storage
-- -----------------------------------------------------------------------------
-- Ruta: <empresa_id>/<nombre>.webp. Lectura pública por dirección (una foto de
-- producto no es un dato sensible); escribe solo el Dueño, en su carpeta.
do $$
begin
  if to_regclass('storage.buckets') is null then
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('productos', 'productos', true, 300000, array['image/webp', 'image/png', 'image/jpeg'])
  on conflict (id) do nothing;

  execute $p$
    create policy productos_imagenes_escritura on storage.objects
      for all to authenticated
      using (bucket_id = 'productos'
             and (storage.foldername(name))[1] = (select privado.mi_empresa())::text
             and (select privado.mi_rol()) = 'DUENO')
      with check (bucket_id = 'productos'
             and (storage.foldername(name))[1] = (select privado.mi_empresa())::text
             and (select privado.mi_rol()) = 'DUENO')
  $p$;
end;
$$;

-- Nueva versión: la medida debe existir, la presentación base toma su nombre y
-- se recibe `imagen` (ruta dentro de la carpeta de la bodega; vacío la quita).
create or replace function public.guardar_producto(p_id uuid, p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa   uuid := privado.mi_empresa();
  v_anterior  public.productos;
  v_producto  public.productos;
  v_detalle   text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_datos) is distinct from 'object' then
    return privado.error('DATOS_INVALIDOS');
  end if;
  if p_datos ->> 'categoria_id' is not null and not exists (
       select 1 from public.categorias c
        where c.id = (p_datos ->> 'categoria_id')::uuid and c.empresa_id = v_empresa) then
    return privado.error('DATOS_INVALIDOS', 'La categoría no existe');
  end if;
  if (p_datos ->> 'costo_servicio')::numeric < 0 then
    return privado.error('DATOS_INVALIDOS', 'El costo no puede ser negativo');
  end if;
  if p_datos ->> 'unidad_base' is not null and not exists (
       select 1 from public.unidades_medida m
        where m.empresa_id = v_empresa and m.codigo = p_datos ->> 'unidad_base') then
    return privado.error('DATOS_INVALIDOS', 'La medida no existe');
  end if;
  if nullif(trim(p_datos ->> 'imagen'), '') is not null
     and trim(p_datos ->> 'imagen') not like v_empresa::text || '/%' then
    return privado.error('DATOS_INVALIDOS', 'La imagen no es de esta bodega');
  end if;

  if p_id is null then
    insert into public.productos (empresa_id, nombre, categoria_id, unidad_base, tarifa_iva, codigo_iva,
                                  stock_minimo, codigo_principal, codigo_auxiliar, informacion_adicional,
                                  controla_stock, imagen, creado_por)
    values (v_empresa,
            trim(p_datos ->> 'nombre'),
            (p_datos ->> 'categoria_id')::uuid,
            coalesce(p_datos ->> 'unidad_base', 'UND'),
            coalesce((p_datos ->> 'tarifa_iva')::numeric, privado.tarifa_codigo_iva(p_datos ->> 'codigo_iva')),
            p_datos ->> 'codigo_iva',
            coalesce((p_datos ->> 'stock_minimo')::numeric, 0),
            nullif(trim(p_datos ->> 'codigo_principal'), ''),
            nullif(trim(p_datos ->> 'codigo_auxiliar'), ''),
            nullif(trim(p_datos ->> 'informacion_adicional'), ''),
            coalesce((p_datos ->> 'controla_stock')::boolean, true),
            nullif(trim(p_datos ->> 'imagen'), ''),
            auth.uid())
    returning * into v_producto;

    insert into public.presentaciones (empresa_id, producto_id, nombre, factor,
                                       codigo_barras, precio_venta, creado_por)
    values (v_empresa, v_producto.id,
            (select m.nombre from public.unidades_medida m
              where m.empresa_id = v_empresa and m.codigo = v_producto.unidad_base),
            1,
            nullif(trim(p_datos ->> 'codigo_barras'), ''),
            (p_datos ->> 'precio_venta')::numeric,
            auth.uid());

    insert into public.existencias (empresa_id, producto_id, ultimo_costo)
    values (v_empresa, v_producto.id,
            case when not v_producto.controla_stock then round((p_datos ->> 'costo_servicio')::numeric, 6) end);

    insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, despues)
    values (v_empresa, auth.uid(), 'PRODUCTO_CREADO', 'productos', v_producto.id, to_jsonb(v_producto));
  else
    select * into v_anterior
      from public.productos p
     where p.id = p_id and p.empresa_id = v_empresa
       for update;
    if not found then
      return privado.error('DATOS_INVALIDOS', 'El producto no existe');
    end if;

    if p_datos ? 'unidad_base'
       and p_datos ->> 'unidad_base' is distinct from v_anterior.unidad_base
       and exists (select 1 from public.movimientos_inventario m where m.producto_id = p_id) then
      return privado.error('DATOS_INVALIDOS',
        'No se puede cambiar la unidad base de un producto con movimientos');
    end if;
    if v_anterior.controla_stock and (p_datos ->> 'controla_stock')::boolean is false
       and exists (select 1 from public.existencias x where x.producto_id = p_id and x.cantidad <> 0) then
      return privado.error('DATOS_INVALIDOS',
        'Para dejar de controlar el stock, primero llévalo a cero con un ajuste');
    end if;

    update public.productos p set
      nombre       = case when p_datos ? 'nombre'       then trim(p_datos ->> 'nombre')               else p.nombre end,
      categoria_id = case when p_datos ? 'categoria_id' then (p_datos ->> 'categoria_id')::uuid       else p.categoria_id end,
      unidad_base  = case when p_datos ? 'unidad_base'  then p_datos ->> 'unidad_base'                else p.unidad_base end,
      tarifa_iva   = case when p_datos ? 'tarifa_iva' and not p_datos ? 'codigo_iva'
                          then (p_datos ->> 'tarifa_iva')::numeric                                    else p.tarifa_iva end,
      codigo_iva   = case when p_datos ? 'codigo_iva'   then p_datos ->> 'codigo_iva'                 else p.codigo_iva end,
      stock_minimo = case when p_datos ? 'stock_minimo' then (p_datos ->> 'stock_minimo')::numeric    else p.stock_minimo end,
      activo       = case when p_datos ? 'activo'       then (p_datos ->> 'activo')::boolean          else p.activo end,
      controla_stock = case when p_datos ? 'controla_stock'
                            then (p_datos ->> 'controla_stock')::boolean                              else p.controla_stock end,
      imagen = case when p_datos ? 'imagen' then nullif(trim(p_datos ->> 'imagen'), '') else p.imagen end,
      codigo_principal = case when p_datos ? 'codigo_principal'
                              then nullif(trim(p_datos ->> 'codigo_principal'), '')                   else p.codigo_principal end,
      codigo_auxiliar  = case when p_datos ? 'codigo_auxiliar'
                              then nullif(trim(p_datos ->> 'codigo_auxiliar'), '')                    else p.codigo_auxiliar end,
      informacion_adicional = case when p_datos ? 'informacion_adicional'
                              then nullif(trim(p_datos ->> 'informacion_adicional'), '')              else p.informacion_adicional end
     where p.id = p_id
    returning * into v_producto;

    if not v_producto.controla_stock and p_datos ? 'costo_servicio' then
      update public.existencias x
         set ultimo_costo = round((p_datos ->> 'costo_servicio')::numeric, 6), actualizado_en = now()
       where x.producto_id = p_id;
    end if;

    -- Incluye los cambios de tarifa_iva que pide la Fase 3.
    if v_producto is distinct from v_anterior then
      insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes, despues)
      values (v_empresa, auth.uid(), 'PRODUCTO_EDITADO', 'productos', p_id,
              to_jsonb(v_anterior), to_jsonb(v_producto));
    end if;
  end if;

  return privado.ok(jsonb_build_object('id', v_producto.id));
exception
  when unique_violation then
    get stacked diagnostics v_detalle = constraint_name;
    if v_detalle = 'productos_codigo_principal_unico' then
      return privado.error('DUPLICADO', 'El código principal ya está en uso');
    end if;
    return privado.error('DUPLICADO', 'El código de barras ya está en uso');
  when check_violation or not_null_violation or invalid_text_representation
       or numeric_value_out_of_range then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS', null, jsonb_build_object('restriccion', nullif(v_detalle, '')));
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Crear productos en lote desde líneas de facturas del SRI
-- -----------------------------------------------------------------------------
-- Por cada línea sin producto: si ya se resolvió en esta misma pasada (mismo
-- código) se salta; si hay un producto con el mismo nombre se usa ese; si no,
-- se crea con los datos de la línea. Todo o nada. Asociar recuerda el código y
-- alcanza a las demás líneas pendientes con ese código.
create function public.crear_productos_de_lineas(p_lineas uuid[], p_controla_stock boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa    public.empresas;
  v_id         uuid;
  v_linea      public.comprobante_lineas;
  v_pres       uuid;
  v_codigo     text;
  v_codigo_iva text;
  v_r          jsonb;
  v_creados    int := 0;
  v_usados     int := 0;
  v_detalle    text;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if coalesce(array_length(p_lineas, 1), 0) = 0 then
    return privado.error('DATOS_INVALIDOS', 'Elige al menos una línea');
  end if;

  foreach v_id in array p_lineas loop
    select l.* into v_linea
      from public.comprobante_lineas l
      join public.comprobantes c on c.id = l.comprobante_id
     where l.id = v_id and l.empresa_id = v_empresa.id and c.venta_id is null;
    if not found then
      perform privado.fallar('DATOS_INVALIDOS', 'Una de las líneas ya no está pendiente');
    end if;
    if v_linea.presentacion_id is not null then
      continue;
    end if;

    select r.id into v_pres
      from public.productos p
      join public.presentaciones r on r.producto_id = p.id and r.factor = 1 and r.activo
     where p.empresa_id = v_empresa.id and p.activo and lower(p.nombre) = lower(trim(v_linea.descripcion))
     limit 1;

    if v_pres is null then
      v_codigo_iva := privado.codigo_tarifa_iva(v_linea.tarifa_iva);
      if v_codigo_iva is null then
        perform privado.fallar('DATOS_INVALIDOS',
          v_linea.descripcion || ': la tarifa de IVA no se reconoce; créalo a mano');
      end if;
      -- Un producto inactivo puede tener el código: entonces queda sin código.
      v_codigo := case when length(v_linea.codigo) <= 25
                        and not exists (select 1 from public.productos p
                                         where p.empresa_id = v_empresa.id and p.codigo_principal = v_linea.codigo)
                       then v_linea.codigo end;
      v_r := public.guardar_producto(null, jsonb_build_object(
        'nombre',           left(trim(v_linea.descripcion), 200),
        'codigo_iva',       v_codigo_iva,
        'codigo_principal', v_codigo,
        'controla_stock',   p_controla_stock,
        'precio_venta',     round(v_linea.precio_unitario
                                  * case when v_empresa.precios_incluyen_iva then 1 + v_linea.tarifa_iva / 100 else 1 end, 2)));
      if (v_r ->> 'ok') is distinct from 'true' then
        perform privado.fallar('DATOS_INVALIDOS', v_linea.descripcion || ': no se pudo crear');
      end if;
      select r.id into v_pres from public.presentaciones r
       where r.producto_id = (v_r -> 'data' ->> 'id')::uuid and r.factor = 1;
      v_creados := v_creados + 1;
    else
      v_usados := v_usados + 1;
    end if;

    v_r := public.asociar_linea_comprobante(v_linea.id, v_pres);
    if (v_r ->> 'ok') is distinct from 'true' then
      perform privado.fallar('DATOS_INVALIDOS', v_linea.descripcion || ': no se pudo asociar');
    end if;
  end loop;

  return privado.ok(jsonb_build_object('creados', v_creados, 'existentes', v_usados));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
end;
$$;

revoke all on function public.crear_productos_de_lineas(uuid[], boolean) from public, anon;
grant execute on function public.crear_productos_de_lineas(uuid[], boolean) to authenticated;
