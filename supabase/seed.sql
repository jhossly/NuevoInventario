-- =============================================================================
-- Datos de prueba SOLO para la base local. `npx supabase db reset` los carga
-- después de las migraciones. Nunca se ejecutan en producción.
--
-- Usuarios locales (contraseña de prueba: Bodega-local-2026):
--   dueno@bodega.test     Dueño
--   vendedor@bodega.test  Vendedor
--
-- El catálogo y el stock inicial se cargan con las funciones públicas, como
-- lo haría el Dueño desde la app, para que el seed pase por las mismas reglas.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Usuarios (Auth necesita los campos de token en '' y una identidad de email)
-- -----------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  email_change_token_current, phone_change, phone_change_token, reauthentication_token)
select
  '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
  extensions.crypt('Bodega-local-2026', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', jsonb_build_object('nombre', u.nombre), now(), now(),
  '', '', '', '', '', '', '', ''
from (values
  ('11111111-1111-1111-1111-111111111111'::uuid, 'dueno@bodega.test',    'Dueño de prueba'),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'vendedor@bodega.test', 'Vendedor de prueba')
) as u(id, email, nombre);

insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select u.id::text, u.id,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email', now(), now(), now()
  from auth.users u
 where u.email in ('dueno@bodega.test', 'vendedor@bodega.test');

-- -----------------------------------------------------------------------------
-- Empresa y membresías
-- -----------------------------------------------------------------------------
insert into public.empresas (id, ruc, razon_social, nombre_comercial) values
  ('eeeeeeee-0000-0000-0000-000000000001', '0999999999001', 'Bodega de Prueba', 'Bodega Local');

insert into public.perfiles (id, nombre) values
  ('11111111-1111-1111-1111-111111111111', 'Dueño de prueba'),
  ('22222222-2222-2222-2222-222222222222', 'Vendedor de prueba');

insert into public.membresias (empresa_id, usuario_id, rol) values
  ('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'DUENO'),
  ('eeeeeeee-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'VENDEDOR');

-- -----------------------------------------------------------------------------
-- Catálogo y stock inicial, actuando como el Dueño
-- -----------------------------------------------------------------------------
do $$
declare
  v_cat      jsonb := '{}';
  v_producto uuid;
  v_r        jsonb;
  p          record;
  x          record;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

  for x in select * from (values ('Aceites'), ('Lácteos'), ('Abarrotes'), ('Bebidas')) c(nombre) loop
    v_r := public.guardar_categoria(null, x.nombre);
    v_cat := v_cat || jsonb_build_object(x.nombre, v_r -> 'data' ->> 'id');
  end loop;

  -- nombre, categoría, unidad, IVA, precio base, código de barras,
  -- presentación extra (nombre, factor, precio, se vende), stock inicial y costo
  for p in select * from (values
    ('Aceite vegetal 1 L',     'Aceites',   'UND', 15, 3.45, '7861001234567', 'Caja 12',     12::numeric,       null::numeric, false, 10::numeric,  2.000000::numeric),
    ('Queso fresco',           'Lácteos',   'KG',   0, 6.00, null,            'Libra',       0.453592,          2.75,          true,  8.500,        4.200000),
    ('Arroz',                  'Abarrotes', 'KG',   0, 1.10, null,            'Libra',       0.453592,          0.55,          true,  45.359,       0.850000),
    ('Azúcar',                 'Abarrotes', 'KG',   0, 1.20, null,            'Libra',       0.453592,          0.60,          true,  20,           0.950000),
    ('Cola 3 L',               'Bebidas',   'UND', 15, 2.50, '7861009876543', 'Paquete 6',   6,                 14.00,         true,  18,           1.750000),
    ('Fósforos',               'Abarrotes', 'UND', 15, 0.10, null,            'Paquete 10',  10,                0.90,          true,  50,           0.060000)
  ) as t(nombre, categoria, unidad, iva, precio, barras, pres, factor, precio_pres, se_vende, stock, costo)
  loop
    v_r := public.guardar_producto(null, jsonb_build_object(
      'nombre', p.nombre, 'categoria_id', v_cat ->> p.categoria, 'unidad_base', p.unidad,
      'tarifa_iva', p.iva, 'precio_venta', p.precio, 'codigo_barras', p.barras));
    if not (v_r ->> 'ok')::boolean then
      raise exception 'seed: % -> %', p.nombre, v_r;
    end if;
    v_producto := (v_r -> 'data' ->> 'id')::uuid;

    v_r := public.guardar_presentacion(null, jsonb_build_object(
      'producto_id', v_producto, 'nombre', p.pres, 'factor', p.factor,
      'precio_venta', p.precio_pres, 'se_vende', p.se_vende));
    if not (v_r ->> 'ok')::boolean then
      raise exception 'seed: % / % -> %', p.nombre, p.pres, v_r;
    end if;

    v_r := public.ajustar_inventario(v_producto, 'APERTURA', p.stock, p.costo);
    if not (v_r ->> 'ok')::boolean then
      raise exception 'seed: apertura de % -> %', p.nombre, v_r;
    end if;
  end loop;

  perform set_config('request.jwt.claims', '', true);
end;
$$;
