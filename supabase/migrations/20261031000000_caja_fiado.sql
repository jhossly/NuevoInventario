-- =============================================================================
-- Migración 0005: caja y fiado
-- Fase 3 (diseño) / Fase 9 (implementación)
--
-- Crea:
--   * cajas (una sola abierta por empresa; se cierra una vez), caja_movimientos
--     (ingresos y egresos, también los automáticos de anulaciones y
--     devoluciones en efectivo), fiado_movimientos (cuenta corriente)
--   * ventas.caja_id y devoluciones.caja_id
--   * funciones: abrir_caja, movimiento_caja, cerrar_caja, resumen_caja,
--     explicar_diferencia_caja, registrar_abono, ajustar_fiado, cuentas_fiado
--   * nuevas versiones de registrar_venta (pago FIADO, caja obligatoria para
--     efectivo), anular_venta y registrar_devolucion (efectivo sale de la caja
--     abierta; el fiado se descuenta del saldo)
--
-- Efectivo esperado al cerrar (HU-04, D-033):
--   fondo inicial + ventas en efectivo + abonos de fiado en efectivo
--   + ingresos − egresos (los egresos incluyen el efectivo devuelto por
--   anulaciones y devoluciones)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tablas
-- -----------------------------------------------------------------------------
create table public.cajas (
  id                      uuid primary key default gen_random_uuid(),
  empresa_id              uuid not null references public.empresas (id) on delete restrict,
  abierta_por             uuid,
  abierta_en              timestamptz not null default now(),
  fondo_inicial           numeric(12,2) not null,
  cerrada_por             uuid,
  cerrada_en              timestamptz,
  monto_contado           numeric(12,2),
  monto_esperado          numeric(12,2),
  diferencia              numeric(12,2),
  nota_cierre             text,
  explicacion_diferencia  text,
  explicada_por           uuid,
  explicada_en            timestamptz,
  constraint cajas_fondo_no_negativo check (fondo_inicial >= 0),
  constraint cajas_cierre_completo check (
    (cerrada_en is null) = (monto_contado is null and monto_esperado is null and diferencia is null)),
  constraint cajas_contado_no_negativo check (monto_contado >= 0),
  constraint cajas_diferencia_cuadra check (diferencia = monto_contado - monto_esperado)
);
-- Una sola caja abierta por empresa (Fase 3).
create unique index cajas_una_abierta on public.cajas (empresa_id) where cerrada_en is null;
create index cajas_empresa_fecha_idx on public.cajas (empresa_id, abierta_en desc);

create table public.caja_movimientos (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references public.empresas (id) on delete restrict,
  caja_id             uuid not null references public.cajas (id) on delete restrict,
  tipo                text not null,
  monto               numeric(12,2) not null,
  motivo              text not null,
  -- Egresos automáticos: el efectivo devuelto por una anulación o devolución.
  venta_id            uuid references public.ventas (id) on delete restrict,
  devolucion_id       uuid references public.devoluciones (id) on delete restrict,
  automatico          boolean not null default false,
  clave_idempotencia  uuid,
  creado_en           timestamptz not null default now(),
  creado_por          uuid,
  constraint caja_movimientos_tipo check (tipo in ('INGRESO', 'EGRESO')),
  constraint caja_movimientos_monto check (monto > 0),
  constraint caja_movimientos_motivo check (length(trim(motivo)) > 0)
);
create index caja_movimientos_caja_idx on public.caja_movimientos (caja_id);
create unique index caja_movimientos_idempotencia
  on public.caja_movimientos (empresa_id, clave_idempotencia) where clave_idempotencia is not null;

create table public.fiado_movimientos (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references public.empresas (id) on delete restrict,
  cliente_id          uuid not null references public.clientes (id) on delete restrict,
  tipo                text not null,
  -- Con signo: el cargo aumenta la deuda, el abono la reduce.
  monto               numeric(12,2) not null,
  medio               text,
  venta_id            uuid references public.ventas (id) on delete restrict,
  devolucion_id       uuid references public.devoluciones (id) on delete restrict,
  caja_id             uuid references public.cajas (id) on delete restrict,
  motivo              text,
  clave_idempotencia  uuid,
  creado_en           timestamptz not null default now(),
  creado_por          uuid,
  constraint fiado_movimientos_tipo check (
    (tipo = 'CARGO'  and monto > 0 and venta_id is not null) or
    (tipo = 'ABONO'  and monto < 0 and medio in ('EFECTIVO', 'TRANSFERENCIA', 'TARJETA')) or
    (tipo = 'AJUSTE' and monto <> 0 and motivo is not null)),
  -- El efectivo de un abono entra a una caja.
  constraint fiado_movimientos_abono_caja check (medio is distinct from 'EFECTIVO' or caja_id is not null)
);
create index fiado_movimientos_cliente_idx on public.fiado_movimientos (cliente_id, creado_en);
create index fiado_movimientos_caja_idx on public.fiado_movimientos (caja_id);
create unique index fiado_movimientos_idempotencia
  on public.fiado_movimientos (empresa_id, clave_idempotencia) where clave_idempotencia is not null;

alter table public.ventas add column caja_id uuid references public.cajas (id) on delete restrict;
create index ventas_caja_idx on public.ventas (caja_id);
alter table public.devoluciones add column caja_id uuid references public.cajas (id) on delete restrict;

-- Inmutabilidad
create trigger caja_movimientos_solo_insercion before update or delete on public.caja_movimientos
  for each row execute function privado.impedir_cambios();
create trigger fiado_movimientos_solo_insercion before update or delete on public.fiado_movimientos
  for each row execute function privado.impedir_cambios();

-- Una caja solo cambia dos veces: al cerrarse (una vez, sin reabrir) y al
-- recibir la explicación de su diferencia (una vez). Nunca se borra.
create function privado.caja_cambios_permitidos()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_cierre      text[] := array['cerrada_por', 'cerrada_en', 'monto_contado', 'monto_esperado',
                                'diferencia', 'nota_cierre'];
  v_explicacion text[] := array['explicacion_diferencia', 'explicada_por', 'explicada_en'];
