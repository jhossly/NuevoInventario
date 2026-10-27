-- =============================================================================
-- Migración 0007: importación de facturas autorizadas del SRI
-- Fase 2 y 3 (diseño) / Fase 11 (implementación)
--
-- El dueño factura en el portal gratuito del SRI. Aquí sube los XML
-- autorizados de SUS facturas para no registrar dos veces (D-012):
--   1. importar_comprobante lee el XML, valida que sea una factura autorizada
--      de esta bodega y guarda cabecera y líneas. No toca el inventario.
--   2. Cada línea se asocia a una presentación por su código (memoria en
--      codigos_sri o código de barras); las que no coinciden quedan pendientes.
--   3. Si la venta ya se registró a mano (mismo día, total ±$0,01), el dueño la
--      VINCULA. Si no, CREA la venta desde el XML (con sus montos exactos y la
--      salida de inventario). Nunca las dos cosas.
--
-- D-040: el XML se lee aquí con xpath (no en una Edge Function): una sola
-- transacción, una sola fuente de reglas, pruebas con pgTAP. PostgreSQL no
-- resuelve entidades externas y además se rechaza cualquier DOCTYPE.
-- D-041: el XML original se guarda en la fila (unos KB), no en Storage.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tablas
-- -----------------------------------------------------------------------------
create table public.comprobantes (
  id                             uuid primary key default gen_random_uuid(),
  empresa_id                     uuid not null references public.empresas (id) on delete restrict,
  origen                         text not null default 'IMPORTADO',
  clave_acceso                   text not null,
  tipo                           text not null,
  numero                         text not null,
  fecha_emision                  date not null,
  ambiente                       text not null,
  numero_autorizacion            text,
  tipo_identificacion_comprador  text,
  identificacion_comprador       text,
  razon_social_comprador         text,
  subtotal                       numeric(12,2) not null,
  descuento                      numeric(12,2) not null,
  iva                            numeric(12,2) not null,
  total                          numeric(12,2) not null,
  pagos                          jsonb not null,
  estado                         text not null default 'AUTORIZADO',
  xml                            text not null,
  venta_id                       uuid unique references public.ventas (id) on delete restrict,
  vinculo                        text,
  vinculado_en                   timestamptz,
  vinculado_por                  uuid,
  creado_en                      timestamptz not null default now(),
  creado_por                     uuid,
  constraint comprobantes_origen check (origen in ('IMPORTADO', 'EMITIDO')),
  constraint comprobantes_clave check (clave_acceso ~ '^[0-9]{49}$'),
  constraint comprobantes_estado check (estado = 'AUTORIZADO'),
  constraint comprobantes_vinculo check (
    (venta_id is null) = (vinculo is null) and (vinculo is null or vinculo in ('VINCULADA', 'CREADA'))),
  constraint comprobantes_totales check (total = subtotal - descuento + iva),
  constraint comprobantes_clave_unica unique (empresa_id, clave_acceso)
);
create index comprobantes_empresa_fecha_idx on public.comprobantes (empresa_id, fecha_emision desc);

create table public.comprobante_lineas (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null references public.empresas (id) on delete restrict,
  comprobante_id   uuid not null references public.comprobantes (id) on delete cascade,
  orden            int not null,
  codigo           text,
  descripcion      text not null,
  cantidad         numeric(18,6) not null,
  precio_unitario  numeric(18,6) not null,     -- sin IVA, como viene en el XML
  descuento        numeric(12,2) not null,
  base             numeric(12,2) not null,     -- precioTotalSinImpuesto
  tarifa_iva       numeric(5,2) not null,
  iva              numeric(12,2) not null,
  presentacion_id  uuid references public.presentaciones (id) on delete restrict,
  constraint comprobante_lineas_valores check (cantidad > 0 and base >= 0 and descuento >= 0 and iva >= 0),
  constraint comprobante_lineas_orden unique (comprobante_id, orden)
);
create index comprobante_lineas_comprobante_idx on public.comprobante_lineas (comprobante_id);

-- Memoria de asociaciones: el código que el dueño usa en el portal del SRI
-- apunta a una presentación; la próxima factura con ese código se asocia sola.
create table public.codigos_sri (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null references public.empresas (id) on delete restrict,
  codigo           text not null,
  presentacion_id  uuid not null references public.presentaciones (id) on delete restrict,
  actualizado_en   timestamptz not null default now(),
  constraint codigos_sri_unico unique (empresa_id, codigo)
);

