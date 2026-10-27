# Continuidad del proyecto

Resumen compacto para retomar el trabajo en una conversación nueva.
**Pégalo completo al inicio de la nueva conversación.** Actualízalo al cerrar cada sesión importante.

Última actualización: 2026-10-28 (Fase 6 cerrada: base de datos e interfaz de catálogo e inventario, probadas en local y en CI)

---

## Producto

Sistema web (PWA) de inventario, compras, ventas, fiado y caja para **una bodega RIMPE Negocio Popular** en Ecuador. Uso propio, sin venta a terceros. Usuarios: el dueño (celular: compras, conteos, consultas) y quien factura (computadora: ventas, caja, reportes). Hoy el dueño factura en el portal gratuito del SRI y descuenta el stock a mano en Excel; el objetivo es eliminar ese doble trabajo.

## Alcance aprobado

- **MVP-1:** catálogo con presentaciones (caja → unidad, kilo, libra), compras con o sin respaldo, inventario con libro inmutable, ventas de mostrador, anulaciones y devoluciones, fiado con límite, caja con apertura y cierre, reportes (margen, stock valorizado, kardex, acumulado frente al límite RIMPE), exportación para el contador e importación de XML autorizados del SRI.
- **MVP-2:** facturación electrónica integrada (generar, firmar con el .p12 del dueño, enviar y autorizar).
- **Fuera:** multiempresa comercial, suscripciones, lotes y vencimientos, FIFO, modo sin conexión, app nativa.

## Decisiones clave

Ver `docs/DECISIONES.md` (D-001 a D-022). Las esenciales: costo promedio ponderado, bloqueo de ventas sin stock, reglas en funciones SQL, libro de movimientos inmutable, cuatro barreras de seguridad y el Vendedor sin ver costos.

## Tecnologías

React 18 + Vite + TypeScript estricto, Tailwind, TanStack Query, Zod, Supabase (PostgreSQL + Auth + RLS + Edge Functions), Vitest, pgTAP, GitHub Actions.

## Documentos de diseño (claude.ai)

- Fase 1 — Requisitos: https://claude.ai/artifact/5z1ZdcfVRn1hnWX9EWd6ca
- Fase 2 — Arquitectura: https://claude.ai/artifact/GQqtHdoGmpwF4ze5bTvrzf
- Fase 3 — Modelo de datos (25 tablas, ejemplos de kardex): https://claude.ai/artifact/TgjLKKw7gv4oUq2b2WaKyc
- Fase 4 — Seguridad (roles, RLS, 18 pruebas, custodia .p12): https://claude.ai/artifact/TTLswDHhLE4XcTsoyYpTzd

## Estado de las fases

| Fase | Estado |
| --- | --- |
| 1. Requisitos y alcance | Aprobada |
| 2. Arquitectura | Aprobada |
| 3. Modelo de datos | Aprobada |
| 4. Seguridad | Aprobada |
| 5. Entorno y estructura | **Cerrada**: verificada en Windows y en GitHub Actions |
| 6. Productos e inventario | **Cerrada**: base de datos e interfaz probadas en local y en GitHub Actions |
| 7. Compras | Siguiente (base de datos) |

## Migraciones

| Archivo | Contenido |
| --- | --- |
| `20261027000000_base_seguridad.sql` | Esquema `privado`, `empresas`, `perfiles`, `membresias`, `auditoria`, `mi_empresa()`, `mi_rol()`, `privado.ok()`/`privado.error()`, trigger de solo inserción, permisos y RLS, función `mi_contexto()` |
| `20261028000000_catalogo_inventario.sql` | `categorias`, `productos`, `presentaciones`, `movimientos_inventario` (inmutable, con `secuencia`), `existencias` (costos ocultos por columna, D-020), `conteos`, `conteo_detalles` (congelados al confirmar). Motor `privado.registrar_movimiento` (promedio ponderado, bloqueo de fila, `STOCK_INSUFICIENTE`). `privado.fallar()` (errores de negocio con SQLSTATE `NG001`) y `privado.ve_costos()`. Expuestas: `guardar_categoria`, `eliminar_categoria`, `guardar_producto`, `guardar_presentacion`, `ajustar_inventario`, `inventario_valorizado`, `guardar_conteo`, `confirmar_conteo` |