begin
  if tg_op = 'DELETE' then
    raise exception 'Una caja no se borra' using errcode = 'P0001';
  end if;
  if old.cerrada_en is null and new.cerrada_en is not null
     and (to_jsonb(old) - v_cierre) = (to_jsonb(new) - v_cierre) then
    return new;
  end if;
  if old.cerrada_en is not null and old.explicacion_diferencia is null
     and new.explicacion_diferencia is not null
     and (to_jsonb(old) - v_explicacion) = (to_jsonb(new) - v_explicacion) then
    return new;
  end if;
  raise exception 'Una caja solo se cierra una vez y no se reabre' using errcode = 'P0001';
end;
$$;

create trigger cajas_cambios_permitidos before update or delete on public.cajas
  for each row execute function privado.caja_cambios_permitidos();

-- La caja de una venta o devolución no se cambia después (el trigger de ventas
-- ya compara todas las columnas salvo las de anulación; devoluciones es de solo
-- inserción).

-- -----------------------------------------------------------------------------
-- 2. Permisos y RLS
-- -----------------------------------------------------------------------------
revoke all on public.cajas, public.caja_movimientos, public.fiado_movimientos from anon, authenticated;
grant select on public.caja_movimientos, public.fiado_movimientos to authenticated;

-- Cierre a ciegas (D-032): el Vendedor no ve lo esperado ni la diferencia
-- (Fase 4: «Ver diferencia de caja: solo Dueño»). Se ocultan por columna; el
-- Dueño los obtiene con resumen_caja().
grant select (id, empresa_id, abierta_por, abierta_en, fondo_inicial, cerrada_por, cerrada_en,
              monto_contado, nota_cierre)
  on public.cajas to authenticated;
-- ventas.caja_id es una columna nueva: se suma a las que el navegador puede leer.
grant select (caja_id) on public.ventas to authenticated;

alter table public.cajas             enable row level security;
alter table public.caja_movimientos  enable row level security;
alter table public.fiado_movimientos enable row level security;

create policy cajas_lectura on public.cajas
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

create policy caja_movimientos_lectura on public.caja_movimientos
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

-- Ambos roles cobran abonos y venden al fiado: ambos ven la cuenta corriente.
create policy fiado_movimientos_lectura on public.fiado_movimientos
  for select to authenticated
  using (empresa_id = (select privado.mi_empresa()));

-- -----------------------------------------------------------------------------
-- 3. Auxiliares privados
-- -----------------------------------------------------------------------------

-- Caja abierta de la empresa, bloqueada en modo compartido: muchas ventas a la
-- vez la usan, pero el cierre (que la bloquea en exclusiva) espera a que
-- terminen y ninguna venta entra a una caja ya cerrada.
create function privado.caja_abierta(p_empresa uuid)
returns uuid
language sql
set search_path = ''
as $$
  select c.id from public.cajas c
   where c.empresa_id = p_empresa and c.cerrada_en is null
     for share
$$;

-- Componentes del efectivo esperado de una caja (HU-04).
create function privado.efectivo_caja(p_caja_id uuid)
returns table (fondo_inicial numeric, ventas_efectivo numeric, abonos_efectivo numeric,
               ingresos numeric, egresos numeric, esperado numeric)
language sql
stable
set search_path = ''
as $$
  with c as (select fondo_inicial from public.cajas where id = p_caja_id),
  v as (select coalesce(sum(p.monto), 0) as total
          from public.venta_pagos p join public.ventas v on v.id = p.venta_id
         where v.caja_id = p_caja_id and p.medio = 'EFECTIVO'),
  a as (select coalesce(sum(-f.monto), 0) as total
          from public.fiado_movimientos f
         where f.caja_id = p_caja_id and f.tipo = 'ABONO' and f.medio = 'EFECTIVO'),
  m as (select coalesce(sum(monto) filter (where tipo = 'INGRESO'), 0) as ingresos,
               coalesce(sum(monto) filter (where tipo = 'EGRESO'), 0) as egresos
          from public.caja_movimientos where caja_id = p_caja_id)
  select c.fondo_inicial, v.total, a.total, m.ingresos, m.egresos,
         c.fondo_inicial + v.total + a.total + m.ingresos - m.egresos
    from c, v, a, m
$$;

create function privado.saldo_fiado(p_cliente_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(f.monto), 0) from public.fiado_movimientos f where f.cliente_id = p_cliente_id
$$;

