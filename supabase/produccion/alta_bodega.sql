-- =============================================================================
-- Alta de la bodega real y de sus usuarios (puesta en producción).
--
-- Se ejecuta UNA vez, en el SQL Editor del proyecto de Supabase, después de
-- `supabase db push` (migraciones) y de crear los dos usuarios en
-- Authentication → Users → «Add user» → «Create new user» (con «Auto Confirm
-- User» marcado). Las contraseñas las escribe el dueño ahí: este archivo no
-- guarda ninguna.
--
-- Antes de ejecutar, cambia SOLO los valores entre comillas de la sección
-- «Datos de la bodega». Si algo falta o ya existe, no se guarda nada y el
-- mensaje dice qué corregir.
-- =============================================================================
do $$
declare
  -- ---------------------------------------------------------------------------
  -- Datos de la bodega (cámbialos)
  -- ---------------------------------------------------------------------------
  v_ruc               text := '0000000000001';          -- 13 dígitos, el del RUC
  v_razon_social      text := 'NOMBRES Y APELLIDOS';    -- como sale en el RUC
  v_nombre_comercial  text := 'Nombre de la bodega';    -- el que se ve en la app
  v_correo_dueno      text := 'dueno@correo.com';
  v_nombre_dueno      text := 'Nombre del dueño';
  v_correo_vendedor   text := 'vendedor@correo.com';    -- '' si todavía no hay
  v_nombre_vendedor   text := 'Nombre de quien vende';
  v_precios_con_iva   boolean := true;                  -- los precios de venta incluyen IVA
  -- ---------------------------------------------------------------------------

  v_empresa   uuid;
  v_dueno     uuid;
  v_vendedor  uuid;
begin
  if v_ruc = '0000000000001' or v_correo_dueno = 'dueno@correo.com' then
    raise exception 'Primero cambia los datos de la bodega al inicio del archivo';
  end if;
  if v_ruc !~ '^[0-9]{13}$' then
    raise exception 'El RUC debe tener 13 dígitos: %', v_ruc;
  end if;
  if exists (select 1 from public.empresas) then
    raise exception 'Ya hay una bodega registrada en esta base: el alta se hace una sola vez';
  end if;

  select u.id into v_dueno from auth.users u where lower(u.email) = lower(trim(v_correo_dueno));
  if v_dueno is null then
    raise exception 'No existe el usuario %: créalo en Authentication → Users', v_correo_dueno;
  end if;
  if trim(v_correo_vendedor) <> '' then
    select u.id into v_vendedor from auth.users u where lower(u.email) = lower(trim(v_correo_vendedor));
    if v_vendedor is null then
      raise exception 'No existe el usuario %: créalo en Authentication → Users', v_correo_vendedor;
    end if;
    if v_vendedor = v_dueno then
      raise exception 'El dueño y quien vende deben tener correos distintos';
    end if;
  end if;

  insert into public.empresas (ruc, razon_social, nombre_comercial, precios_incluyen_iva)
  values (v_ruc, trim(v_razon_social), nullif(trim(v_nombre_comercial), ''), v_precios_con_iva)
  returning id into v_empresa;

  insert into public.perfiles (id, nombre) values (v_dueno, trim(v_nombre_dueno));
  insert into public.membresias (empresa_id, usuario_id, rol) values (v_empresa, v_dueno, 'DUENO');

  if v_vendedor is not null then
    insert into public.perfiles (id, nombre) values (v_vendedor, trim(v_nombre_vendedor));
    insert into public.membresias (empresa_id, usuario_id, rol) values (v_empresa, v_vendedor, 'VENDEDOR');
  end if;

  raise notice 'Listo: bodega % (%) con su Dueño%.', v_nombre_comercial, v_ruc,
    case when v_vendedor is not null then ' y su Vendedor' else '' end;
end;
$$;

-- Comprobación: debe mostrar la bodega y sus usuarios con su rol.
select e.ruc, e.razon_social, e.nombre_comercial, u.email, m.rol
  from public.empresas e
  join public.membresias m on m.empresa_id = e.id
  join auth.users u on u.id = m.usuario_id
 order by m.rol;
