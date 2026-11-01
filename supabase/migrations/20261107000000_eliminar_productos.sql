-- =============================================================================
-- Eliminar productos y presentaciones sin historial (D-052)
--
-- Solo el Dueño, y solo lo que nunca se usó: sin movimientos, ventas, compras,
-- conteos ni líneas de facturas del SRI. Lo que tiene historial se desactiva:
-- el kardex y las ventas son inmutables. La auditoría conserva lo eliminado.
-- =============================================================================

create function public.eliminar_producto(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_producto public.productos;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  select * into v_producto from public.productos p
   where p.id = p_id and p.empresa_id = v_empresa
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'El producto no existe');
  end if;

  if exists (select 1 from public.movimientos_inventario m where m.producto_id = p_id)
     or exists (select 1 from public.venta_detalles d where d.producto_id = p_id)
     or exists (select 1 from public.compra_detalles d where d.producto_id = p_id)
     or exists (select 1 from public.conteo_detalles d where d.producto_id = p_id)
     or exists (select 1 from public.comprobante_lineas l
                  join public.presentaciones r on r.id = l.presentacion_id
                 where r.producto_id = p_id) then
    return privado.error('DATOS_INVALIDOS', 'Este producto ya tiene historial: desactívalo en vez de eliminarlo');
  end if;

  delete from public.codigos_sri s
   using public.presentaciones r
   where s.presentacion_id = r.id and r.producto_id = p_id;
  delete from public.existencias x where x.producto_id = p_id;
  delete from public.presentaciones r where r.producto_id = p_id;
  delete from public.productos p where p.id = p_id;

  insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes)
  values (v_empresa, auth.uid(), 'PRODUCTO_ELIMINADO', 'productos', p_id, to_jsonb(v_producto));

  -- La imagen: la borra quien llama, que tiene acceso a Storage.
  return privado.ok(jsonb_build_object('id', p_id, 'imagen', v_producto.imagen));
exception
  when foreign_key_violation then
    return privado.error('DATOS_INVALIDOS', 'Este producto ya tiene historial: desactívalo en vez de eliminarlo');
end;
$$;

create function public.eliminar_presentacion(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa      uuid := privado.mi_empresa();
  v_presentacion public.presentaciones;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  select * into v_presentacion from public.presentaciones r where r.id = p_id and r.empresa_id = v_empresa;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La presentación no existe');
  end if;
  perform 1 from public.productos p where p.id = v_presentacion.producto_id for update;

  -- La presentación base (factor 1) es la que usan las facturas y el conteo.
  if v_presentacion.factor = 1 and not exists (
       select 1 from public.presentaciones r
        where r.producto_id = v_presentacion.producto_id and r.id <> p_id and r.factor = 1) then
    return privado.error('DATOS_INVALIDOS', 'La presentación base no se elimina');
  end if;
  if exists (select 1 from public.venta_detalles d where d.presentacion_id = p_id)
     or exists (select 1 from public.compra_detalles d where d.presentacion_id = p_id)
     or exists (select 1 from public.comprobante_lineas l where l.presentacion_id = p_id) then
    return privado.error('DATOS_INVALIDOS', 'Esta presentación ya se usó: desactívala en vez de eliminarla');
  end if;

  delete from public.codigos_sri s where s.presentacion_id = p_id;
  delete from public.presentaciones r where r.id = p_id;

  insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes)
  values (v_empresa, auth.uid(), 'PRESENTACION_ELIMINADA', 'presentaciones', p_id, to_jsonb(v_presentacion));

  return privado.ok(jsonb_build_object('id', p_id));
exception
  when foreign_key_violation then
    return privado.error('DATOS_INVALIDOS', 'Esta presentación ya se usó: desactívala en vez de eliminarla');
end;
$$;

revoke all on function public.eliminar_producto(uuid), public.eliminar_presentacion(uuid) from public, anon;
grant execute on function public.eliminar_producto(uuid), public.eliminar_presentacion(uuid) to authenticated;