Interfaz (Fase 6): ingreso con correo y contraseña; rutas por `#hash` (`src/shared/ruta.ts`); toda lectura pasa por `consultar()` y toda escritura por `llamar()` (`src/lib/datos.ts`), con Zod sobre cada respuesta. Pantallas: lista de productos con búsqueda sin tildes y bajo stock, ficha con presentaciones, alta y edición de producto, ajuste (apertura, ajuste ±, merma) con clave de idempotencia por intento, kardex (solo quien ve costos) y conteo con borrador. Los números escritos se leen con `leerDecimal` (acepta coma, no redondea).

`supabase/seed.sql` (solo local): empresa «Bodega de Prueba», usuarios `dueno@bodega.test` y `vendedor@bodega.test` (contraseña en el propio archivo), 4 categorías, 6 productos con 2 presentaciones cada uno y stock inicial cargado con las funciones públicas. Para la Fase 7, el motor ya acepta COMPRA, VENTA, DEVOLUCION_VENTA y ANULACION_VENTA: compras y ventas solo deben llamarlo.

## Pruebas ejecutadas y resultados reales

| Fecha | Dónde | Qué | Resultado |
| --- | --- | --- | --- |
| 2026-10-27 | Espacio de trabajo de Claude: PostgreSQL 16.15 + pgTAP 1.3.5 con una imitación mínima de Supabase (roles anon/authenticated, `auth.uid()`) | `001_seguridad_base.test.sql` | **24/24 pasan**. Prueba de mutación: con RLS desactivado, un permiso de escritura y una vista sin `security_invoker`, fallan 6/24 como se espera |
| 2026-10-27 | Espacio de trabajo de Claude: Node 22 con un sustituto mínimo de vitest | `formato.test.ts`, `respuesta.test.ts` | **12/12 pasan** |
| 2026-10-27 | Windows 11 del usuario: Node 24.22.0, npm 11.19.1 | `npm install` (184 paquetes), `npm run typecheck`, `npm run build` (vite 5.4.21, JS 463 kB / 128 kB gzip) | **Pasan** |
| 2026-10-27 | Windows 11 del usuario: vitest 2.1.9 real | `formato.test.ts`, `respuesta.test.ts`, `env.test.ts` (nuevo, cubre `leerEnv`) | **17/17 pasan** |
| 2026-10-27 | Windows 11 del usuario: Supabase local real (CLI 2.122.0, imagen postgres 17.11.0.006, pg_prove 3.36) | `npm run db:test` → `001_seguridad_base.test.sql` | **24/24 pasan** |
| 2026-10-27 | GitHub Actions, run 40543041246, commit `0a00ce6` | Trabajos «Tipos, Vitest y build» y «Migraciones y pgTAP» (`.github/workflows/pruebas.yml`) | **Pasan los dos** |
| 2026-10-28 | Windows 11 del usuario: Supabase local, después de `db reset` con seed | `001_seguridad_base` (24) + `002_catalogo_inventario` (62: kardex del aceite fila por fila, reglas, idempotencia, redondeo, Vendedor sin costos, aislamiento, libro inmutable) | **86/86 pasan**. Prueba de mutación: con la salida al último costo y `existencias` sin permiso por columna, fallan 7/62 como se espera |
| 2026-10-28 | GitHub Actions, run 40547661672, commit `e3bfa8d` | Trabajos «Tipos, Vitest y build» y «Migraciones y pgTAP» con la migración `catalogo_inventario` | **Pasan los dos** |
| 2026-10-28 | Windows 11 del usuario: Vitest | 6 archivos: `formato`, `respuesta`, `env`, `rpc`, `decimal`, `ruta` (incluye `nuevaClave`) | **40/40 pasan**; typecheck y build pasan (aviso: JS > 500 kB) |
| 2026-10-28 | Navegador integrado, app local en celular (375×812), datos del seed | Dueño: ingreso, lista con valorizado, merma (stock 10 → 9), merma mayor al stock (`No hay stock suficiente`), kardex, conteo con borrador que sobrevive a recargar y confirmación (queso 8,5 → 8,2; fósforos sin cambio), alta de producto con error de 3 decimales en el precio, presentación «Paquete 4», apertura. Vendedor: lista sin costos, ficha sin edición, ajuste bloqueado | **Todo funciona**; sin errores en consola |
| 2026-10-28 | GitHub Actions, run 40550743078, commit `c644f24` | Trabajos «Tipos, Vitest y build» y «Migraciones y pgTAP» con la interfaz de la Fase 6 | **Pasan los dos** |
| 2026-10-28 | Windows 11 del usuario: API local real | Inicio de sesión de `dueno@bodega.test`, RPC `inventario_valorizado`, lectura directa de `existencias.valor_total` | Sesión ok; RPC devuelve valores como texto; lectura directa rechazada con `42501` |

