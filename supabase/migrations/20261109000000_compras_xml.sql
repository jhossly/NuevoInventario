-- =============================================================================
-- Importar la factura del proveedor como compra (D-054)
--
-- `leer_factura_proveedor` no guarda nada: devuelve lo que trae el XML y qué
-- producto parece ser cada línea, para revisarlo en pantalla.
-- `registrar_compra_de_factura` vuelve a leer el XML: los montos nunca vienen
-- del navegador. Quien revisa solo dice qué producto es, cuánto llegó de verdad
-- y cuántas unidades trae cada bulto.
--
-- ICE e IRBPNR no son recuperables: van a `otros_impuestos` y suman al costo.
-- Si llega menos de lo facturado, la compra registra lo recibido y guarda el
-- total de la factura en `total_factura`, para ver la diferencia.
-- =============================================================================

alter table public.compras
  add column otros_impuestos numeric(12,2) not null default 0,
  add column clave_acceso    text,
  add column total_factura   numeric(12,2),
  add column xml             text,
  drop constraint compras_totales_cuadran,
  add constraint compras_totales_cuadran check (total = subtotal - descuento + iva + otros_impuestos);

create unique index compras_clave_acceso_unica on public.compras (empresa_id, clave_acceso)
  where clave_acceso is not null;

alter table public.compra_detalles
  add column otros_impuestos numeric(12,2) not null default 0,
  add column descripcion_factura text;

-- Memoria: el código de este proveedor es esta presentación.
create table public.codigos_proveedor (
  empresa_id       uuid not null references public.empresas (id) on delete restrict,
  proveedor_id     uuid not null references public.proveedores (id) on delete restrict,
  codigo           text not null,
  presentacion_id  uuid not null references public.presentaciones (id) on delete cascade,
  actualizado_en   timestamptz not null default now(),
  primary key (empresa_id, proveedor_id, codigo)
);

revoke all on public.codigos_proveedor from anon, authenticated;
grant select on public.codigos_proveedor to authenticated;
alter table public.codigos_proveedor enable row level security;
create policy codigos_proveedor_lectura on public.codigos_proveedor
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');

-- -----------------------------------------------------------------------------
-- Leer el XML
-- -----------------------------------------------------------------------------
-- Valida el documento y devuelve sus datos, con las líneas ya cuadradas contra
-- la cabecera. Falla con privado.fallar si no sirve para esta bodega.
create function privado.leer_xml_proveedor(p_empresa public.empresas, p_xml text)
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
  if (select round(sum((l ->> 'base')::numeric), 2) from jsonb_array_elements(v_lineas) l) <> round(v_base, 2) then
    perform privado.fallar('DATOS_INVALIDOS', 'Las líneas no suman la base de la factura');
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

-- Qué presentación parece ser una línea: lo recordado de este proveedor, luego
-- el código de barras, luego los códigos del producto.
create function privado.presentacion_de_linea(p_empresa uuid, p_proveedor uuid, p_linea jsonb)
returns uuid
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select c.presentacion_id from public.codigos_proveedor c
      join public.presentaciones r on r.id = c.presentacion_id and r.activo
     where c.empresa_id = p_empresa and c.proveedor_id = p_proveedor and c.codigo = p_linea ->> 'codigo'),
    (select r.id from public.presentaciones r
      where r.empresa_id = p_empresa and r.activo
        and r.codigo_barras in (p_linea ->> 'codigo', p_linea ->> 'codigo_auxiliar') limit 1),
    (select r.id from public.productos p
      join public.presentaciones r on r.producto_id = p.id and r.activo and r.factor = 1
     where p.empresa_id = p_empresa and p.activo
       and (p.codigo_principal in (p_linea ->> 'codigo', p_linea ->> 'codigo_auxiliar')
            or p.codigo_auxiliar in (p_linea ->> 'codigo', p_linea ->> 'codigo_auxiliar')) limit 1));
$$;