-- El contenido no se edita (Fase 3). Solo se completa una vez el vínculo con
-- su venta; mientras no tenga venta, se puede descartar (un archivo equivocado).
create function privado.comprobante_cambios_permitidos()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_libres text[] := array['venta_id', 'vinculo', 'vinculado_en', 'vinculado_por'];
begin
  if tg_op = 'DELETE' then
    if old.venta_id is not null then
      raise exception 'Un comprobante con venta no se borra' using errcode = 'P0001';
    end if;
    return old;
  end if;
  if old.venta_id is null and new.venta_id is not null
     and (to_jsonb(old) - v_libres) = (to_jsonb(new) - v_libres) then
    return new;
  end if;
  raise exception 'Un comprobante no se edita: solo se vincula una vez a su venta' using errcode = 'P0001';
end;
$$;

create trigger comprobantes_cambios_permitidos before update or delete on public.comprobantes
  for each row execute function privado.comprobante_cambios_permitidos();

-- De las líneas solo cambia la presentación asociada, y solo antes del vínculo.
create function privado.comprobante_linea_cambios_permitidos()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    return old;  -- solo ocurre en cascada al descartar un comprobante sin venta
  end if;
  if exists (select 1 from public.comprobantes c where c.id = old.comprobante_id and c.venta_id is not null) then
    raise exception 'El comprobante ya tiene venta: sus líneas no cambian' using errcode = 'P0001';
  end if;
  if (to_jsonb(old) - 'presentacion_id') is distinct from (to_jsonb(new) - 'presentacion_id') then
    raise exception 'De una línea del comprobante solo se cambia el producto asociado' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger comprobante_lineas_cambios_permitidos before update or delete on public.comprobante_lineas
  for each row execute function privado.comprobante_linea_cambios_permitidos();

-- -----------------------------------------------------------------------------
-- 2. Permisos y RLS (todo del Dueño: Fase 4, «Importar XML del SRI»)
-- -----------------------------------------------------------------------------
revoke all on public.comprobantes, public.comprobante_lineas, public.codigos_sri from anon, authenticated;
-- El XML completo no viaja al navegador en las listas: columna aparte.
grant select (id, empresa_id, origen, clave_acceso, tipo, numero, fecha_emision, ambiente, numero_autorizacion,
              tipo_identificacion_comprador, identificacion_comprador, razon_social_comprador,
              subtotal, descuento, iva, total, pagos, estado, venta_id, vinculo, vinculado_en, creado_en)
  on public.comprobantes to authenticated;
grant select on public.comprobante_lineas, public.codigos_sri to authenticated;

alter table public.comprobantes       enable row level security;
alter table public.comprobante_lineas enable row level security;
alter table public.codigos_sri        enable row level security;

create policy comprobantes_lectura on public.comprobantes
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');
create policy comprobante_lineas_lectura on public.comprobante_lineas
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');
create policy codigos_sri_lectura on public.codigos_sri
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()) and (select privado.mi_rol()) = 'DUENO');

-- -----------------------------------------------------------------------------
-- 3. Lectura del XML (privado)
-- -----------------------------------------------------------------------------

-- Dígito verificador de la clave de acceso: módulo 11, pesos 2..7 desde la derecha.
create function privado.digito_clave_acceso(p_base text)
returns int
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_suma int := 0;
  v_peso int := 2;
  v_resto int;
begin
  for i in reverse length(p_base)..1 loop
    v_suma := v_suma + substr(p_base, i, 1)::int * v_peso;
    v_peso := case when v_peso = 7 then 2 else v_peso + 1 end;
  end loop;
  v_resto := 11 - (v_suma % 11);
  return case v_resto when 11 then 0 when 10 then 1 else v_resto end;
end;
$$;

