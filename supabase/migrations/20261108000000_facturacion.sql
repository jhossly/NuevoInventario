-- =============================================================================
-- Facturación electrónica desde la app (MVP-2, D-053)
--
-- La base genera el comprobante y reparte la numeración; la función de servidor
-- `facturar` lo firma con el .p12 y lo envía al SRI. La venta se guarda primero:
-- si el SRI no responde, la factura queda pendiente y se reintenta con la misma
-- clave de acceso.
--
-- Arranca apagada y en el ambiente de pruebas: pasar a producción es una
-- decisión explícita del Dueño.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Configuración
-- -----------------------------------------------------------------------------
alter table public.empresas
  add column facturacion_activa    boolean not null default false,
  add column ambiente_sri          text not null default '1',
  add column establecimiento       text not null default '001',
  add column punto_emision         text not null default '001',
  add column obligado_contabilidad boolean not null default false,
  add column leyenda_rimpe         text default 'CONTRIBUYENTE NEGOCIO POPULAR - RÉGIMEN RIMPE',
  add constraint empresas_ambiente_sri check (ambiente_sri in ('1', '2')),
  add constraint empresas_establecimiento check (establecimiento ~ '^[0-9]{3}$' and establecimiento <> '000'),
  add constraint empresas_punto_emision check (punto_emision ~ '^[0-9]{3}$' and punto_emision <> '000');

-- Último número usado por ambiente y punto de emisión. Las pruebas no gastan
-- los números de producción.
create table public.secuencias_factura (
  empresa_id  uuid not null references public.empresas (id) on delete restrict,
  ambiente    text not null,
  estab       text not null,
  pto_emi     text not null,
  ultimo      int not null default 0,
  primary key (empresa_id, ambiente, estab, pto_emi),
  constraint secuencias_factura_ultimo check (ultimo between 0 and 999999999)
);

create table public.facturas_electronicas (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references public.empresas (id) on delete restrict,
  venta_id            uuid not null references public.ventas (id) on delete restrict,
  ambiente            text not null,
  estab               text not null,
  pto_emi             text not null,
  secuencial          int not null,
  numero              text not null,
  clave_acceso        text not null,
  fecha_emision       date not null,
  estado              text not null default 'PENDIENTE',
  xml                 text not null,
  xml_firmado         text,
  numero_autorizacion text,
  fecha_autorizacion  timestamptz,
  mensajes            jsonb not null default '[]',
  intentos            int not null default 0,
  creado_en           timestamptz not null default now(),
  creado_por          uuid,
  actualizado_en      timestamptz not null default now(),
  constraint facturas_electronicas_clave_unica unique (clave_acceso),
  constraint facturas_electronicas_venta_unica unique (venta_id, ambiente),
  constraint facturas_electronicas_numero_unico unique (empresa_id, ambiente, estab, pto_emi, secuencial),
  constraint facturas_electronicas_estado check (
    estado in ('PENDIENTE', 'RECIBIDA', 'DEVUELTA', 'NO_AUTORIZADA', 'AUTORIZADA')),
  constraint facturas_electronicas_autorizada check (estado <> 'AUTORIZADA' or numero_autorizacion is not null)
);
create index facturas_electronicas_venta_idx on public.facturas_electronicas (venta_id);

-- Una factura autorizada es un documento legal: no cambia ni se borra.
create function privado.factura_cambios_permitidos()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or old.estado = 'AUTORIZADA' then
    raise exception 'Una factura electrónica no se cambia ni se borra' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger facturas_electronicas_cambios before update or delete on public.facturas_electronicas
  for each row execute function privado.factura_cambios_permitidos();

revoke all on public.secuencias_factura, public.facturas_electronicas from anon, authenticated;
grant select on public.secuencias_factura, public.facturas_electronicas to authenticated;
alter table public.secuencias_factura enable row level security;
alter table public.facturas_electronicas enable row level security;

create policy secuencias_factura_lectura on public.secuencias_factura
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');
-- El Vendedor ve las de sus ventas, igual que las ventas (D-028).
create policy facturas_electronicas_lectura on public.facturas_electronicas
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa())
         and ((select privado.mi_rol()) = 'DUENO'
              or exists (select 1 from public.ventas v where v.id = venta_id and v.creado_por = auth.uid())));

