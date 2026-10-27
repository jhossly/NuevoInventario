# Continuidad del proyecto

Resumen compacto para retomar el trabajo en una conversación nueva.
**Pégalo completo al inicio de la nueva conversación.** Actualízalo al cerrar cada sesión importante.

Última actualización: 2026-10-27 (Fase 5 cerrada: verificada en Windows y en CI)

---

## Producto

Sistema web (PWA) de inventario, compras, ventas, fiado y caja para **una bodega RIMPE Negocio Popular** en Ecuador. Uso propio, sin venta a terceros. Usuarios: el dueño (celular: compras, conteos, consultas) y quien factura (computadora: ventas, caja, reportes). Hoy el dueño factura en el portal gratuito del SRI y descuenta el stock a mano en Excel; el objetivo es eliminar ese doble trabajo.

## Alcance aprobado

- **MVP-1:** catálogo con presentaciones (caja → unidad, kilo, libra), compras con o sin respaldo, inventario con libro inmutable, ventas de mostrador, anulaciones y devoluciones, fiado con límite, caja con apertura y cierre, reportes (margen, stock valorizado, kardex, acumulado frente al límite RIMPE), exportación para el contador e importación de XML autorizados del SRI.
- **MVP-2:** facturación electrónica integrada (generar, firmar con el .p12 del dueño, enviar y autorizar).
- **Fuera:** multiempresa comercial, suscripciones, lotes y vencimientos, FIFO, modo sin conexión, app nativa.

## Decisiones clave

Ver `docs/DECISIONES.md` (D-001 a D-019). Las esenciales: costo promedio ponderado, bloqueo de ventas sin stock, reglas en funciones SQL, libro de movimientos inmutable, cuatro barreras de seguridad y el Vendedor sin ver costos.

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
| 6. Productos e inventario | Siguiente |

## Migraciones

| Archivo | Contenido |
| --- | --- |
| `20261027000000_base_seguridad.sql` | Esquema `privado`, `empresas`, `perfiles`, `membresias`, `auditoria`, `mi_empresa()`, `mi_rol()`, `privado.ok()`/`privado.error()`, trigger de solo inserción, permisos y RLS, función `mi_contexto()` |

## Pruebas ejecutadas y resultados reales

| Fecha | Dónde | Qué | Resultado |
| --- | --- | --- | --- |
| 2026-10-27 | Espacio de trabajo de Claude: PostgreSQL 16.15 + pgTAP 1.3.5 con una imitación mínima de Supabase (roles anon/authenticated, `auth.uid()`) | `001_seguridad_base.test.sql` | **24/24 pasan**. Prueba de mutación: con RLS desactivado, un permiso de escritura y una vista sin `security_invoker`, fallan 6/24 como se espera |
| 2026-10-27 | Espacio de trabajo de Claude: Node 22 con un sustituto mínimo de vitest | `formato.test.ts`, `respuesta.test.ts` | **12/12 pasan** |
| 2026-10-27 | Windows 11 del usuario: Node 24.22.0, npm 11.19.1 | `npm install` (184 paquetes), `npm run typecheck`, `npm run build` (vite 5.4.21, JS 463 kB / 128 kB gzip) | **Pasan** |
| 2026-10-27 | Windows 11 del usuario: vitest 2.1.9 real | `formato.test.ts`, `respuesta.test.ts`, `env.test.ts` (nuevo, cubre `leerEnv`) | **17/17 pasan** |
| 2026-10-27 | Windows 11 del usuario: Supabase local real (CLI 2.122.0, imagen postgres 17.11.0.006, pg_prove 3.36) | `npm run db:test` → `001_seguridad_base.test.sql` | **24/24 pasan** |
| 2026-10-27 | GitHub Actions, run 40543041246, commit `0a00ce6` | Trabajos «Tipos, Vitest y build» y «Migraciones y pgTAP» (`.github/workflows/pruebas.yml`) | **Pasan los dos** |

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

## Próximas tareas

1. Fase 6: migración de catálogo e inventario (`categorias`, `productos`, `presentaciones`, `movimientos_inventario`, `existencias`, conteos), funciones `ajustar_inventario` y `registrar_conteo`, pruebas del kardex del aceite (Fase 3) y datos de prueba (`seed.sql`).