Aviso de `npm install`: el script `postinstall` de esbuild 0.21.5 no se ejecutó (allowScripts de npm 11). No afectó a vite ni vitest.

## Errores conocidos

Ninguno abierto. Resueltos:

- Docker Desktop no arrancaba: faltaba "Plataforma de máquina virtual" para WSL 2. Se arregló con `wsl --install --no-distribution` (como administrador) y reinicio.
- El primer `supabase start` falló una vez con `DbSetupError` (contenedor sobrante de un arranque interrumpido); al reintentar funcionó sin cambios. Si se repite: `npx supabase stop` y volver a `npx supabase start`.
- El contenedor `supabase_vector` (recolector de logs) se reinicia en bucle; no afecta la base ni las pruebas.

## Hecho en Windows (2026-10-27)

- Git 2.56.0 y Docker Desktop 29.9.2 instalados.
- Repositorio: https://github.com/jhossly/NuevoInventario (rama `main`). Primer commit `0a00ce6`, autor `jhossly <joselynmusuna4.2017@gmail.com>` (config local del repo). El push pide iniciar sesión en el navegador (Git Credential Manager); no hay `gh` instalado.
- `.github/workflows/pruebas.yml` creado en esta sesión (no existía aunque el README lo mencionaba).
- `npx supabase init` hecho: `supabase/config.toml` (project_id `NuevoInventario`, PostgreSQL 17, API en 54321, BD en 54322).
- `npx supabase start` funciona; la migración `base_seguridad` se aplica en PostgreSQL 17. Studio en http://127.0.0.1:54323.
- `.env.local` creado con la URL y la anon key locales (ignorado por Git).

## Riesgos pendientes

- Respuestas del contador: IVA incluido en precios, IVA de compras como costo, notas de venta agrupadas y formato de exportación.
- Confirmar que un sistema de uso propio no requiere el registro de proveedores (Res. NAC-DGERCGC26-00000027).
- Compatibilidad de la firma XAdES con Edge Functions (prototipo antes del MVP-2).
- Plan de Supabase para producción (el gratuito no tiene respaldos automáticos).
- La concurrencia (dos ventas de la última unidad a la vez) depende de `select … for update` en `existencias`; pgTAP corre en una sola sesión y no la prueba. Probarla con dos conexiones en la Fase 7, cuando exista `registrar_venta`.
- `existencias_cantidad_no_negativa` impide stock negativo; si el dueño activa `permitir_venta_sin_stock` (D-004), habrá que quitar esa restricción en una migración.
- La interfaz debe pedir columnas explícitas de `existencias`: `select *` falla por el permiso por columna (D-020).
- El paquete JS pesa más de 500 kB (supabase-js + zod + React). Dividirlo por pantallas cuando lleguen ventas y caja.
- Sin pruebas automáticas de componentes React (no hay jsdom ni Testing Library): las pantallas se probaron a mano en el navegador. Reevaluar en la Fase 8 (D-018).

## Próximas tareas

1. Fase 7: compras (`proveedores`, `compras`, `compra_detalles`, `registrar_compra` con IVA como costo según `iva_compras_es_costo`), usando `privado.registrar_movimiento`.