-- No guarda nada. Los importes viajan como texto (D-019).
create function public.leer_factura_proveedor(p_xml text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa   public.empresas;
  v_datos     jsonb;
  v_proveedor uuid;
  v_detalle   text;
  v_lineas    jsonb;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;

  v_datos := privado.leer_xml_proveedor(v_empresa, p_xml);

  select v.id into v_proveedor from public.proveedores v
   where v.empresa_id = v_empresa.id and v.identificacion = v_datos ->> 'ruc';

  if exists (select 1 from public.compras c
              where c.empresa_id = v_empresa.id and c.estado = 'CONFIRMADA'
                and (c.clave_acceso = v_datos ->> 'clave_acceso'
                     or (c.proveedor_id = v_proveedor
                         and c.numero_documento = privado.normalizar_documento(v_datos ->> 'numero')))) then
    return privado.error('DUPLICADO', 'Esta factura ya está registrada como compra');
  end if;

  select jsonb_agg(l || jsonb_build_object(
           'presentacion_id', r.id, 'producto_id', r.producto_id, 'factor', r.factor::text,
           'producto', p.nombre, 'presentacion', r.nombre, 'unidad_base', p.unidad_base)
         order by (l ->> 'orden')::int)
    into v_lineas
    from jsonb_array_elements(v_datos -> 'lineas') l
    left join public.presentaciones r on r.id = privado.presentacion_de_linea(v_empresa.id, v_proveedor, l)
    left join public.productos p on p.id = r.producto_id;

  return privado.ok(v_datos - 'lineas' || jsonb_build_object(
    'proveedor_id', v_proveedor,
    'lineas', (select jsonb_agg(l || jsonb_build_object(
                 'cantidad',        (l ->> 'cantidad'),
                 'precio_unitario', (l ->> 'precio_unitario'),
                 'descuento',       (l ->> 'descuento'),
                 'base',            (l ->> 'base'),
                 'tarifa_iva',      (l ->> 'tarifa_iva'),
                 'iva',             (l ->> 'iva'),
                 'otros_impuestos', (l ->> 'otros_impuestos')) order by (l ->> 'orden')::int)
                 from jsonb_array_elements(v_lineas) l),
    'total', v_datos ->> 'total'));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
end;
$$;

-- p_lineas: [{orden, cantidad_recibida, factor, producto_id | nuevo:{nombre,
-- unidad_base, precio_venta, controla_stock}}]. cantidad_recibida 0 omite la línea.
-- factor: cuántas unidades base trae cada unidad facturada.
create function public.registrar_compra_de_factura(p_xml text, p_lineas jsonb, p_clave_idempotencia uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa    public.empresas;
  v_datos      jsonb;
  v_hoy        date;
  v_proveedor  uuid;
  v_compra     public.compras;
  v_existente  public.compras;
  v_id         uuid := gen_random_uuid();
  v_r          jsonb;
  x            jsonb;   -- línea del XML
  e            jsonb;   -- lo que dijo quien revisó
  v_producto   uuid;
  v_pres       uuid;
  v_factor     numeric;
  v_recibida   numeric;
  v_parte      numeric;
  v_barras     text;
  v_subtotal   numeric;
  v_descuento  numeric;
  v_iva        numeric;
  v_otros      numeric;
  v_base_unit  numeric;
  v_orden      int := 0;
  v_creados    int := 0;
  v_filas      jsonb := '[]';
  v_detalle    text;
begin
  select * into v_empresa from public.empresas em where em.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la clave de idempotencia');
  end if;
  select * into v_existente from public.compras c
   where c.empresa_id = v_empresa.id and c.clave_idempotencia = p_clave_idempotencia;
  if found then
    return privado.ok(jsonb_build_object('compra_id', v_existente.id, 'repetido', true,
                                         'total', v_existente.total::text, 'productos_nuevos', 0));
  end if;
  if jsonb_typeof(p_lineas) is distinct from 'array' then
    return privado.error('DATOS_INVALIDOS');
  end if;

  v_datos := privado.leer_xml_proveedor(v_empresa, p_xml);
  v_hoy := (now() at time zone v_empresa.zona_horaria)::date;
  if (v_datos ->> 'fecha')::date > v_hoy then
    return privado.error('DATOS_INVALIDOS', 'La fecha no puede ser futura');
  end if;

  -- Proveedor: se reconoce por el RUC o se crea.
  select v.id into v_proveedor from public.proveedores v
   where v.empresa_id = v_empresa.id and v.identificacion = v_datos ->> 'ruc';
  if v_proveedor is null then
    v_r := public.guardar_proveedor(null, jsonb_build_object(
      'tipo_identificacion', 'RUC', 'identificacion', v_datos ->> 'ruc', 'nombre', v_datos ->> 'razon_social'));
    if (v_r ->> 'ok') is distinct from 'true' then
      perform privado.fallar('DATOS_INVALIDOS', 'No se pudo crear el proveedor');
    end if;
    v_proveedor := (v_r -> 'data' ->> 'id')::uuid;
  end if;

  for x in select l from jsonb_array_elements(v_datos -> 'lineas') l order by (l ->> 'orden')::int loop
    select l into e from jsonb_array_elements(p_lineas) l where (l ->> 'orden')::int = (x ->> 'orden')::int limit 1;
    if e is null then
      perform privado.fallar('DATOS_INVALIDOS', (x ->> 'descripcion') || ': falta revisar esta línea');
    end if;

    begin
      v_recibida := round((e ->> 'cantidad_recibida')::numeric, 3);
      v_factor   := coalesce((e ->> 'factor')::numeric, 1);
    exception when invalid_text_representation or numeric_value_out_of_range then
      perform privado.fallar('DATOS_INVALIDOS', (x ->> 'descripcion') || ': número mal escrito');
    end;
    if v_recibida is null or v_recibida < 0 or v_factor <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', (x ->> 'descripcion') || ': revisa la cantidad');
    end if;
    continue when v_recibida = 0;

    -- Producto: uno que ya existe o uno nuevo.
    v_producto := null;
    if e ? 'nuevo' then
      -- La misma factura puede repetir un producto: no se crea dos veces.
      select r.producto_id into v_producto
        from public.codigos_proveedor c
        join public.presentaciones r on r.id = c.presentacion_id
       where c.empresa_id = v_empresa.id and c.proveedor_id = v_proveedor and c.codigo = x ->> 'codigo';
      if v_producto is null then
        select p.id into v_producto from public.productos p
         where p.empresa_id = v_empresa.id and p.activo
           and lower(p.nombre) = lower(trim(coalesce(e -> 'nuevo' ->> 'nombre', x ->> 'descripcion')))
         limit 1;
      end if;
    end if;

    if v_producto is not null then
      null;
    elsif e ? 'nuevo' then
      v_r := public.guardar_producto(null, jsonb_build_object(
        'nombre',         left(trim(coalesce(e -> 'nuevo' ->> 'nombre', x ->> 'descripcion')), 200),
        'unidad_base',    coalesce(e -> 'nuevo' ->> 'unidad_base', 'UND'),
        'codigo_iva',     coalesce(x ->> 'codigo_iva', '0'),
        'precio_venta',   nullif(e -> 'nuevo' ->> 'precio_venta', ''),
        'controla_stock', coalesce((e -> 'nuevo' ->> 'controla_stock')::boolean, true)));
      if (v_r ->> 'ok') is distinct from 'true' then
        perform privado.fallar('DATOS_INVALIDOS',
          (x ->> 'descripcion') || ': ' || coalesce(v_r -> 'error' ->> 'mensaje', 'no se pudo crear el producto'));
      end if;
      v_producto := (v_r -> 'data' ->> 'id')::uuid;
      v_creados := v_creados + 1;
    else
      select p.id into v_producto from public.productos p
       where p.id = (e ->> 'producto_id')::uuid and p.empresa_id = v_empresa.id;
      if v_producto is null then
        perform privado.fallar('DATOS_INVALIDOS', (x ->> 'descripcion') || ': elige el producto');
      end if;
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
          (x ->> 'descripcion') || ': ' || coalesce(v_r -> 'error' ->> 'mensaje', 'no se pudo crear la presentación'));
      end if;
      v_pres := (v_r -> 'data' ->> 'id')::uuid;
    end if;

    -- El código de barras del proveedor, si está libre, queda en esta presentación.
    v_barras := case when x ->> 'codigo_auxiliar' ~ '^[0-9]{8,14}$' then x ->> 'codigo_auxiliar'
                     when x ->> 'codigo' ~ '^[0-9]{8,14}$' then x ->> 'codigo' end;
    if v_barras is not null
       and not exists (select 1 from public.presentaciones r
                        where r.empresa_id = v_empresa.id and r.codigo_barras = v_barras) then
      update public.presentaciones r set codigo_barras = v_barras
       where r.id = v_pres and r.codigo_barras is null;
    end if;

    if x ->> 'codigo' is not null then
      insert into public.codigos_proveedor (empresa_id, proveedor_id, codigo, presentacion_id)
      values (v_empresa.id, v_proveedor, x ->> 'codigo', v_pres)
      on conflict (empresa_id, proveedor_id, codigo)
      do update set presentacion_id = excluded.presentacion_id, actualizado_en = now();
    end if;

    -- Montos del XML, en proporción a lo que llegó.
    v_parte     := v_recibida / (x ->> 'cantidad')::numeric;
    v_subtotal  := round(((x ->> 'base')::numeric + (x ->> 'descuento')::numeric) * v_parte, 2);
    v_descuento := round((x ->> 'descuento')::numeric * v_parte, 2);
    v_iva       := round((x ->> 'iva')::numeric * v_parte, 2);
    v_otros     := round((x ->> 'otros_impuestos')::numeric * v_parte, 2);
    v_orden     := v_orden + 1;
    v_base_unit := (v_subtotal - v_descuento + v_otros
                    + case when v_empresa.iva_compras_es_costo then v_iva else 0 end) / (v_recibida * v_factor);

    v_filas := v_filas || jsonb_build_array(jsonb_build_object(
      'orden', v_orden, 'presentacion_id', v_pres, 'producto_id', v_producto, 'cantidad', v_recibida,
      'costo_unitario', round(v_subtotal / v_recibida, 6), 'descuento', v_descuento,
      'tarifa_iva', (x ->> 'tarifa_iva')::numeric, 'subtotal', v_subtotal, 'iva', v_iva, 'otros', v_otros,
      'cantidad_base', round(v_recibida * v_factor, 3), 'costo_base', round(v_base_unit, 6),
      'descripcion', x ->> 'descripcion'));
  end loop;

  if v_orden = 0 then
    perform privado.fallar('DATOS_INVALIDOS', 'No llegó nada: la compra necesita al menos una línea');
  end if;

  -- Una compra confirmada no se edita: la cabecera entra ya con sus totales.
  insert into public.compras (id, empresa_id, proveedor_id, fecha, numero_documento, con_respaldo,
                              subtotal, descuento, iva, otros_impuestos, total, iva_es_costo, clave_idempotencia,
                              clave_acceso, total_factura, xml, creado_por)
  select v_id, v_empresa.id, v_proveedor, (v_datos ->> 'fecha')::date,
         privado.normalizar_documento(v_datos ->> 'numero'), true,
         f.subtotal, f.descuento, f.iva, f.otros, f.subtotal - f.descuento + f.iva + f.otros,
         v_empresa.iva_compras_es_costo, p_clave_idempotencia,
         v_datos ->> 'clave_acceso', (v_datos ->> 'total')::numeric, p_xml, auth.uid()
    from (select sum((l ->> 'subtotal')::numeric) as subtotal, sum((l ->> 'descuento')::numeric) as descuento,
                 sum((l ->> 'iva')::numeric) as iva, sum((l ->> 'otros')::numeric) as otros
            from jsonb_array_elements(v_filas) l) f
  returning * into v_compra;

  insert into public.compra_detalles (empresa_id, compra_id, orden, presentacion_id, producto_id, cantidad,
                                      costo_unitario, descuento, tarifa_iva, subtotal, iva, otros_impuestos,
                                      cantidad_base, costo_unitario_base, descripcion_factura)
  select v_empresa.id, v_id, (l ->> 'orden')::int, (l ->> 'presentacion_id')::uuid, (l ->> 'producto_id')::uuid,
         (l ->> 'cantidad')::numeric, (l ->> 'costo_unitario')::numeric, (l ->> 'descuento')::numeric,
         (l ->> 'tarifa_iva')::numeric, (l ->> 'subtotal')::numeric, (l ->> 'iva')::numeric,
         (l ->> 'otros')::numeric, (l ->> 'cantidad_base')::numeric, (l ->> 'costo_base')::numeric, l ->> 'descripcion'
    from jsonb_array_elements(v_filas) l;

  -- Entradas al inventario en orden de producto (evita bloqueos cruzados).
  for v_producto, v_recibida, v_base_unit in
    select d.producto_id, d.cantidad_base, d.costo_unitario_base
      from public.compra_detalles d where d.compra_id = v_id order by d.producto_id, d.orden
  loop
    perform privado.registrar_movimiento(
      v_empresa.id, v_producto, 'COMPRA', v_recibida, v_base_unit,
      'compras', v_id, null, null, v_compra.fecha);
  end loop;

  return privado.ok(jsonb_build_object('compra_id', v_id, 'repetido', false, 'total', v_compra.total::text,
                                       'total_factura', v_datos ->> 'total', 'productos_nuevos', v_creados));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
  when unique_violation then
    return privado.error('DUPLICADO', 'Esta factura ya está registrada como compra');
end;
$$;

revoke all on function
  privado.leer_xml_proveedor(public.empresas, text),
  privado.presentacion_de_linea(uuid, uuid, jsonb)
  from public, anon, authenticated;

revoke all on function
  public.leer_factura_proveedor(text),
  public.registrar_compra_de_factura(text, jsonb, uuid)
  from public, anon;
grant execute on function
  public.leer_factura_proveedor(text),
  public.registrar_compra_de_factura(text, jsonb, uuid)
  to authenticated;
