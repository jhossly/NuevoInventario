-- =============================================================================
-- Mi negocio: datos y ajustes de la bodega desde el panel (D-047)
--
-- El Dueño cambia nombre, razón social, dirección, teléfono, logo y ajustes
-- sin tocar SQL. El RUC no se cambia aquí: la importación de facturas del SRI
-- lo usa para reconocer las de la bodega.
--
-- El logo se guarda en empresas.logo como imagen en base64, ya reducida en el
-- navegador: pesa unos KB, entra en los respaldos de la base y no necesita un
-- depósito de archivos aparte (igual que el XML, D-041). No se admite SVG,
-- que puede llevar código.
-- =============================================================================

alter table public.empresas
  add column direccion text,
  add column telefono  text,
  add column logo      text,
  add constraint empresas_razon_social_no_vacia check (length(trim(razon_social)) > 0),
  add constraint empresas_direccion_largo check (length(direccion) <= 300),
  add constraint empresas_telefono_largo check (length(telefono) <= 20),
  add constraint empresas_logo_valido check (
    length(logo) <= 200000
    and logo ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$');

-- Claves de p_datos (todas opcionales): nombre_comercial, razon_social,
-- direccion, telefono, logo, precios_incluyen_iva, iva_compras_es_costo,
-- vendedor_ve_costos, descuento_max_vendedor, monto_max_consumidor_final,
-- monto_max_sin_comprobante, limite_ingresos_rimpe. Un texto vacío borra.
create function public.guardar_mi_negocio(p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa   uuid := privado.mi_empresa();
  v_anterior  public.empresas;
  v_nueva     public.empresas;
  v_detalle   text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_datos) is distinct from 'object' then
    return privado.error('DATOS_INVALIDOS');
  end if;
  if p_datos ? 'ruc' then
    return privado.error('DATOS_INVALIDOS', 'El RUC no se cambia desde aquí');
  end if;

  select * into v_anterior from public.empresas e where e.id = v_empresa for update;

  update public.empresas e set
    nombre_comercial = case when p_datos ? 'nombre_comercial'
                            then nullif(trim(p_datos ->> 'nombre_comercial'), '') else e.nombre_comercial end,
    razon_social     = case when p_datos ? 'razon_social'
                            then trim(p_datos ->> 'razon_social') else e.razon_social end,
    direccion        = case when p_datos ? 'direccion'
                            then nullif(trim(p_datos ->> 'direccion'), '') else e.direccion end,
    telefono         = case when p_datos ? 'telefono'
                            then nullif(trim(p_datos ->> 'telefono'), '') else e.telefono end,
    logo             = case when p_datos ? 'logo'
                            then nullif(p_datos ->> 'logo', '') else e.logo end,
    precios_incluyen_iva = case when p_datos ? 'precios_incluyen_iva'
                            then (p_datos ->> 'precios_incluyen_iva')::boolean else e.precios_incluyen_iva end,
    iva_compras_es_costo = case when p_datos ? 'iva_compras_es_costo'
                            then (p_datos ->> 'iva_compras_es_costo')::boolean else e.iva_compras_es_costo end,
    vendedor_ve_costos = case when p_datos ? 'vendedor_ve_costos'
                            then (p_datos ->> 'vendedor_ve_costos')::boolean else e.vendedor_ve_costos end,
    descuento_max_vendedor = case when p_datos ? 'descuento_max_vendedor'
                            then (p_datos ->> 'descuento_max_vendedor')::numeric else e.descuento_max_vendedor end,
    monto_max_consumidor_final = case when p_datos ? 'monto_max_consumidor_final'
                            then (p_datos ->> 'monto_max_consumidor_final')::numeric else e.monto_max_consumidor_final end,
    monto_max_sin_comprobante = case when p_datos ? 'monto_max_sin_comprobante'
                            then (p_datos ->> 'monto_max_sin_comprobante')::numeric else e.monto_max_sin_comprobante end,
    limite_ingresos_rimpe = case when p_datos ? 'limite_ingresos_rimpe'
                            then (p_datos ->> 'limite_ingresos_rimpe')::numeric else e.limite_ingresos_rimpe end
   where e.id = v_empresa
  returning * into v_nueva;

  -- El logo no va a la auditoría: basta saber si cambió.
  if v_nueva is distinct from v_anterior then
    insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes, despues)
    values (v_empresa, auth.uid(), 'EMPRESA_EDITADA', 'empresas', v_empresa,
            to_jsonb(v_anterior) - 'logo',
            (to_jsonb(v_nueva) - 'logo')
              || jsonb_build_object('logo_cambiado', v_nueva.logo is distinct from v_anterior.logo));
  end if;

  return privado.ok(jsonb_build_object('id', v_empresa));
exception
  when check_violation or not_null_violation or invalid_text_representation
       or numeric_value_out_of_range then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS', null, jsonb_build_object('restriccion', nullif(v_detalle, '')));
end;
$$;

revoke all on function public.guardar_mi_negocio(jsonb) from public, anon;
grant execute on function public.guardar_mi_negocio(jsonb) to authenticated;

-- El contexto de la sesión lleva el logo para mostrarlo arriba en la app.
create or replace function public.mi_contexto()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_rol     text := privado.mi_rol();
  v_datos   jsonb;
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;

  select jsonb_build_object(
           'empresa_id',         e.id,
           'nombre',             coalesce(e.nombre_comercial, e.razon_social),
           'logo',               e.logo,
           'regimen',            e.regimen,
           'rol',                v_rol,
           've_costos',          (v_rol = 'DUENO' or e.vendedor_ve_costos),
           'precios_incluyen_iva', e.precios_incluyen_iva
         )
    into v_datos
  from public.empresas e
  where e.id = v_empresa;

  return privado.ok(v_datos);
end;
$$;
