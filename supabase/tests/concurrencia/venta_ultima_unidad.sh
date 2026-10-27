#!/usr/bin/env bash
# =============================================================================
# Pruebas de concurrencia con dos conexiones reales:
#  1. (Fase 3, «Casos que el modelo debe resolver») dos cajeros venden la
#     última unidad al mismo tiempo: una venta se confirma y la otra recibe
#     STOCK_INSUFICIENTE.
#  2. (HU-02) dos toques de «Cobrar» llegan a la vez con la misma clave: se
#     guarda una sola venta y ambos reciben respuesta correcta (la segunda,
#     «repetida»).
#
# pgTAP corre en una sola sesión y no puede probar esto: aquí se abren dos
# conexiones reales a la base local. La sesión A vende y espera 3 segundos
# antes de confirmar; la sesión B intenta vender mientras tanto y debe esperar
# el bloqueo de la fila de existencias y luego ver el stock en cero.
#
# Uso (con Supabase local encendido):  bash supabase/tests/concurrencia/venta_ultima_unidad.sh
# Deja la base como estaba: borra al final los datos que crea.
# =============================================================================
set -euo pipefail

CONTENEDOR="supabase_db_${PROYECTO_SUPABASE:-NuevoInventario}"
psql_como() { docker exec -i "$CONTENEDOR" psql -U "$1" -d postgres -v ON_ERROR_STOP=1 -qAt; }

EMPRESA='cccccccc-1111-1111-1111-000000000000'
USUARIO='cccccccc-1111-1111-1111-00000000a001'
CLAIMS="{\"sub\":\"$USUARIO\",\"role\":\"authenticated\"}"

limpiar() {
  # Los libros son de solo inserción; para borrar los datos de prueba se
  # desactivan los triggers solo en esta sesión de administración.
  psql_como supabase_admin <<SQL >/dev/null
set session_replication_role = replica;
delete from public.venta_pagos         where empresa_id = '$EMPRESA';
delete from public.venta_detalles      where empresa_id = '$EMPRESA';
delete from public.ventas              where empresa_id = '$EMPRESA';
delete from public.movimientos_inventario where empresa_id = '$EMPRESA';
delete from public.existencias         where empresa_id = '$EMPRESA';
delete from public.presentaciones      where empresa_id = '$EMPRESA';
delete from public.productos           where empresa_id = '$EMPRESA';
delete from public.auditoria           where empresa_id = '$EMPRESA';
delete from public.membresias          where empresa_id = '$EMPRESA';
delete from public.perfiles            where id = '$USUARIO';
delete from public.empresas            where id = '$EMPRESA';
delete from auth.users                 where id = '$USUARIO';
SQL
}
trap limpiar EXIT
limpiar

# Datos: una empresa, un Dueño y un producto con UNA unidad en stock.
psql_como postgres <<SQL >/dev/null
insert into auth.users (id, email) values ('$USUARIO', 'concurrencia@prueba.test');
insert into public.empresas (id, ruc, razon_social) values ('$EMPRESA', '0999999999999', 'Bodega Concurrencia');
insert into public.perfiles (id, nombre) values ('$USUARIO', 'Cajero');
insert into public.membresias (empresa_id, usuario_id, rol) values ('$EMPRESA', '$USUARIO', 'DUENO');
select set_config('request.jwt.claims', '$CLAIMS', false);
select public.guardar_producto(null, '{"nombre":"Último aceite","tarifa_iva":15,"precio_venta":3.45}');
select public.ajustar_inventario(p.id, 'APERTURA', 1, 2) from public.productos p where p.empresa_id = '$EMPRESA';
select public.guardar_producto(null, '{"nombre":"Cola","tarifa_iva":15,"precio_venta":2.50}');
select public.ajustar_inventario(p.id, 'APERTURA', 5, 1) from public.productos p
 where p.empresa_id = '$EMPRESA' and p.nombre = 'Cola';
SQL

PRESENTACION=$(psql_como postgres <<SQL
select r.id from public.presentaciones r join public.productos p on p.id = r.producto_id
 where r.empresa_id = '$EMPRESA' and p.nombre = 'Último aceite';
SQL
)
COLA=$(psql_como postgres <<SQL
select r.id from public.presentaciones r join public.productos p on p.id = r.producto_id
 where r.empresa_id = '$EMPRESA' and p.nombre = 'Cola';
SQL
)

vender() {  # $1 = segundos de espera antes de confirmar; $2 = presentación; $3 = clave (opcional)
  psql_como postgres <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$CLAIMS', true);
select coalesce(r -> 'error' ->> 'codigo', case when (r -> 'data' ->> 'repetido')::boolean then 'REPETIDO' else 'OK' end)
  from (select public.registrar_venta(
          '[{"presentacion_id":"$2","cantidad":1}]', null, null, null,
          coalesce(nullif('${3:-}', ''), gen_random_uuid()::text)::uuid) r) x;
select pg_sleep($1);
commit;
SQL
}

a_la_vez() {  # $1 = presentación; $2 = clave compartida (opcional). Deja A y B.
  local salida_a salida_b
  salida_a=$(mktemp); salida_b=$(mktemp)
  vender 3 "$1" "${2:-}" >"$salida_a" &
  local pid_a=$!
  sleep 1
  vender 0 "$1" "${2:-}" >"$salida_b" &
  wait "$pid_a" $!
  A=$(grep -E '^[A-Z_]+$' "$salida_a" | head -1)
  B=$(grep -E '^[A-Z_]+$' "$salida_b" | head -1)
  rm -f "$salida_a" "$salida_b"
}

resumen() {  # $1 = nombre del producto
  psql_como postgres <<SQL
select (select count(*) from public.ventas v join public.venta_detalles d on d.venta_id = v.id
         join public.productos p on p.id = d.producto_id
        where v.empresa_id = '$EMPRESA' and p.nombre = '$1') || ' ' ||
       (select x.cantidad from public.existencias x join public.productos p on p.id = x.producto_id
         where x.empresa_id = '$EMPRESA' and p.nombre = '$1');
SQL
}

FALLAS=0

a_la_vez "$PRESENTACION"
R=$(resumen 'Último aceite')
echo "1. Última unidad — A: $A · B: $B · ventas y stock: $R"
if [[ "$A" == "OK" && "$B" == "STOCK_INSUFICIENTE" && "$R" == "1 0.000" ]]; then
  echo "ok 1 - una venta se confirma y la otra recibe STOCK_INSUFICIENTE"
else
  echo "FALLA 1 - se esperaba A=OK, B=STOCK_INSUFICIENTE, 1 venta y stock 0.000" >&2; FALLAS=1
fi

a_la_vez "$COLA" 'cccccccc-1111-1111-1111-0000000000c1'
R=$(resumen 'Cola')
echo "2. Doble toque — A: $A · B: $B · ventas y stock: $R"
if [[ "$A" == "OK" && "$B" == "REPETIDO" && "$R" == "1 4.000" ]]; then
  echo "ok 2 - dos toques simultáneos guardan una sola venta y ambos responden bien"
else
  echo "FALLA 2 - se esperaba A=OK, B=REPETIDO, 1 venta y stock 4.000" >&2; FALLAS=1
fi

exit "$FALLAS"