-- -----------------------------------------------------------------------------
-- 2. Generar el comprobante
-- -----------------------------------------------------------------------------
create function privado.xml_esc(p_texto text)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(p_texto, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

-- p_lado: dinero con 2 decimales; cantidades y precios unitarios llevan 6.
create function privado.xml_num(p_valor numeric, p_decimales int default 2)
returns text
language sql
immutable
set search_path = ''
as $$
  select trim(to_char(round(p_valor, p_decimales), 'FM999999999990.' || repeat('0', p_decimales)));
$$;

create function privado.xml_tag(p_nombre text, p_valor text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when nullif(trim(p_valor), '') is null then ''
              else '<' || p_nombre || '>' || privado.xml_esc(trim(p_valor)) || '</' || p_nombre || '>' end;
$$;

-- Medios del sistema → tabla 24 de la ficha técnica. Fiado va como 01 (sin
-- sistema financiero) hasta que el contador indique otra cosa.
create function privado.forma_pago_sri(p_medio text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_medio when 'TRANSFERENCIA' then '20' when 'TARJETA' then '19' else '01' end;
$$;

-- El XML va en una sola línea y sin etiquetas vacías: así ya está canonizado
-- para la firma (supabase/functions/facturar/firma.ts).
create function privado.xml_factura(
  p_empresa public.empresas, p_venta public.ventas, p_clave text, p_secuencial int, p_ambiente text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_cliente   public.clientes;
  v_tipo      text := '07';
  v_id        text := '9999999999999';
  v_nombre    text := 'CONSUMIDOR FINAL';
  v_detalles  text;
  v_impuestos text;
  v_pagos     text;
  v_adicional text;
begin
  if p_venta.cliente_id is not null then
    select * into v_cliente from public.clientes c where c.id = p_venta.cliente_id;
    if v_cliente.identificacion is not null then
      v_tipo   := case v_cliente.tipo_identificacion when 'RUC' then '04' when 'CEDULA' then '05' else '06' end;
      v_id     := v_cliente.identificacion;
      v_nombre := v_cliente.nombre;
    end if;
  end if;

  select string_agg(
           '<detalle>' ||
           privado.xml_tag('codigoPrincipal', coalesce(p.codigo_principal, r.codigo_barras, left(replace(p.id::text, '-', ''), 25))) ||
           privado.xml_tag('codigoAuxiliar', p.codigo_auxiliar) ||
           privado.xml_tag('descripcion', left(p.nombre || case when r.factor <> 1 then ' - ' || r.nombre else '' end, 300)) ||
           '<cantidad>' || privado.xml_num(d.cantidad, 6) || '</cantidad>' ||
           '<precioUnitario>' || privado.xml_num(d.subtotal / d.cantidad, 6) || '</precioUnitario>' ||
           '<descuento>' || privado.xml_num(d.descuento) || '</descuento>' ||
           '<precioTotalSinImpuesto>' || privado.xml_num(d.subtotal - d.descuento) || '</precioTotalSinImpuesto>' ||
           '<impuestos><impuesto><codigo>2</codigo><codigoPorcentaje>' || d.codigo_iva || '</codigoPorcentaje>' ||
           '<tarifa>' || privado.xml_num(d.tarifa_iva) || '</tarifa>' ||
           '<baseImponible>' || privado.xml_num(d.subtotal - d.descuento) || '</baseImponible>' ||
           '<valor>' || privado.xml_num(d.iva) || '</valor></impuesto></impuestos></detalle>',
           '' order by d.orden)
    into v_detalles
    from public.venta_detalles d
    join public.presentaciones r on r.id = d.presentacion_id
    join public.productos p on p.id = d.producto_id
   where d.venta_id = p_venta.id;

  select string_agg(
           '<totalImpuesto><codigo>2</codigo><codigoPorcentaje>' || t.codigo_iva || '</codigoPorcentaje>' ||
           '<baseImponible>' || privado.xml_num(t.base) || '</baseImponible>' ||
           '<valor>' || privado.xml_num(t.iva) || '</valor></totalImpuesto>',
           '' order by t.codigo_iva)
    into v_impuestos
    from (select d.codigo_iva, sum(d.subtotal - d.descuento) as base, sum(d.iva) as iva
            from public.venta_detalles d where d.venta_id = p_venta.id group by d.codigo_iva) t;

  select string_agg(
           '<pago><formaPago>' || x.forma || '</formaPago><total>' || privado.xml_num(x.monto) || '</total></pago>',
           '' order by x.forma)
    into v_pagos
    from (select privado.forma_pago_sri(g.medio) as forma, sum(g.monto) as monto
            from public.venta_pagos g where g.venta_id = p_venta.id group by 1) x;

  v_adicional := case when v_cliente.correo is not null then
                   '<campoAdicional nombre="Email">' || privado.xml_esc(v_cliente.correo) || '</campoAdicional>' else '' end ||
                 case when v_cliente.telefono is not null then
                   '<campoAdicional nombre="Telefono">' || privado.xml_esc(v_cliente.telefono) || '</campoAdicional>' else '' end;

  return '<?xml version="1.0" encoding="UTF-8"?><factura id="comprobante" version="1.1.0"><infoTributaria>' ||
    '<ambiente>' || p_ambiente || '</ambiente><tipoEmision>1</tipoEmision>' ||
    privado.xml_tag('razonSocial', p_empresa.razon_social) ||
    privado.xml_tag('nombreComercial', p_empresa.nombre_comercial) ||
    '<ruc>' || p_empresa.ruc || '</ruc><claveAcceso>' || p_clave || '</claveAcceso><codDoc>01</codDoc>' ||
    '<estab>' || p_empresa.establecimiento || '</estab><ptoEmi>' || p_empresa.punto_emision || '</ptoEmi>' ||
    '<secuencial>' || lpad(p_secuencial::text, 9, '0') || '</secuencial>' ||
    privado.xml_tag('dirMatriz', p_empresa.direccion) ||
    privado.xml_tag('contribuyenteRimpe', p_empresa.leyenda_rimpe) ||
    '</infoTributaria><infoFactura>' ||
    '<fechaEmision>' || to_char(p_venta.fecha, 'DD/MM/YYYY') || '</fechaEmision>' ||
    privado.xml_tag('dirEstablecimiento', p_empresa.direccion) ||
    '<obligadoContabilidad>' || case when p_empresa.obligado_contabilidad then 'SI' else 'NO' end || '</obligadoContabilidad>' ||
    '<tipoIdentificacionComprador>' || v_tipo || '</tipoIdentificacionComprador>' ||
    privado.xml_tag('razonSocialComprador', v_nombre) ||
    '<identificacionComprador>' || v_id || '</identificacionComprador>' ||
    privado.xml_tag('direccionComprador', v_cliente.direccion) ||
    '<totalSinImpuestos>' || privado.xml_num(p_venta.subtotal - p_venta.descuento) || '</totalSinImpuestos>' ||
    '<totalDescuento>' || privado.xml_num(p_venta.descuento) || '</totalDescuento>' ||
    '<totalConImpuestos>' || v_impuestos || '</totalConImpuestos>' ||
    '<propina>0.00</propina><importeTotal>' || privado.xml_num(p_venta.total) || '</importeTotal>' ||
    '<moneda>DOLAR</moneda><pagos>' || v_pagos || '</pagos></infoFactura>' ||
    '<detalles>' || v_detalles || '</detalles>' ||
    case when v_adicional <> '' then '<infoAdicional>' || v_adicional || '</infoAdicional>' else '' end ||
    '</factura>';
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Preparar y registrar
-- -----------------------------------------------------------------------------
-- Devuelve la factura de la venta, creándola si hace falta. Repetir la llamada
-- nunca gasta otro número. Si el SRI la devolvió o rechazó, regenera el XML
-- (con la misma clave) para volver a enviarla con los datos corregidos.
create function public.preparar_factura(p_venta_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol        text := privado.mi_rol();
  v_empresa    public.empresas;
  v_venta      public.ventas;
  v_factura    public.facturas_electronicas;
  v_secuencial int;
  v_base_clave text;
  v_clave      text;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null then
    return privado.error('SIN_PERMISO');
  end if;

  select * into v_venta from public.ventas v
   where v.id = p_venta_id and v.empresa_id = v_empresa.id
     and (v_rol = 'DUENO' or v.creado_por = auth.uid());
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La venta no existe');
  end if;
  if not v_empresa.facturacion_activa then
    return privado.error('DATOS_INVALIDOS', 'La facturación electrónica no está activa: actívala en Mi negocio');
  end if;
  if v_venta.tipo_comprobante <> 'FACTURA' then
    return privado.error('DATOS_INVALIDOS', 'Esta venta no se registró como factura');
  end if;
  if v_venta.estado <> 'CONFIRMADA' then
    return privado.error('DATOS_INVALIDOS', 'La venta está anulada');
  end if;
  if exists (select 1 from public.comprobantes c where c.venta_id = v_venta.id) then
    return privado.error('DATOS_INVALIDOS', 'Esta venta ya tiene una factura del portal del SRI');
  end if;
  if length(trim(v_empresa.razon_social)) = 0 or v_empresa.direccion is null then
    return privado.error('DATOS_INVALIDOS', 'Completa la razón social y la dirección en Mi negocio');
  end if;

  -- Bloquea la venta: dos «Emitir» a la vez no gastan dos números.
  perform 1 from public.ventas v where v.id = v_venta.id for update;

  select * into v_factura from public.facturas_electronicas f
   where f.venta_id = v_venta.id and f.ambiente = v_empresa.ambiente_sri;

  if found then
    if v_factura.estado in ('DEVUELTA', 'NO_AUTORIZADA') then
      update public.facturas_electronicas f
         set xml = privado.xml_factura(v_empresa, v_venta, f.clave_acceso, f.secuencial, f.ambiente),
             xml_firmado = null, estado = 'PENDIENTE', actualizado_en = now()
       where f.id = v_factura.id
      returning * into v_factura;
    end if;
  else
    insert into public.secuencias_factura as s (empresa_id, ambiente, estab, pto_emi, ultimo)
    values (v_empresa.id, v_empresa.ambiente_sri, v_empresa.establecimiento, v_empresa.punto_emision, 1)
    on conflict (empresa_id, ambiente, estab, pto_emi) do update set ultimo = s.ultimo + 1
    returning s.ultimo into v_secuencial;

    v_base_clave := to_char(v_venta.fecha, 'DDMMYYYY') || '01' || v_empresa.ruc || v_empresa.ambiente_sri ||
                    v_empresa.establecimiento || v_empresa.punto_emision || lpad(v_secuencial::text, 9, '0') ||
                    lpad(floor(random() * 100000000)::int::text, 8, '0') || '1';
    v_clave := v_base_clave || privado.digito_clave_acceso(v_base_clave);

    insert into public.facturas_electronicas (
      empresa_id, venta_id, ambiente, estab, pto_emi, secuencial, numero, clave_acceso, fecha_emision, xml, creado_por)
    values (
      v_empresa.id, v_venta.id, v_empresa.ambiente_sri, v_empresa.establecimiento, v_empresa.punto_emision, v_secuencial,
      v_empresa.establecimiento || '-' || v_empresa.punto_emision || '-' || lpad(v_secuencial::text, 9, '0'),
      v_clave, v_venta.fecha,
      privado.xml_factura(v_empresa, v_venta, v_clave, v_secuencial, v_empresa.ambiente_sri), auth.uid())
    returning * into v_factura;
  end if;

  return privado.ok(jsonb_build_object(
    'id', v_factura.id, 'clave_acceso', v_factura.clave_acceso, 'ambiente', v_factura.ambiente,
    'numero', v_factura.numero, 'estado', v_factura.estado, 'xml', v_factura.xml, 'xml_firmado', v_factura.xml_firmado));
end;
$$;

-- Solo la función de servidor (service_role): el navegador no decide si el SRI
-- autorizó. Claves: estado, xml_firmado, numero_autorizacion, fecha_autorizacion, mensajes.
create function public.registrar_resultado_factura(p_id uuid, p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.facturas_electronicas f set
    estado              = coalesce(p_datos ->> 'estado', f.estado),
    xml_firmado         = coalesce(p_datos ->> 'xml_firmado', f.xml_firmado),
    numero_autorizacion = coalesce(p_datos ->> 'numero_autorizacion', f.numero_autorizacion),
    fecha_autorizacion  = coalesce((p_datos ->> 'fecha_autorizacion')::timestamptz, f.fecha_autorizacion),
    mensajes            = coalesce(p_datos -> 'mensajes', f.mensajes),
    intentos            = f.intentos + 1,
    actualizado_en      = now()
   where f.id = p_id;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La factura no existe');
  end if;
  return privado.ok(jsonb_build_object('id', p_id));
end;
$$;

-- Una venta con factura autorizada se anula primero en el SRI: se avisa en la
-- pantalla; aquí solo se deja constancia de que sigue autorizada.

-- Configuración, solo Dueño. Claves: facturacion_activa, ambiente_sri,
-- establecimiento, punto_emision, obligado_contabilidad, leyenda_rimpe y
-- ultimo_secuencial (último número ya usado en este punto y ambiente).
create function public.guardar_facturacion(p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_nueva   public.empresas;
  v_ultimo  int;
  v_detalle text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if jsonb_typeof(p_datos) is distinct from 'object' then
    return privado.error('DATOS_INVALIDOS');
  end if;

  update public.empresas e set
    facturacion_activa = case when p_datos ? 'facturacion_activa' then (p_datos ->> 'facturacion_activa')::boolean else e.facturacion_activa end,
    ambiente_sri = case when p_datos ? 'ambiente_sri' then p_datos ->> 'ambiente_sri' else e.ambiente_sri end,
    establecimiento = case when p_datos ? 'establecimiento' then p_datos ->> 'establecimiento' else e.establecimiento end,
    punto_emision = case when p_datos ? 'punto_emision' then p_datos ->> 'punto_emision' else e.punto_emision end,
    obligado_contabilidad = case when p_datos ? 'obligado_contabilidad' then (p_datos ->> 'obligado_contabilidad')::boolean else e.obligado_contabilidad end,
    leyenda_rimpe = case when p_datos ? 'leyenda_rimpe' then nullif(trim(p_datos ->> 'leyenda_rimpe'), '') else e.leyenda_rimpe end
   where e.id = v_empresa
  returning * into v_nueva;

  if p_datos ? 'ultimo_secuencial' then
    v_ultimo := (p_datos ->> 'ultimo_secuencial')::int;
    if exists (select 1 from public.facturas_electronicas f
                where f.empresa_id = v_empresa and f.ambiente = v_nueva.ambiente_sri
                  and f.estab = v_nueva.establecimiento and f.pto_emi = v_nueva.punto_emision
                  and f.secuencial > v_ultimo) then
      return privado.error('DATOS_INVALIDOS', 'Ya hay facturas con un número mayor');
    end if;
    insert into public.secuencias_factura as s (empresa_id, ambiente, estab, pto_emi, ultimo)
    values (v_empresa, v_nueva.ambiente_sri, v_nueva.establecimiento, v_nueva.punto_emision, v_ultimo)
    on conflict (empresa_id, ambiente, estab, pto_emi) do update set ultimo = excluded.ultimo;
  end if;

  insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, despues)
  values (v_empresa, auth.uid(), 'FACTURACION_CONFIGURADA', 'empresas', v_empresa, p_datos);

  return privado.ok(jsonb_build_object('id', v_empresa));
exception
  when check_violation or invalid_text_representation or numeric_value_out_of_range then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS',
      case v_detalle
        when 'empresas_establecimiento' then 'El establecimiento lleva 3 dígitos'
        when 'empresas_punto_emision' then 'El punto de emisión lleva 3 dígitos'
        when 'secuencias_factura_ultimo' then 'El número no es válido'
        else 'Revisa los datos' end);
end;
$$;

-- El contexto de la sesión dice si se factura desde la app.
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
           'precios_incluyen_iva', e.precios_incluyen_iva,
           'facturacion_activa', e.facturacion_activa,
           'ambiente_sri',       e.ambiente_sri
         )
    into v_datos
  from public.empresas e
  where e.id = v_empresa;

  return privado.ok(v_datos);
end;
$$;

revoke all on function
  privado.factura_cambios_permitidos(),
  privado.xml_esc(text),
  privado.xml_num(numeric, int),
  privado.xml_tag(text, text),
  privado.forma_pago_sri(text),
  privado.xml_factura(public.empresas, public.ventas, text, int, text)
  from public, anon, authenticated;

revoke all on function
  public.preparar_factura(uuid),
  public.registrar_resultado_factura(uuid, jsonb),
  public.guardar_facturacion(jsonb)
  from public, anon, authenticated;
grant execute on function public.preparar_factura(uuid), public.guardar_facturacion(jsonb) to authenticated;
grant execute on function public.registrar_resultado_factura(uuid, jsonb) to service_role;
