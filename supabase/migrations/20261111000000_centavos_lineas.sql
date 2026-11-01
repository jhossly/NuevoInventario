-- =============================================================================
-- Centavo de redondeo entre las líneas y el subtotal de una factura (D-056)
--
-- En facturas del SRI versión 2.1.0 la suma de las líneas puede diferir del
-- subtotal por redondeo, y aun así están autorizadas. Antes se rechazaban.
-- =============================================================================

create or replace function public.importar_comprobante(p_xml text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa    public.empresas;
  v_doc        xml;
  v_fac        xml;
  v_estado     text;
  v_autoriz    text;
  v_clave      text;
  v_ruc        text;
  v_cod_doc    text;
  v_ambiente   text;
  v_fecha      date;
  v_numero     text;
  v_existente  public.comprobantes;
  v_id         uuid := gen_random_uuid();
  v_detalle    xml;
  v_orden      int := 0;
  v_lineas     jsonb := '[]';
  v_base_tot   numeric;
  v_desc_tot   numeric;
  v_iva        numeric;
  v_total      numeric;
  v_dif_iva    numeric;
  v_pagos      jsonb;
  v_pagado     numeric;
  v_sin_asociar int;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_xml is null or length(p_xml) > 500000 then
    return privado.error('DATOS_INVALIDOS', 'El archivo está vacío o es demasiado grande');
  end if;
  if p_xml ~* '<!DOCTYPE' then
    return privado.error('DATOS_INVALIDOS', 'El archivo no es un XML del SRI');
  end if;

  -- Sobre de autorización (lo que descarga el portal) o factura sola.
  begin
    v_doc := xmlparse(document ltrim(p_xml, E'﻿ \t\r\n'));
    if xpath_exists('/autorizacion', v_doc) then
      v_estado  := privado.xml_texto(v_doc, '/autorizacion/estado');
      v_autoriz := privado.xml_texto(v_doc, '/autorizacion/numeroAutorizacion');
      if v_estado is distinct from 'AUTORIZADO' then
        return privado.error('DATOS_INVALIDOS', 'El comprobante no está autorizado por el SRI');
      end if;
      v_fac := xmlparse(document privado.xml_interno((xpath('/autorizacion/comprobante/text()', v_doc))[1]::text));
    else
      v_fac := v_doc;
    end if;
  exception
    when others then
      return privado.error('DATOS_INVALIDOS', 'El archivo no es un XML válido');
  end;

  if not xpath_exists('/factura', v_fac) then
    return privado.error('DATOS_INVALIDOS', 'Solo se importan facturas');
  end if;

  v_clave    := privado.xml_texto(v_fac, '/factura/infoTributaria/claveAcceso');
  v_ruc      := privado.xml_texto(v_fac, '/factura/infoTributaria/ruc');
  v_cod_doc  := privado.xml_texto(v_fac, '/factura/infoTributaria/codDoc');
  v_ambiente := privado.xml_texto(v_fac, '/factura/infoTributaria/ambiente');
  v_numero   := concat_ws('-', privado.xml_texto(v_fac, '/factura/infoTributaria/estab'),
                               privado.xml_texto(v_fac, '/factura/infoTributaria/ptoEmi'),
                               privado.xml_texto(v_fac, '/factura/infoTributaria/secuencial'));
  begin
    v_fecha := to_date(privado.xml_texto(v_fac, '/factura/infoFactura/fechaEmision'), 'DD/MM/YYYY');
  exception when others then
    v_fecha := null;
  end;

  -- Validaciones de identidad del documento
  if v_clave is null or v_clave !~ '^[0-9]{49}$'
     or privado.digito_clave_acceso(left(v_clave, 48)) <> right(v_clave, 1)::int then
    return privado.error('DATOS_INVALIDOS', 'La clave de acceso no es válida');
  end if;
  if v_ruc is distinct from v_empresa.ruc or substr(v_clave, 11, 13) <> v_ruc then
    return privado.error('DATOS_INVALIDOS', 'La factura no es de esta bodega (otro RUC)');
  end if;
  if v_cod_doc is distinct from '01' then
    return privado.error('DATOS_INVALIDOS', 'Solo se importan facturas');
  end if;
  if v_ambiente is distinct from '2' then
    return privado.error('DATOS_INVALIDOS', 'La factura es del ambiente de pruebas del SRI');
  end if;
  if v_fecha is null or to_char(v_fecha, 'DDMMYYYY') <> left(v_clave, 8) then
    return privado.error('DATOS_INVALIDOS', 'La fecha de emisión no coincide con la clave de acceso');
  end if;

  select * into v_existente from public.comprobantes c
   where c.empresa_id = v_empresa.id and c.clave_acceso = v_clave;
  if found then
    return privado.ok(jsonb_build_object('comprobante_id', v_existente.id, 'repetido', true));
  end if;

  -- Totales de la cabecera
  begin
    v_base_tot := privado.xml_numero(v_fac, '/factura/infoFactura/totalSinImpuestos');
    v_desc_tot := coalesce(privado.xml_numero(v_fac, '/factura/infoFactura/totalDescuento'), 0);
    v_total    := privado.xml_numero(v_fac, '/factura/infoFactura/importeTotal');
    select coalesce(sum(privado.xml_numero(t, '/*/valor')), 0) into v_iva
      from unnest(xpath('/factura/infoFactura/totalConImpuestos/totalImpuesto[codigo="2"]', v_fac)) t;
  exception when others then
    return privado.error('DATOS_INVALIDOS', 'Los totales del XML no son números');
  end;
  if v_base_tot is null or v_total is null or round(v_base_tot + v_iva, 2) <> round(v_total, 2) then
    return privado.error('DATOS_INVALIDOS',
      'El total no es la base más el IVA (¿propina u otro impuesto?): esta factura no se puede importar');
  end if;

  -- Líneas
  begin
    for v_detalle in select unnest(xpath('/factura/detalles/detalle', v_fac)) loop
      v_orden := v_orden + 1;
      v_lineas := v_lineas || jsonb_build_array(jsonb_build_object(
        'orden',           v_orden,
        'codigo',          coalesce(privado.xml_texto(v_detalle, '/*/codigoPrincipal'), privado.xml_texto(v_detalle, '/*/codigoAuxiliar')),
        'descripcion',     coalesce(privado.xml_texto(v_detalle, '/*/descripcion'), 'Sin descripción'),
        'cantidad',        privado.xml_numero(v_detalle, '/*/cantidad'),
        'precio_unitario', privado.xml_numero(v_detalle, '/*/precioUnitario'),
        'descuento',       coalesce(privado.xml_numero(v_detalle, '/*/descuento'), 0),
        'base',            privado.xml_numero(v_detalle, '/*/precioTotalSinImpuesto'),
        'tarifa_iva',      coalesce((select privado.xml_numero(i, '/*/tarifa')
                                       from unnest(xpath('/*/impuestos/impuesto[codigo="2"]', v_detalle)) i limit 1), 0),
        'iva',             coalesce((select sum(privado.xml_numero(i, '/*/valor'))
                                       from unnest(xpath('/*/impuestos/impuesto[codigo="2"]', v_detalle)) i), 0)));
    end loop;
  exception when others then
    return privado.error('DATOS_INVALIDOS', 'Las líneas del XML no se pueden leer');
  end;
  if v_orden = 0 then
    return privado.error('DATOS_INVALIDOS', 'La factura no tiene líneas');
  end if;
  -- Con la versión 2.1.0 el SRI redondea cada línea y el total por separado: hasta
  -- $0,05 de diferencia van a la línea más grande, como el IVA (D-042).
  v_dif_iva := round(v_base_tot, 2) - (select round(sum((l ->> 'base')::numeric), 2) from jsonb_array_elements(v_lineas) l);
  if abs(v_dif_iva) > 0.05 then
    return privado.error('DATOS_INVALIDOS', 'Las líneas no suman la base de la factura');
  end if;
  if v_dif_iva <> 0 then
    select jsonb_agg(case when (l ->> 'orden')::int = m.orden
                          then jsonb_set(l, '{base}', to_jsonb((l ->> 'base')::numeric + v_dif_iva))
                          else l end order by (l ->> 'orden')::int)
      into v_lineas
      from jsonb_array_elements(v_lineas) l,
           (select (x ->> 'orden')::int as orden from jsonb_array_elements(v_lineas) x
             order by (x ->> 'base')::numeric desc limit 1) m;
  end if;

  -- El SRI calcula el IVA sobre la base total por tarifa; la suma por línea
  -- puede diferir en centavos. La diferencia (hasta $0,05) va a la línea
  -- gravada más grande, para que las líneas cuadren con la cabecera (D-042).
  v_dif_iva := round(v_iva, 2) - (select round(sum((l ->> 'iva')::numeric), 2) from jsonb_array_elements(v_lineas) l);
  if abs(v_dif_iva) > 0.05 then
    return privado.error('DATOS_INVALIDOS', 'El IVA de las líneas no cuadra con el de la factura');
  end if;
  if v_dif_iva <> 0 then
    select jsonb_agg(case when (l ->> 'orden')::int = m.orden
                          then jsonb_set(l, '{iva}', to_jsonb((l ->> 'iva')::numeric + v_dif_iva))
                          else l end order by (l ->> 'orden')::int)
      into v_lineas
      from jsonb_array_elements(v_lineas) l,
           (select (x ->> 'orden')::int as orden from jsonb_array_elements(v_lineas) x
             where (x ->> 'tarifa_iva')::numeric > 0
             order by (x ->> 'base')::numeric desc limit 1) m;
    if v_lineas is null then
      return privado.error('DATOS_INVALIDOS', 'El IVA de las líneas no cuadra con el de la factura');
    end if;
  end if;

  -- Pagos: formaPago del SRI → medio del sistema (01 = sin sistema financiero).
  select coalesce(jsonb_agg(jsonb_build_object(
           'medio', case privado.xml_texto(p, '/*/formaPago')
                      when '01' then 'EFECTIVO'
                      when '16' then 'TARJETA' when '19' then 'TARJETA'
                      else 'TRANSFERENCIA' end,
           'monto', round(privado.xml_numero(p, '/*/total'), 2))), '[]'::jsonb)
    into v_pagos
    from unnest(xpath('/factura/infoFactura/pagos/pago', v_fac)) p;
  select coalesce(sum((p ->> 'monto')::numeric), 0) into v_pagado from jsonb_array_elements(v_pagos) p;
  if jsonb_array_length(v_pagos) = 0 or v_pagado <> round(v_total, 2) then
    v_pagos := jsonb_build_array(jsonb_build_object('medio', 'EFECTIVO', 'monto', round(v_total, 2)));
  end if;

  insert into public.comprobantes (id, empresa_id, clave_acceso, tipo, numero, fecha_emision, ambiente,
                                   numero_autorizacion, tipo_identificacion_comprador, identificacion_comprador,
                                   razon_social_comprador, subtotal, descuento, iva, total, pagos, xml, creado_por)
  values (v_id, v_empresa.id, v_clave, v_cod_doc, v_numero, v_fecha, v_ambiente, coalesce(v_autoriz, v_clave),
          privado.xml_texto(v_fac, '/factura/infoFactura/tipoIdentificacionComprador'),
          privado.xml_texto(v_fac, '/factura/infoFactura/identificacionComprador'),
          privado.xml_texto(v_fac, '/factura/infoFactura/razonSocialComprador'),
          round(v_base_tot + v_desc_tot, 2), round(v_desc_tot, 2), round(v_iva, 2), round(v_total, 2),
          v_pagos, p_xml, auth.uid());

  -- Asociación automática: memoria de códigos, luego código de barras.
  insert into public.comprobante_lineas (empresa_id, comprobante_id, orden, codigo, descripcion, cantidad,
                                         precio_unitario, descuento, base, tarifa_iva, iva, presentacion_id)
  select v_empresa.id, v_id, (l ->> 'orden')::int, l ->> 'codigo', l ->> 'descripcion',
         (l ->> 'cantidad')::numeric, (l ->> 'precio_unitario')::numeric, (l ->> 'descuento')::numeric,
         (l ->> 'base')::numeric, (l ->> 'tarifa_iva')::numeric, (l ->> 'iva')::numeric,
         coalesce(
           (select s.presentacion_id from public.codigos_sri s
             where s.empresa_id = v_empresa.id and s.codigo = l ->> 'codigo'),
           (select r.id from public.presentaciones r
             where r.empresa_id = v_empresa.id and r.codigo_barras = l ->> 'codigo' and r.activo))
    from jsonb_array_elements(v_lineas) l;

  select count(*) into v_sin_asociar from public.comprobante_lineas
   where comprobante_id = v_id and presentacion_id is null;

  return privado.ok(jsonb_build_object('comprobante_id', v_id, 'repetido', false,
                                       'lineas', v_orden, 'sin_asociar', v_sin_asociar,
                                       'numero', v_numero, 'total', round(v_total, 2)::text));
exception
  when unique_violation then
    select * into v_existente from public.comprobantes c
     where c.empresa_id = v_empresa.id and c.clave_acceso = v_clave;
    return privado.ok(jsonb_build_object('comprobante_id', v_existente.id, 'repetido', true));
  when invalid_text_representation or numeric_value_out_of_range or check_violation then
    return privado.error('DATOS_INVALIDOS', 'El XML tiene datos que no se pueden guardar');
end;
$$;

create or replace function privado.leer_xml_proveedor(p_empresa public.empresas, p_xml text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_doc      xml;
  v_fac      xml;
  v_clave    text;
  v_ruc      text;
  v_comprador text;
  v_fecha    date;
  v_detalle  xml;
  v_orden    int := 0;
  v_lineas   jsonb := '[]';
  v_iva      numeric;
  v_base     numeric;
  v_total    numeric;
  v_dif      numeric;
  v_suma     numeric;
begin
  if p_xml is null or length(p_xml) > 1000000 then
    perform privado.fallar('DATOS_INVALIDOS', 'El archivo está vacío o es demasiado grande');
  end if;
  if p_xml ~* '<!DOCTYPE' then
    perform privado.fallar('DATOS_INVALIDOS', 'El archivo no es un XML del SRI');
  end if;

  begin
    v_doc := xmlparse(document ltrim(p_xml, E'﻿ \t\r\n'));
    if xpath_exists('/autorizacion', v_doc) then
      if privado.xml_texto(v_doc, '/autorizacion/estado') is distinct from 'AUTORIZADO' then
        perform privado.fallar('DATOS_INVALIDOS', 'El comprobante no está autorizado por el SRI');
      end if;
      v_fac := xmlparse(document privado.xml_interno((xpath('/autorizacion/comprobante/text()', v_doc))[1]::text));
    else
      v_fac := v_doc;
    end if;
  exception
    when sqlstate 'NG001' then raise;
    when others then
      perform privado.fallar('DATOS_INVALIDOS', 'El archivo no es un XML válido');
  end;

  if not xpath_exists('/factura', v_fac)
     or privado.xml_texto(v_fac, '/factura/infoTributaria/codDoc') is distinct from '01' then
    perform privado.fallar('DATOS_INVALIDOS', 'Solo se importan facturas');
  end if;

  v_clave     := privado.xml_texto(v_fac, '/factura/infoTributaria/claveAcceso');
  v_ruc       := privado.xml_texto(v_fac, '/factura/infoTributaria/ruc');
  v_comprador := privado.xml_texto(v_fac, '/factura/infoFactura/identificacionComprador');

  if v_clave is null or v_clave !~ '^[0-9]{49}$'
     or privado.digito_clave_acceso(left(v_clave, 48)) <> right(v_clave, 1)::int then
    perform privado.fallar('DATOS_INVALIDOS', 'La clave de acceso no es válida');
  end if;
  if privado.xml_texto(v_fac, '/factura/infoTributaria/ambiente') is distinct from '2' then
    perform privado.fallar('DATOS_INVALIDOS', 'La factura es del ambiente de pruebas del SRI');
  end if;
  if v_ruc = p_empresa.ruc then
    perform privado.fallar('DATOS_INVALIDOS', 'Esta factura la emitiste tú: súbela en Facturas SRI');
  end if;
  if v_comprador is distinct from p_empresa.ruc and v_comprador is distinct from left(p_empresa.ruc, 10) then
    perform privado.fallar('DATOS_INVALIDOS', 'La factura no está a nombre de esta bodega');
  end if;
  begin
    v_fecha := to_date(privado.xml_texto(v_fac, '/factura/infoFactura/fechaEmision'), 'DD/MM/YYYY');
  exception when others then
    v_fecha := null;
  end;
  if v_fecha is null or to_char(v_fecha, 'DDMMYYYY') <> left(v_clave, 8) then
    perform privado.fallar('DATOS_INVALIDOS', 'La fecha de emisión no coincide con la clave de acceso');
  end if;

  begin
    for v_detalle in select unnest(xpath('/factura/detalles/detalle', v_fac)) loop
      v_orden := v_orden + 1;
      v_lineas := v_lineas || jsonb_build_array(jsonb_build_object(
        'orden',            v_orden,
        'codigo',           coalesce(privado.xml_texto(v_detalle, '/*/codigoPrincipal'), privado.xml_texto(v_detalle, '/*/codigoAuxiliar')),
        'codigo_auxiliar',  privado.xml_texto(v_detalle, '/*/codigoAuxiliar'),
        'descripcion',      coalesce(privado.xml_texto(v_detalle, '/*/descripcion'), 'Sin descripción'),
        'cantidad',         privado.xml_numero(v_detalle, '/*/cantidad'),
        'precio_unitario',  privado.xml_numero(v_detalle, '/*/precioUnitario'),
        'descuento',        coalesce(privado.xml_numero(v_detalle, '/*/descuento'), 0),
        'base',             privado.xml_numero(v_detalle, '/*/precioTotalSinImpuesto'),
        'codigo_iva',       (select privado.xml_texto(i, '/*/codigoPorcentaje')
                               from unnest(xpath('/*/impuestos/impuesto[codigo="2"]', v_detalle)) i limit 1),
        'tarifa_iva',       coalesce((select privado.xml_numero(i, '/*/tarifa')
                                        from unnest(xpath('/*/impuestos/impuesto[codigo="2"]', v_detalle)) i limit 1), 0),
        'iva',              coalesce((select sum(privado.xml_numero(i, '/*/valor'))
                                        from unnest(xpath('/*/impuestos/impuesto[codigo="2"]', v_detalle)) i), 0),
        'otros_impuestos',  coalesce((select sum(privado.xml_numero(i, '/*/valor'))
                                        from unnest(xpath('/*/impuestos/impuesto[codigo!="2"]', v_detalle)) i), 0)));
    end loop;
    v_base  := privado.xml_numero(v_fac, '/factura/infoFactura/totalSinImpuestos');
    v_total := privado.xml_numero(v_fac, '/factura/infoFactura/importeTotal');
    select coalesce(sum(privado.xml_numero(t, '/*/valor')), 0) into v_iva
      from unnest(xpath('/factura/infoFactura/totalConImpuestos/totalImpuesto[codigo="2"]', v_fac)) t;
  exception
    when sqlstate 'NG001' then raise;
    when others then
      perform privado.fallar('DATOS_INVALIDOS', 'Las líneas del XML no se pueden leer');
  end;

  if v_orden = 0 then
    perform privado.fallar('DATOS_INVALIDOS', 'La factura no tiene líneas');
  end if;
  -- Con la versión 2.1.0 el SRI redondea cada línea y el total por separado: hasta
  -- $0,05 de diferencia van a la línea más grande, como el IVA (D-042).
  v_dif := round(v_base, 2) - (select round(sum((l ->> 'base')::numeric), 2) from jsonb_array_elements(v_lineas) l);
  if abs(v_dif) > 0.05 then
    perform privado.fallar('DATOS_INVALIDOS', 'Las líneas no suman la base de la factura');
  end if;
  if v_dif <> 0 then
    select jsonb_agg(case when (l ->> 'orden')::int = m.orden
                          then jsonb_set(l, '{base}', to_jsonb((l ->> 'base')::numeric + v_dif))
                          else l end order by (l ->> 'orden')::int)
      into v_lineas
      from jsonb_array_elements(v_lineas) l,
           (select (x ->> 'orden')::int as orden from jsonb_array_elements(v_lineas) x
             order by (x ->> 'base')::numeric desc limit 1) m;
  end if;

  -- El SRI calcula el IVA sobre el total por tarifa: los centavos que difieren
  -- van a la línea gravada más grande (D-042).
  v_dif := round(v_iva, 2) - (select round(sum((l ->> 'iva')::numeric), 2) from jsonb_array_elements(v_lineas) l);
  if abs(v_dif) > 0.05 then
    perform privado.fallar('DATOS_INVALIDOS', 'El IVA de las líneas no cuadra con el de la factura');
  end if;
  if v_dif <> 0 then
    select jsonb_agg(case when (l ->> 'orden')::int = m.orden
                          then jsonb_set(l, '{iva}', to_jsonb((l ->> 'iva')::numeric + v_dif))
                          else l end order by (l ->> 'orden')::int)
      into v_lineas
      from jsonb_array_elements(v_lineas) l,
           (select (x ->> 'orden')::int as orden from jsonb_array_elements(v_lineas) x
             where (x ->> 'tarifa_iva')::numeric > 0
             order by (x ->> 'base')::numeric desc limit 1) m;
    if v_lineas is null then
      perform privado.fallar('DATOS_INVALIDOS', 'El IVA de las líneas no cuadra con el de la factura');
    end if;
  end if;

  select sum((l ->> 'base')::numeric + (l ->> 'iva')::numeric + (l ->> 'otros_impuestos')::numeric) into v_suma
    from jsonb_array_elements(v_lineas) l;
  if abs(round(v_suma, 2) - round(v_total, 2)) > 0.05 then
    perform privado.fallar('DATOS_INVALIDOS', 'Los valores de la factura no suman su total');
  end if;

  return jsonb_build_object(
    'clave_acceso', v_clave,
    'ruc',          v_ruc,
    'razon_social', coalesce(privado.xml_texto(v_fac, '/factura/infoTributaria/razonSocial'), v_ruc),
    'numero',       concat_ws('-', privado.xml_texto(v_fac, '/factura/infoTributaria/estab'),
                                   privado.xml_texto(v_fac, '/factura/infoTributaria/ptoEmi'),
                                   privado.xml_texto(v_fac, '/factura/infoTributaria/secuencial')),
    'fecha',        v_fecha,
    'total',        round(v_total, 2),
    'lineas',       v_lineas);
end;
$$;