-- Texto de un nodo: xpath devuelve las entidades escapadas (&amp;). Con un
-- nodo suelto (un <detalle>), la ruta empieza en «/*/» (la raíz es ese nodo).
create function privado.xml_texto(p_doc xml, p_ruta text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(trim(replace(replace(replace(replace(replace(
           (xpath(p_ruta || '/text()', p_doc))[1]::text,
           '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&apos;', ''''), '&amp;', '&')), '')
$$;

-- Factura de adentro del sobre de autorización. El SRI la manda en CDATA o
-- escapada; se aceptan ambas.
create function privado.xml_interno(p_texto text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_texto like '<![CDATA[%' then substr(p_texto, 10, length(p_texto) - 12)
    else replace(replace(replace(replace(replace(p_texto,
           '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&apos;', ''''), '&amp;', '&')
  end
$$;

-- Número del XML ("10.35"); nulo si falta.
create function privado.xml_numero(p_doc xml, p_ruta text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select privado.xml_texto(p_doc, p_ruta)::numeric
$$;

-- -----------------------------------------------------------------------------
-- 4. Importar
-- -----------------------------------------------------------------------------
create function public.importar_comprobante(p_xml text)
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
  if (select round(sum((l ->> 'base')::numeric), 2) from jsonb_array_elements(v_lineas) l) <> round(v_base_tot, 2) then
    return privado.error('DATOS_INVALIDOS', 'Las líneas no suman la base de la factura');
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

-- -----------------------------------------------------------------------------
-- 5. Asociar, buscar duplicados, vincular, crear venta, descartar
-- -----------------------------------------------------------------------------
create function public.asociar_linea_comprobante(p_linea_id uuid, p_presentacion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_linea    public.comprobante_lineas;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  select * into v_linea from public.comprobante_lineas l where l.id = p_linea_id and l.empresa_id = v_empresa;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La línea no existe');
  end if;
  if exists (select 1 from public.comprobantes c where c.id = v_linea.comprobante_id and c.venta_id is not null) then
    return privado.error('DATOS_INVALIDOS', 'El comprobante ya tiene venta');
  end if;
  if not exists (select 1 from public.presentaciones r
                  where r.id = p_presentacion_id and r.empresa_id = v_empresa and r.activo) then
    return privado.error('DATOS_INVALIDOS', 'La presentación no existe');
  end if;

  update public.comprobante_lineas l set presentacion_id = p_presentacion_id where l.id = v_linea.id;

  -- Se recuerda para las próximas facturas, y se aplica a las líneas pendientes
  -- con el mismo código.
  if v_linea.codigo is not null then
    insert into public.codigos_sri (empresa_id, codigo, presentacion_id)
    values (v_empresa, v_linea.codigo, p_presentacion_id)
    on conflict (empresa_id, codigo) do update
      set presentacion_id = excluded.presentacion_id, actualizado_en = now();
    update public.comprobante_lineas l set presentacion_id = p_presentacion_id
     where l.empresa_id = v_empresa and l.codigo = v_linea.codigo and l.presentacion_id is null
       and exists (select 1 from public.comprobantes c where c.id = l.comprobante_id and c.venta_id is null);
  end if;

  return privado.ok(jsonb_build_object('linea_id', v_linea.id));
end;
$$;

-- Ventas registradas a mano que pueden ser esta factura (D-012): mismo día,
-- total ±$0,01, confirmadas y sin comprobante.
create function public.candidatos_comprobante(p_comprobante_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_comp    public.comprobantes;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  select * into v_comp from public.comprobantes c where c.id = p_comprobante_id and c.empresa_id = v_empresa;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'El comprobante no existe');
  end if;

  return privado.ok(jsonb_build_object('ventas', coalesce((
    select jsonb_agg(jsonb_build_object(
             'venta_id', v.id, 'creado_en', v.creado_en, 'total', v.total::text,
             'tipo_comprobante', v.tipo_comprobante,
             'cliente', coalesce(c.nombre, 'Consumidor final'))
           order by (v.tipo_comprobante = 'FACTURA') desc, abs(v.total - v_comp.total), v.creado_en)
      from public.ventas v
      left join public.clientes c on c.id = v.cliente_id
     where v.empresa_id = v_empresa and v.estado = 'CONFIRMADA'
       and v.fecha = v_comp.fecha_emision
       and abs(v.total - v_comp.total) <= 0.01
       and not exists (select 1 from public.comprobantes x where x.venta_id = v.id)), '[]'::jsonb)));
end;
$$;

create function public.vincular_comprobante(p_comprobante_id uuid, p_venta_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_comp    public.comprobantes;
  v_venta   public.ventas;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  select * into v_comp from public.comprobantes c
   where c.id = p_comprobante_id and c.empresa_id = v_empresa for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'El comprobante no existe');
  end if;
  if v_comp.venta_id is not null then
    return privado.error('DATOS_INVALIDOS', 'El comprobante ya tiene venta');
  end if;
  select * into v_venta from public.ventas v where v.id = p_venta_id and v.empresa_id = v_empresa for update;
  if not found or v_venta.estado <> 'CONFIRMADA' then
    return privado.error('DATOS_INVALIDOS', 'La venta no existe o está anulada');
  end if;
  if v_venta.fecha <> v_comp.fecha_emision or abs(v_venta.total - v_comp.total) > 0.01 then
    return privado.error('DATOS_INVALIDOS', 'La venta no es del mismo día o su total no coincide (D-012)');
  end if;

  update public.comprobantes c
     set venta_id = v_venta.id, vinculo = 'VINCULADA', vinculado_en = now(), vinculado_por = auth.uid()
   where c.id = v_comp.id;

  return privado.ok(jsonb_build_object('comprobante_id', v_comp.id, 'venta_id', v_venta.id));
exception
  when unique_violation then
    return privado.error('DATOS_INVALIDOS', 'Esa venta ya tiene otro comprobante');
end;
$$;

-- Crea la venta que no se registró a mano, con los montos exactos del XML.
-- Fecha de la factura, sin caja (el efectivo de ese día ya se contó fuera del
-- sistema, D-043), cliente buscado o creado por su identificación.
create function public.crear_venta_de_comprobante(p_comprobante_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  public.empresas;
  v_comp     public.comprobantes;
  v_cliente  uuid;
  v_tipo_id  text;
  v_id       uuid := gen_random_uuid();
  v_linea    record;
  v_mov      public.movimientos_inventario;
  v_costos   jsonb := '{}';
  v_detalle  text;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  select * into v_comp from public.comprobantes c
   where c.id = p_comprobante_id and c.empresa_id = v_empresa.id for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'El comprobante no existe');
  end if;
  if v_comp.venta_id is not null then
    return privado.ok(jsonb_build_object('venta_id', v_comp.venta_id, 'repetido', true));
  end if;
  if exists (select 1 from public.comprobante_lineas l where l.comprobante_id = v_comp.id and l.presentacion_id is null) then
    return privado.error('DATOS_INVALIDOS', 'Asocia todas las líneas a un producto antes de crear la venta');
  end if;

  -- Cliente (consumidor final = sin cliente)
  v_tipo_id := case v_comp.tipo_identificacion_comprador
                 when '04' then 'RUC' when '05' then 'CEDULA' when '06' then 'PASAPORTE' end;
  if v_tipo_id is not null and v_comp.identificacion_comprador is not null then
    select c.id into v_cliente from public.clientes c
     where c.empresa_id = v_empresa.id and c.identificacion = v_comp.identificacion_comprador;
    if v_cliente is null then
      begin
        insert into public.clientes (empresa_id, tipo_identificacion, identificacion, nombre, creado_por)
        values (v_empresa.id, v_tipo_id, v_comp.identificacion_comprador,
                coalesce(v_comp.razon_social_comprador, v_comp.identificacion_comprador), auth.uid())
        returning id into v_cliente;
      exception when check_violation then
        v_cliente := null;  -- identificación con un formato que no reconocemos
      end;
    end if;
  end if;

  -- Salidas de inventario en orden de producto, con la fecha de la factura.
  for v_linea in
    select l.*, r.factor, r.producto_id
      from public.comprobante_lineas l join public.presentaciones r on r.id = l.presentacion_id
     where l.comprobante_id = v_comp.id
     order by r.producto_id, l.orden
  loop
    v_mov := privado.registrar_movimiento(
      v_empresa.id, v_linea.producto_id, 'VENTA', -round(v_linea.cantidad * v_linea.factor, 3), null,
      'ventas', v_id, 'Factura ' || v_comp.numero, null, v_comp.fecha_emision);
    v_costos := v_costos || jsonb_build_object(v_linea.orden::text, jsonb_build_object(
      'costo_unitario', v_mov.costo_unitario, 'costo_total', -v_mov.valor));
  end loop;

  insert into public.ventas (id, empresa_id, fecha, cliente_id, caja_id, tipo_comprobante, subtotal, descuento,
                             iva, total, costo_total, precios_incluyen_iva, clave_idempotencia, creado_por)
  select v_id, v_empresa.id, v_comp.fecha_emision, v_cliente, null, 'FACTURA',
         sum(l.base + l.descuento), sum(l.descuento), sum(l.iva), sum(l.base + l.iva),
         sum((v_costos -> l.orden::text ->> 'costo_total')::numeric),
         v_empresa.precios_incluyen_iva, v_comp.id, auth.uid()
    from public.comprobante_lineas l where l.comprobante_id = v_comp.id;

  insert into public.venta_detalles (empresa_id, venta_id, orden, presentacion_id, producto_id, cantidad,
                                     precio_unitario, tarifa_iva, subtotal, descuento, iva, total,
                                     cantidad_base, costo_unitario, costo_total)
  select v_empresa.id, v_id, l.orden, l.presentacion_id, r.producto_id, round(l.cantidad, 3),
         -- Precio informativo, como el de la percha (con IVA si así se trabaja).
         round(l.precio_unitario * case when v_empresa.precios_incluyen_iva then 1 + l.tarifa_iva / 100 else 1 end, 2),
         l.tarifa_iva, l.base + l.descuento, l.descuento, l.iva, l.base + l.iva,
         round(l.cantidad * r.factor, 3),
         (v_costos -> l.orden::text ->> 'costo_unitario')::numeric,
         (v_costos -> l.orden::text ->> 'costo_total')::numeric
    from public.comprobante_lineas l join public.presentaciones r on r.id = l.presentacion_id
   where l.comprobante_id = v_comp.id;

  insert into public.venta_pagos (empresa_id, venta_id, medio, monto)
  select v_empresa.id, v_id, p ->> 'medio', (p ->> 'monto')::numeric
    from jsonb_array_elements(v_comp.pagos) p
   where (p ->> 'monto')::numeric > 0;

  update public.comprobantes c
     set venta_id = v_id, vinculo = 'CREADA', vinculado_en = now(), vinculado_por = auth.uid()
   where c.id = v_comp.id;

  return privado.ok(jsonb_build_object('venta_id', v_id, 'repetido', false));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return privado.explicar_error_venta(v_detalle);
  when check_violation then
    return privado.error('DATOS_INVALIDOS', 'Los montos de la factura no se pueden registrar como venta');
end;
$$;

create function public.descartar_comprobante(p_comprobante_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
  v_comp    public.comprobantes;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  select * into v_comp from public.comprobantes c
   where c.id = p_comprobante_id and c.empresa_id = v_empresa for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'El comprobante no existe');
  end if;
  if v_comp.venta_id is not null then
    return privado.error('DATOS_INVALIDOS', 'El comprobante ya tiene venta: no se descarta');
  end if;
  delete from public.comprobantes c where c.id = v_comp.id;
  insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes)
  values (v_empresa, auth.uid(), 'COMPROBANTE_DESCARTADO', 'comprobantes', v_comp.id,
          jsonb_build_object('clave_acceso', v_comp.clave_acceso, 'numero', v_comp.numero, 'total', v_comp.total));
  return privado.ok(jsonb_build_object('comprobante_id', v_comp.id));
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Permisos de las funciones
-- -----------------------------------------------------------------------------
revoke all on function
  privado.comprobante_cambios_permitidos(),
  privado.comprobante_linea_cambios_permitidos(),
  privado.digito_clave_acceso(text),
  privado.xml_texto(xml, text),
  privado.xml_interno(text),
  privado.xml_numero(xml, text)
  from public, anon, authenticated;

revoke all on function
  public.importar_comprobante(text),
  public.asociar_linea_comprobante(uuid, uuid),
  public.candidatos_comprobante(uuid),
  public.vincular_comprobante(uuid, uuid),
  public.crear_venta_de_comprobante(uuid),
  public.descartar_comprobante(uuid)
  from public, anon;
grant execute on function
  public.importar_comprobante(text),
  public.asociar_linea_comprobante(uuid, uuid),
  public.candidatos_comprobante(uuid),
  public.vincular_comprobante(uuid, uuid),
  public.crear_venta_de_comprobante(uuid),
  public.descartar_comprobante(uuid)
  to authenticated;