-- -----------------------------------------------------------------------------
-- 4. Caja
-- -----------------------------------------------------------------------------
create function public.abrir_caja(p_fondo_inicial numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_id       uuid;
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;
  if p_fondo_inicial is null or p_fondo_inicial < 0 then
    return privado.error('DATOS_INVALIDOS', 'El fondo inicial debe ser cero o más');
  end if;
  if exists (select 1 from public.cajas c where c.empresa_id = v_empresa and c.cerrada_en is null) then
    return privado.error('DATOS_INVALIDOS', 'Ya hay una caja abierta');
  end if;

  insert into public.cajas (empresa_id, abierta_por, fondo_inicial)
  values (v_empresa, auth.uid(), round(p_fondo_inicial, 2))
  returning id into v_id;

  return privado.ok(jsonb_build_object('caja_id', v_id));
exception
  when unique_violation then
    return privado.error('DATOS_INVALIDOS', 'Ya hay una caja abierta');
end;
$$;

-- Ingreso o egreso manual de efectivo (pago a un proveedor, cambio traído del banco).
create function public.movimiento_caja(p_tipo text, p_monto numeric, p_motivo text, p_clave_idempotencia uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_caja     uuid;
  v_id       uuid;
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is not null then
    select m.id into v_id from public.caja_movimientos m
     where m.empresa_id = v_empresa and m.clave_idempotencia = p_clave_idempotencia;
    if found then
      return privado.ok(jsonb_build_object('movimiento_id', v_id, 'repetido', true));
    end if;
  end if;
  if p_tipo is null or p_tipo not in ('INGRESO', 'EGRESO') then
    return privado.error('DATOS_INVALIDOS', 'Tipo de movimiento no válido');
  end if;
  if p_monto is null or round(p_monto, 2) <= 0 then
    return privado.error('DATOS_INVALIDOS', 'El monto debe ser mayor que cero');
  end if;
  if nullif(trim(p_motivo), '') is null then
    return privado.error('DATOS_INVALIDOS', 'El motivo es obligatorio');
  end if;

  v_caja := privado.caja_abierta(v_empresa);
  if v_caja is null then
    return privado.error('CAJA_CERRADA');
  end if;

  insert into public.caja_movimientos (empresa_id, caja_id, tipo, monto, motivo, clave_idempotencia, creado_por)
  values (v_empresa, v_caja, p_tipo, round(p_monto, 2), trim(p_motivo), p_clave_idempotencia, auth.uid())
  returning id into v_id;

  return privado.ok(jsonb_build_object('movimiento_id', v_id, 'repetido', false));
exception
  when unique_violation then
    select m.id into v_id from public.caja_movimientos m
     where m.empresa_id = v_empresa and m.clave_idempotencia = p_clave_idempotencia;
    return privado.ok(jsonb_build_object('movimiento_id', v_id, 'repetido', true));
end;
$$;

-- Cierra la caja abierta con lo contado. El Vendedor cierra a ciegas: no recibe
-- lo esperado ni la diferencia (D-032).
create function public.cerrar_caja(p_monto_contado numeric, p_nota text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa   uuid := privado.mi_empresa();
  v_caja      public.cajas;
  v_efectivo  record;
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;
  if p_monto_contado is null or p_monto_contado < 0 then
    return privado.error('DATOS_INVALIDOS', 'Escribe el efectivo contado');
  end if;

  -- Bloqueo exclusivo: espera a que terminen las ventas en curso de esta caja.
  select * into v_caja from public.cajas c
   where c.empresa_id = v_empresa and c.cerrada_en is null
     for update;
  if not found then
    return privado.error('CAJA_CERRADA', 'No hay una caja abierta');
  end if;

  select * into v_efectivo from privado.efectivo_caja(v_caja.id);

  update public.cajas c
     set cerrada_por    = auth.uid(),
         cerrada_en     = now(),
         monto_contado  = round(p_monto_contado, 2),
         monto_esperado = v_efectivo.esperado,
         diferencia     = round(p_monto_contado, 2) - v_efectivo.esperado,
         nota_cierre    = nullif(trim(p_nota), '')
   where c.id = v_caja.id;

  if privado.mi_rol() = 'DUENO' then
    return privado.ok(jsonb_build_object(
      'caja_id', v_caja.id,
      'esperado', v_efectivo.esperado::numeric(12,2)::text,
      'contado', round(p_monto_contado, 2)::text,
      'diferencia', (round(p_monto_contado, 2) - v_efectivo.esperado)::numeric(12,2)::text));
  end if;
  return privado.ok(jsonb_build_object('caja_id', v_caja.id));
end;
$$;

-- Resumen de una caja (la abierta si p_caja_id es nulo). El detalle del
-- efectivo esperado solo para el Dueño.
create function public.resumen_caja(p_caja_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_caja     public.cajas;
  v_ef       record;
  v_base     jsonb;
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;

  select * into v_caja from public.cajas c
   where c.empresa_id = v_empresa
     and (c.id = p_caja_id or (p_caja_id is null and c.cerrada_en is null));
  if not found then
    return privado.ok(jsonb_build_object('caja', null));
  end if;

  v_base := jsonb_build_object(
    'caja_id',       v_caja.id,
    'abierta_en',    v_caja.abierta_en,
    'fondo_inicial', v_caja.fondo_inicial::text,
    'cerrada_en',    v_caja.cerrada_en,
    'monto_contado', v_caja.monto_contado::text,
    'ventas',        (select count(*) from public.ventas v where v.caja_id = v_caja.id));

  if privado.mi_rol() is distinct from 'DUENO' then
    return privado.ok(jsonb_build_object('caja', v_base));
  end if;

  select * into v_ef from privado.efectivo_caja(v_caja.id);
  return privado.ok(jsonb_build_object('caja', v_base || jsonb_build_object(
    'ventas_efectivo', v_ef.ventas_efectivo::numeric(12,2)::text,
    'abonos_efectivo', v_ef.abonos_efectivo::numeric(12,2)::text,
    'ingresos',        v_ef.ingresos::numeric(12,2)::text,
    'egresos',         v_ef.egresos::numeric(12,2)::text,
    -- Abierta: el esperado al momento. Cerrada: el que quedó guardado.
    'esperado',        coalesce(v_caja.monto_esperado, v_ef.esperado)::numeric(12,2)::text,
    'diferencia',      v_caja.diferencia::text,
    'explicacion',     v_caja.explicacion_diferencia)));
end;
$$;

create function public.explicar_diferencia_caja(p_caja_id uuid, p_explicacion text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_caja     public.cajas;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if nullif(trim(p_explicacion), '') is null then
    return privado.error('DATOS_INVALIDOS', 'Escribe la explicación');
  end if;
  select * into v_caja from public.cajas c where c.id = p_caja_id and c.empresa_id = v_empresa for update;
  if not found or v_caja.cerrada_en is null then
    return privado.error('DATOS_INVALIDOS', 'La caja no existe o sigue abierta');
  end if;
  if v_caja.explicacion_diferencia is not null then
    return privado.error('DATOS_INVALIDOS', 'La diferencia ya tiene explicación');
  end if;

  update public.cajas c
     set explicacion_diferencia = trim(p_explicacion), explicada_por = auth.uid(), explicada_en = now()
   where c.id = v_caja.id;
  return privado.ok(jsonb_build_object('caja_id', v_caja.id));
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Fiado
-- -----------------------------------------------------------------------------

-- Abono de un cliente. No se abona más de lo que debe. El efectivo entra a la
-- caja abierta.
create function public.registrar_abono(p_cliente_id uuid, p_monto numeric, p_medio text, p_clave_idempotencia uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_cliente  public.clientes;
  v_saldo    numeric;
  v_monto    numeric := round(p_monto, 2);
  v_caja     uuid;
  v_id       uuid;
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la clave de idempotencia');
  end if;
  select f.id into v_id from public.fiado_movimientos f
   where f.empresa_id = v_empresa and f.clave_idempotencia = p_clave_idempotencia;
  if found then
    return privado.ok(jsonb_build_object('movimiento_id', v_id, 'repetido', true,
                                         'saldo', privado.saldo_fiado(p_cliente_id)::numeric(12,2)::text));
  end if;

  if p_medio is null or p_medio not in ('EFECTIVO', 'TRANSFERENCIA', 'TARJETA') then
    return privado.error('DATOS_INVALIDOS', 'Medio de pago no válido');
  end if;
  if v_monto is null or v_monto <= 0 then
    return privado.error('DATOS_INVALIDOS', 'El abono debe ser mayor que cero');
  end if;

  -- Bloquea al cliente: abonos y ventas al fiado simultáneos se ordenan.
  select * into v_cliente from public.clientes c
   where c.id = p_cliente_id and c.empresa_id = v_empresa
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'El cliente no existe');
  end if;
  v_saldo := privado.saldo_fiado(v_cliente.id);
  if v_monto > v_saldo then
    return privado.error('DATOS_INVALIDOS', 'El abono supera lo que debe el cliente',
      jsonb_build_object('saldo', v_saldo::numeric(12,2)::text));
  end if;

  if p_medio = 'EFECTIVO' then
    v_caja := privado.caja_abierta(v_empresa);
    if v_caja is null then
      return privado.error('CAJA_CERRADA', 'Abre la caja para recibir efectivo');
    end if;
  end if;

  insert into public.fiado_movimientos (empresa_id, cliente_id, tipo, monto, medio, caja_id,
                                        clave_idempotencia, creado_por)
  values (v_empresa, v_cliente.id, 'ABONO', -v_monto, p_medio, v_caja, p_clave_idempotencia, auth.uid())
  returning id into v_id;

  return privado.ok(jsonb_build_object('movimiento_id', v_id, 'repetido', false,
                                       'saldo', (v_saldo - v_monto)::numeric(12,2)::text));
exception
  when unique_violation then
    select f.id into v_id from public.fiado_movimientos f
     where f.empresa_id = v_empresa and f.clave_idempotencia = p_clave_idempotencia;
    return privado.ok(jsonb_build_object('movimiento_id', v_id, 'repetido', true,
                                         'saldo', privado.saldo_fiado(p_cliente_id)::numeric(12,2)::text));
end;
$$;

-- Corrección de la cuenta de un cliente (Fase 3: «se corrige con AJUSTE»).
-- Monto con signo: positivo aumenta la deuda, negativo la reduce.
create function public.ajustar_fiado(p_cliente_id uuid, p_monto numeric, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa  uuid := privado.mi_empresa();
  v_cliente  public.clientes;
  v_id       uuid;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_monto is null or round(p_monto, 2) = 0 then
    return privado.error('DATOS_INVALIDOS', 'El ajuste no puede ser cero');
  end if;
  if nullif(trim(p_motivo), '') is null then
    return privado.error('DATOS_INVALIDOS', 'El motivo es obligatorio');
  end if;
  select * into v_cliente from public.clientes c
   where c.id = p_cliente_id and c.empresa_id = v_empresa
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'El cliente no existe');
  end if;

  insert into public.fiado_movimientos (empresa_id, cliente_id, tipo, monto, motivo, creado_por)
  values (v_empresa, v_cliente.id, 'AJUSTE', round(p_monto, 2), trim(p_motivo), auth.uid())
  returning id into v_id;

  return privado.ok(jsonb_build_object('movimiento_id', v_id,
                                       'saldo', privado.saldo_fiado(v_cliente.id)::numeric(12,2)::text));
end;
$$;

-- Clientes con fiado autorizado o con saldo: cuánto deben y cuánto les queda.
create function public.cuentas_fiado()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_empresa uuid := privado.mi_empresa();
begin
  if v_empresa is null then
    return privado.error('SIN_PERMISO');
  end if;
  return privado.ok(jsonb_build_object('clientes', coalesce((
    select jsonb_agg(jsonb_build_object(
             'cliente_id',      c.id,
             'nombre',          c.nombre,
             'fiado_permitido', c.fiado_permitido,
             'limite',          c.limite_fiado::text,
             'saldo',           s.saldo::numeric(12,2)::text,
             'disponible',      greatest(c.limite_fiado - s.saldo, 0)::numeric(12,2)::text)
           order by s.saldo desc, c.nombre)
      from public.clientes c
      cross join lateral (select privado.saldo_fiado(c.id) as saldo) s
     where c.empresa_id = v_empresa and (c.fiado_permitido or s.saldo <> 0)), '[]'::jsonb)));
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Ventas con caja y fiado (reemplazan las de la migración 0004)
-- -----------------------------------------------------------------------------
-- Cambios respecto de la versión anterior:
--   * el pago FIADO necesita cliente; el Vendedor solo fía a clientes
--     autorizados y dentro del límite (Fase 4); se bloquea al cliente para
--     que dos ventas a la vez no pasen el límite
--   * el efectivo necesita la caja abierta (HU-04); la venta queda en esa caja
create or replace function public.registrar_venta(
  p_lineas              jsonb,
  p_pagos               jsonb,
  p_cliente_id          uuid,
  p_tipo_comprobante    text,
  p_clave_idempotencia  uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa   public.empresas;
  v_rol       text := privado.mi_rol();
  v_id        uuid := gen_random_uuid();
  v_fecha     date;
  v_tipo      text := coalesce(p_tipo_comprobante, 'NOTA_VENTA');
  v_cliente   public.clientes;
  v_existente public.ventas;
  v_lineas    privado.linea_venta[];
  v_linea     privado.linea_venta;
  v_total     numeric;
  v_pagos     jsonb;
  v_pagado    numeric;
  v_efectivo  numeric;
  v_fiado     numeric;
  v_saldo     numeric;
  v_caja      uuid;
  v_mov       public.movimientos_inventario;
  v_costos    jsonb := '{}';
  v_detalle   text;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la clave de idempotencia');
  end if;

  select * into v_existente
    from public.ventas v
   where v.empresa_id = v_empresa.id and v.clave_idempotencia = p_clave_idempotencia;
  if found then
    return privado.ok(jsonb_build_object('venta_id', v_existente.id, 'repetido', true,
                                         'total', v_existente.total::text));
  end if;

  if v_tipo not in ('NOTA_VENTA', 'FACTURA', 'NINGUNO_PERMITIDO') then
    return privado.error('DATOS_INVALIDOS', 'Tipo de comprobante no válido');
  end if;
  if p_cliente_id is not null then
    select * into v_cliente from public.clientes c
     where c.id = p_cliente_id and c.empresa_id = v_empresa.id and c.activo;
    if not found then
      return privado.error('DATOS_INVALIDOS', 'El cliente no existe o está inactivo');
    end if;
  end if;

  select array_agg(l order by l.orden) into v_lineas
    from privado.calcular_lineas_venta(v_empresa.id, v_rol, p_lineas) l;
  select sum(l.total) into v_total from unnest(v_lineas) l;

  -- Comprobante (D-005; montos configurables por el contador)
  if v_tipo = 'FACTURA' and v_total > v_empresa.monto_max_consumidor_final
     and v_cliente.identificacion is null then
    return privado.error('DATOS_INVALIDOS',
      'Una factura de más de ' || v_empresa.monto_max_consumidor_final::text
        || ' necesita un cliente con RUC o cédula');
  end if;
  if v_tipo = 'NINGUNO_PERMITIDO' and v_total > v_empresa.monto_max_sin_comprobante then
    return privado.error('DATOS_INVALIDOS', 'Esta venta necesita comprobante');
  end if;

  -- Pagos
  v_pagos := coalesce(p_pagos, case when v_total > 0
                                    then jsonb_build_array(jsonb_build_object('medio', 'EFECTIVO', 'monto', v_total))
                                    else '[]'::jsonb end);
  if jsonb_typeof(v_pagos) <> 'array' then
    return privado.error('DATOS_INVALIDOS', 'Pagos mal formados');
  end if;
  begin
    select coalesce(sum(round((p ->> 'monto')::numeric, 2)), 0),
           coalesce(sum(round((p ->> 'monto')::numeric, 2)) filter (where p ->> 'medio' = 'EFECTIVO'), 0),
           coalesce(sum(round((p ->> 'monto')::numeric, 2)) filter (where p ->> 'medio' = 'FIADO'), 0)
      into v_pagado, v_efectivo, v_fiado
      from jsonb_array_elements(v_pagos) p;
  exception
    when invalid_text_representation or numeric_value_out_of_range then
      return privado.error('DATOS_INVALIDOS', 'Un monto de pago está mal escrito');
  end;
  if v_pagado <> v_total then
    return privado.error('DATOS_INVALIDOS', 'Los pagos no suman el total de la venta',
      jsonb_build_object('total', v_total::numeric(12,2)::text, 'pagado', v_pagado::numeric(12,2)::text));
  end if;

  -- Fiado (Fase 4): con cliente; el Vendedor, solo autorizado y dentro del límite.
  if v_fiado > 0 then
    if p_cliente_id is null then
      return privado.error('DATOS_INVALIDOS', 'Elige el cliente que se lleva al fiado');
    end if;
    select * into v_cliente from public.clientes c where c.id = p_cliente_id for update;
    v_saldo := privado.saldo_fiado(v_cliente.id);
    if v_rol <> 'DUENO' then
      if not v_cliente.fiado_permitido then
        return privado.error('LIMITE_FIADO', v_cliente.nombre || ' no tiene fiado autorizado');
      end if;
      if v_saldo + v_fiado > v_cliente.limite_fiado then
        return privado.error('LIMITE_FIADO',
          v_cliente.nombre || ' supera su límite de fiado (disponible '
            || greatest(v_cliente.limite_fiado - v_saldo, 0)::numeric(12,2)::text || ')',
          jsonb_build_object('saldo', v_saldo::numeric(12,2)::text,
                             'limite', v_cliente.limite_fiado::text,
                             'disponible', greatest(v_cliente.limite_fiado - v_saldo, 0)::numeric(12,2)::text));
      end if;
    end if;
  end if;

  -- Caja (HU-04): sin caja abierta no se cobra en efectivo.
  v_caja := privado.caja_abierta(v_empresa.id);
  if v_efectivo > 0 and v_caja is null then
    return privado.error('CAJA_CERRADA', 'Abre la caja para cobrar en efectivo');
  end if;

  v_fecha := (now() at time zone v_empresa.zona_horaria)::date;

  -- Salidas de inventario primero (en orden de producto, para no bloquearse en
  -- cruz con otra venta): así cada línea guarda el costo con que salió.
  for v_linea in select * from unnest(v_lineas) l order by l.producto_id, l.orden loop
    v_mov := privado.registrar_movimiento(
      v_empresa.id, v_linea.producto_id, 'VENTA', -v_linea.cantidad_base, null,
      'ventas', v_id, null, null, v_fecha);
    v_costos := v_costos || jsonb_build_object(v_linea.orden::text, jsonb_build_object(
      'costo_unitario', v_mov.costo_unitario, 'costo_total', -v_mov.valor));
  end loop;

  insert into public.ventas (id, empresa_id, fecha, cliente_id, caja_id, tipo_comprobante, subtotal, descuento,
                             iva, total, costo_total, precios_incluyen_iva, clave_idempotencia, creado_por)
  select v_id, v_empresa.id, v_fecha, p_cliente_id, v_caja, v_tipo,
         sum(l.subtotal), sum(l.descuento), sum(l.iva), sum(l.total),
         sum((v_costos -> l.orden::text ->> 'costo_total')::numeric),
         v_empresa.precios_incluyen_iva, p_clave_idempotencia, auth.uid()
    from unnest(v_lineas) l;

  insert into public.venta_detalles (empresa_id, venta_id, orden, presentacion_id, producto_id, cantidad,
                                     precio_unitario, tarifa_iva, subtotal, descuento, iva, total,
                                     cantidad_base, costo_unitario, costo_total)
  select v_empresa.id, v_id, l.orden, l.presentacion_id, l.producto_id, l.cantidad,
         l.precio_unitario, l.tarifa_iva, l.subtotal, l.descuento, l.iva, l.total, l.cantidad_base,
         (v_costos -> l.orden::text ->> 'costo_unitario')::numeric,
         (v_costos -> l.orden::text ->> 'costo_total')::numeric
    from unnest(v_lineas) l;

  insert into public.venta_pagos (empresa_id, venta_id, medio, monto)
  select v_empresa.id, v_id, p ->> 'medio', round((p ->> 'monto')::numeric, 2)
    from jsonb_array_elements(v_pagos) p;

  if v_fiado > 0 then
    insert into public.fiado_movimientos (empresa_id, cliente_id, tipo, monto, venta_id, creado_por)
    values (v_empresa.id, p_cliente_id, 'CARGO', v_fiado, v_id, auth.uid());
  end if;

  return privado.ok(jsonb_build_object('venta_id', v_id, 'repetido', false, 'total', v_total::numeric(12,2)::text));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return privado.explicar_error_venta(v_detalle);
  when check_violation then
    get stacked diagnostics v_detalle = constraint_name;
    return privado.error('DATOS_INVALIDOS',
      case v_detalle when 'venta_pagos_monto' then 'Cada pago debe ser mayor que cero'
                     when 'venta_pagos_medio' then 'Medio de pago no válido'
                     else null end);
  when unique_violation then
    -- Dos toques simultáneos con la misma clave: el primero ya confirmó la
    -- venta (la unicidad esperó a que terminara); se devuelve esa misma.
    select * into v_existente from public.ventas v
     where v.empresa_id = v_empresa.id and v.clave_idempotencia = p_clave_idempotencia;
    if found then
      return privado.ok(jsonb_build_object('venta_id', v_existente.id, 'repetido', true,
                                           'total', v_existente.total::text));
    end if;
    return privado.error('DUPLICADO');
end;
$$;

-- Cambios: el efectivo cobrado sale de la caja abierta (egreso automático) y
-- lo fiado se descuenta del saldo del cliente (ajuste).
create or replace function public.anular_venta(p_venta_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa   uuid := privado.mi_empresa();
  v_venta     public.ventas;
  v_linea     public.venta_detalles;
  v_efectivo  numeric;
  v_fiado     numeric;
  v_caja      uuid;
  v_detalle   text;
begin
  if v_empresa is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO', 'Solo el Dueño anula ventas; puedes solicitar la anulación');
  end if;
  if nullif(trim(p_motivo), '') is null then
    return privado.error('DATOS_INVALIDOS', 'El motivo es obligatorio');
  end if;

  select * into v_venta from public.ventas v
   where v.id = p_venta_id and v.empresa_id = v_empresa
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La venta no existe');
  end if;
  if v_venta.estado = 'ANULADA' then
    return privado.ok(jsonb_build_object('venta_id', v_venta.id, 'repetido', true));
  end if;
  if exists (select 1 from public.devoluciones d where d.venta_id = v_venta.id) then
    return privado.error('DATOS_INVALIDOS', 'La venta tiene devoluciones: devuelve lo que falta en lugar de anular');
  end if;

  select coalesce(sum(p.monto) filter (where p.medio = 'EFECTIVO'), 0),
         coalesce(sum(p.monto) filter (where p.medio = 'FIADO'), 0)
    into v_efectivo, v_fiado
    from public.venta_pagos p where p.venta_id = v_venta.id;

  if v_efectivo > 0 then
    v_caja := privado.caja_abierta(v_empresa);
    if v_caja is null then
      return privado.error('CAJA_CERRADA', 'Abre la caja para devolver el efectivo de la venta');
    end if;
  end if;

  for v_linea in
    select * from public.venta_detalles d where d.venta_id = v_venta.id order by d.producto_id, d.orden
  loop
    perform privado.registrar_movimiento(
      v_empresa, v_linea.producto_id, 'ANULACION_VENTA', v_linea.cantidad_base, v_linea.costo_unitario,
      'ventas', v_venta.id, trim(p_motivo));
  end loop;

  update public.ventas v
     set estado = 'ANULADA', motivo_anulacion = trim(p_motivo), anulada_en = now(), anulada_por = auth.uid()
   where v.id = v_venta.id;

  if v_efectivo > 0 then
    insert into public.caja_movimientos (empresa_id, caja_id, tipo, monto, motivo, venta_id, automatico, creado_por)
    values (v_empresa, v_caja, 'EGRESO', v_efectivo, 'Anulación de venta: ' || trim(p_motivo),
            v_venta.id, true, auth.uid());
  end if;
  if v_fiado > 0 then
    perform 1 from public.clientes c where c.id = v_venta.cliente_id for update;
    insert into public.fiado_movimientos (empresa_id, cliente_id, tipo, monto, venta_id, motivo, creado_por)
    values (v_empresa, v_venta.cliente_id, 'AJUSTE', -v_fiado, v_venta.id,
            'Anulación de venta: ' || trim(p_motivo), auth.uid());
  end if;

  insert into public.auditoria (empresa_id, usuario_id, accion, tabla, registro_id, antes, despues)
  values (v_empresa, auth.uid(), 'VENTA_ANULADA', 'ventas', v_venta.id,
          jsonb_build_object('estado', 'CONFIRMADA', 'total', v_venta.total),
          jsonb_build_object('estado', 'ANULADA', 'motivo', trim(p_motivo)));

  return privado.ok(jsonb_build_object('venta_id', v_venta.id, 'repetido', false));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
end;
$$;

-- Cambios: EFECTIVO sale de la caja abierta (egreso automático); ABONO_FIADO
-- reduce la deuda del cliente de la venta, sin pasar de lo que debe.
create or replace function public.registrar_devolucion(
  p_venta_id            uuid,
  p_lineas              jsonb,
  p_motivo              text,
  p_forma_reintegro     text,
  p_clave_idempotencia  uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa    public.empresas;
  v_venta      public.ventas;
  v_existente  public.devoluciones;
  v_id         uuid := gen_random_uuid();
  v_forma      text := coalesce(p_forma_reintegro, 'EFECTIVO');
  v_fecha      date;
  v_entrada    record;
  v_d          public.venta_detalles;
  v_previo     record;
  v_cantidad   numeric;
  v_cant_base  numeric;
  v_total      numeric;
  v_subtotal   numeric;
  v_calculo    jsonb := '[]';
  v_reintegro  numeric;
  v_caja       uuid;
  v_mov        public.movimientos_inventario;
  v_detalle    text;
begin
  select * into v_empresa from public.empresas e where e.id = privado.mi_empresa();
  if v_empresa.id is null or privado.mi_rol() is distinct from 'DUENO' then
    return privado.error('SIN_PERMISO');
  end if;
  if p_clave_idempotencia is null then
    return privado.error('DATOS_INVALIDOS', 'Falta la clave de idempotencia');
  end if;

  select * into v_existente from public.devoluciones d
   where d.empresa_id = v_empresa.id and d.clave_idempotencia = p_clave_idempotencia;
  if found then
    return privado.ok(jsonb_build_object('devolucion_id', v_existente.id, 'repetido', true,
                                         'total', v_existente.total::text));
  end if;

  if nullif(trim(p_motivo), '') is null then
    return privado.error('DATOS_INVALIDOS', 'El motivo es obligatorio');
  end if;
  if v_forma not in ('EFECTIVO', 'ABONO_FIADO') then
    return privado.error('DATOS_INVALIDOS', 'Forma de reintegro no válida');
  end if;
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    return privado.error('DATOS_INVALIDOS', 'Indica qué se devuelve');
  end if;

  -- Bloquea la venta: dos devoluciones a la vez no pueden pasar del total vendido.
  select * into v_venta from public.ventas v
   where v.id = p_venta_id and v.empresa_id = v_empresa.id
     for update;
  if not found then
    return privado.error('DATOS_INVALIDOS', 'La venta no existe');
  end if;
  if v_venta.estado <> 'CONFIRMADA' then
    return privado.error('DATOS_INVALIDOS', 'La venta está anulada');
  end if;
  if (select count(*) from jsonb_array_elements(p_lineas) l)
     <> (select count(distinct l ->> 'venta_detalle_id') from jsonb_array_elements(p_lineas) l) then
    return privado.error('DATOS_INVALIDOS', 'Una línea de la venta aparece dos veces');
  end if;
  if v_forma = 'ABONO_FIADO' and v_venta.cliente_id is null then
    return privado.error('DATOS_INVALIDOS', 'La venta no tiene cliente: reintegra en efectivo');
  end if;

  v_fecha := (now() at time zone v_empresa.zona_horaria)::date;

  -- 1) Validar y calcular cada línea (la cabecera necesita los totales y la
  --    tabla es de solo inserción).
  for v_entrada in
    select (l ->> 'venta_detalle_id')::uuid as detalle_id, l ->> 'cantidad' as cantidad
      from jsonb_array_elements(p_lineas) l
     order by 1
  loop
    select * into v_d from public.venta_detalles d
     where d.id = v_entrada.detalle_id and d.venta_id = v_venta.id;
    if not found then
      perform privado.fallar('DATOS_INVALIDOS', 'La línea no pertenece a esta venta');
    end if;

    v_cantidad := round(v_entrada.cantidad::numeric, 3);
    select coalesce(sum(x.cantidad), 0) as cantidad, coalesce(sum(x.cantidad_base), 0) as cantidad_base,
           coalesce(sum(x.total), 0) as total, coalesce(sum(x.subtotal), 0) as subtotal
      into v_previo
      from public.devolucion_detalles x where x.venta_detalle_id = v_d.id;

    if v_cantidad is null or v_cantidad <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad a devolver debe ser mayor que cero');
    end if;
    if v_cantidad > v_d.cantidad - v_previo.cantidad then
      perform privado.fallar('DATOS_INVALIDOS',
        'No se puede devolver más de lo vendido (quedan '
          || trim(trailing '.' from trim(trailing '0' from (v_d.cantidad - v_previo.cantidad)::text)) || ')');
    end if;

    if v_cantidad = v_d.cantidad - v_previo.cantidad then
      v_cant_base := v_d.cantidad_base - v_previo.cantidad_base;
      v_total     := v_d.total - v_previo.total;
      v_subtotal  := (v_d.subtotal - v_d.descuento) - v_previo.subtotal;
    else
      v_cant_base := round(v_d.cantidad_base * v_cantidad / v_d.cantidad, 3);
      v_total     := round(v_d.total * v_cantidad / v_d.cantidad, 2);
      v_subtotal  := round((v_d.subtotal - v_d.descuento) * v_cantidad / v_d.cantidad, 2);
    end if;
    if v_cant_base <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad a devolver es demasiado pequeña');
    end if;

    v_calculo := v_calculo || jsonb_build_array(jsonb_build_object(
      'detalle_id', v_d.id, 'producto_id', v_d.producto_id, 'costo_unitario', v_d.costo_unitario,
      'cantidad', v_cantidad, 'cantidad_base', v_cant_base, 'subtotal', v_subtotal, 'total', v_total));
  end loop;

  select sum((c ->> 'total')::numeric) into v_reintegro from jsonb_array_elements(v_calculo) c;

  -- 2) Reintegro: efectivo de la caja abierta, o abono a la deuda del cliente.
  if v_forma = 'EFECTIVO' and v_reintegro > 0 then
    v_caja := privado.caja_abierta(v_empresa.id);
    if v_caja is null then
      return privado.error('CAJA_CERRADA', 'Abre la caja para devolver el efectivo');
    end if;
  end if;
  if v_forma = 'ABONO_FIADO' then
    perform 1 from public.clientes c where c.id = v_venta.cliente_id for update;
    if v_reintegro > privado.saldo_fiado(v_venta.cliente_id) then
      return privado.error('DATOS_INVALIDOS', 'El reintegro supera lo que debe el cliente: reintegra en efectivo',
        jsonb_build_object('saldo', privado.saldo_fiado(v_venta.cliente_id)::numeric(12,2)::text));
    end if;
  end if;

  -- 3) Cabecera con sus totales.
  insert into public.devoluciones (id, empresa_id, venta_id, fecha, motivo, subtotal, iva, total,
                                   forma_reintegro, caja_id, clave_idempotencia, creado_por)
  select v_id, v_empresa.id, v_venta.id, v_fecha, trim(p_motivo),
         sum((c ->> 'subtotal')::numeric), sum((c ->> 'total')::numeric - (c ->> 'subtotal')::numeric),
         sum((c ->> 'total')::numeric), v_forma, v_caja, p_clave_idempotencia, auth.uid()
    from jsonb_array_elements(v_calculo) c;

  -- 4) Entradas al inventario al costo con que salió cada línea, y sus líneas.
  for v_entrada in
    select c from jsonb_array_elements(v_calculo) c order by c ->> 'producto_id', c ->> 'detalle_id'
  loop
    v_mov := privado.registrar_movimiento(
      v_empresa.id, (v_entrada.c ->> 'producto_id')::uuid, 'DEVOLUCION_VENTA',
      (v_entrada.c ->> 'cantidad_base')::numeric, (v_entrada.c ->> 'costo_unitario')::numeric,
      'devoluciones', v_id, trim(p_motivo), null, v_fecha);

    insert into public.devolucion_detalles (empresa_id, devolucion_id, venta_detalle_id, cantidad, cantidad_base,
                                            subtotal, iva, total, costo_unitario, costo_total)
    values (v_empresa.id, v_id, (v_entrada.c ->> 'detalle_id')::uuid,
            (v_entrada.c ->> 'cantidad')::numeric, (v_entrada.c ->> 'cantidad_base')::numeric,
            (v_entrada.c ->> 'subtotal')::numeric,
            (v_entrada.c ->> 'total')::numeric - (v_entrada.c ->> 'subtotal')::numeric,
            (v_entrada.c ->> 'total')::numeric,
            (v_entrada.c ->> 'costo_unitario')::numeric, v_mov.valor);
  end loop;

  -- 5) El dinero.
  if v_forma = 'EFECTIVO' and v_reintegro > 0 then
    insert into public.caja_movimientos (empresa_id, caja_id, tipo, monto, motivo, devolucion_id, automatico, creado_por)
    values (v_empresa.id, v_caja, 'EGRESO', v_reintegro, 'Devolución: ' || trim(p_motivo), v_id, true, auth.uid());
  end if;
  if v_forma = 'ABONO_FIADO' and v_reintegro > 0 then
    insert into public.fiado_movimientos (empresa_id, cliente_id, tipo, monto, devolucion_id, motivo, creado_por)
    values (v_empresa.id, v_venta.cliente_id, 'AJUSTE', -v_reintegro, v_id, 'Devolución: ' || trim(p_motivo), auth.uid());
  end if;

  return privado.ok(jsonb_build_object('devolucion_id', v_id, 'repetido', false,
                                       'total', v_reintegro::numeric(12,2)::text));
exception
  when sqlstate 'NG001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    return v_detalle::jsonb;
  when invalid_text_representation or numeric_value_out_of_range then
    return privado.error('DATOS_INVALIDOS', 'Hay un número mal escrito');
  when unique_violation then
    select * into v_existente from public.devoluciones d
     where d.empresa_id = v_empresa.id and d.clave_idempotencia = p_clave_idempotencia;
    if found then
      return privado.ok(jsonb_build_object('devolucion_id', v_existente.id, 'repetido', true,
                                           'total', v_existente.total::text));
    end if;
    return privado.error('DUPLICADO');
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Permisos de las funciones
-- -----------------------------------------------------------------------------
revoke all on function
  privado.caja_cambios_permitidos(),
  privado.caja_abierta(uuid),
  privado.efectivo_caja(uuid),
  privado.saldo_fiado(uuid)
  from public, anon, authenticated;

revoke all on function
  public.abrir_caja(numeric),
  public.movimiento_caja(text, numeric, text, uuid),
  public.cerrar_caja(numeric, text),
  public.resumen_caja(uuid),
  public.explicar_diferencia_caja(uuid, text),
  public.registrar_abono(uuid, numeric, text, uuid),
  public.ajustar_fiado(uuid, numeric, text),
  public.cuentas_fiado()
  from public, anon;
grant execute on function
  public.abrir_caja(numeric),
  public.movimiento_caja(text, numeric, text, uuid),
  public.cerrar_caja(numeric, text),
  public.resumen_caja(uuid),
  public.explicar_diferencia_caja(uuid, text),
  public.registrar_abono(uuid, numeric, text, uuid),
  public.ajustar_fiado(uuid, numeric, text),
  public.cuentas_fiado()
  to authenticated;
