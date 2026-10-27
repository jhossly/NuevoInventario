# Continuidad del proyecto

Resumen compacto para retomar el trabajo en una conversación nueva.
**Pégalo completo al inicio de la nueva conversación.** Actualízalo al cerrar cada sesión importante.

Última actualización: 2026-11-02 (Fase 11 cerrada: MVP-1 completo, probado en local y en CI)

---

## Producto

Sistema web (PWA) de inventario, compras, ventas, fiado y caja para **una bodega RIMPE Negocio Popular** en Ecuador. Uso propio, sin venta a terceros. Usuarios: el dueño (celular: compras, conteos, consultas) y quien factura (computadora: ventas, caja, reportes). Hoy el dueño factura en el portal gratuito del SRI y descuenta el stock a mano en Excel; el objetivo es eliminar ese doble trabajo.

## Alcance aprobado

- **MVP-1:** catálogo con presentaciones (caja → unidad, kilo, libra), compras con o sin respaldo, inventario con libro inmutable, ventas de mostrador, anulaciones y devoluciones, fiado con límite, caja con apertura y cierre, reportes (margen, stock valorizado, kardex, acumulado frente al límite RIMPE), exportación para el contador e importación de XML autorizados del SRI.
- **MVP-2:** facturación electrónica integrada (generar, firmar con el .p12 del dueño, enviar y autorizar).
- **Fuera:** multiempresa comercial, suscripciones, lotes y vencimientos, FIFO, modo sin conexión, app nativa.

## Decisiones clave

Ver `docs/DECISIONES.md` (D-001 a D-043). Las esenciales: costo promedio ponderado, bloqueo de ventas sin stock, reglas en funciones SQL, libro de movimientos inmutable, cuatro barreras de seguridad y el Vendedor sin ver costos.

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
| 7. Compras | **Cerrada**: base de datos e interfaz probadas en local y en GitHub Actions |
| 8. Ventas | **Cerrada**: base de datos e interfaz probadas en local y en GitHub Actions (con concurrencia) |
| 9. Caja y fiado | **Cerrada**: base de datos e interfaz probadas en local y en GitHub Actions (con concurrencia) |
| 10. Reportes y exportación | **Cerrada**: base de datos e interfaz probadas en local y en GitHub Actions |
| 11. Importar XML del SRI | **Cerrada**: probada en local y en GitHub Actions. **MVP-1 completo** |
| 12. Contador y puesta en producción | Siguiente |

## Migraciones

| Archivo | Contenido |
| --- | --- |
| `20261027000000_base_seguridad.sql` | Esquema `privado`, `empresas`, `perfiles`, `membresias`, `auditoria`, `mi_empresa()`, `mi_rol()`, `privado.ok()`/`privado.error()`, trigger de solo inserción, permisos y RLS, función `mi_contexto()` |
| `20261028000000_catalogo_inventario.sql` | `categorias`, `productos`, `presentaciones`, `movimientos_inventario` (inmutable, con `secuencia`), `existencias` (costos ocultos por columna, D-020), `conteos`, `conteo_detalles` (congelados al confirmar). Motor `privado.registrar_movimiento` (promedio ponderado, bloqueo de fila, `STOCK_INSUFICIENTE`). `privado.fallar()` (errores de negocio con SQLSTATE `NG001`) y `privado.ve_costos()`. Expuestas: `guardar_categoria`, `eliminar_categoria`, `guardar_producto`, `guardar_presentacion`, `ajustar_inventario`, `inventario_valorizado`, `guardar_conteo`, `confirmar_conteo` |
| `20261029000000_compras.sql` | `proveedores`, `compras` (solo pasa de CONFIRMADA a ANULADA), `compra_detalles` (inmutables). Tipo de movimiento `ANULACION_COMPRA`; `registrar_movimiento` recibe la fecha del documento. `privado.calcular_lineas_compra` (única fuente del cálculo), `privado.normalizar_documento`. Expuestas: `guardar_proveedor`, `calcular_compra` (vista previa), `registrar_compra`, `anular_compra` |
| `20261030000000_ventas.sql` | `clientes`, `ventas` (solo admite pedir anulación o pasar a ANULADA), `venta_detalles`, `venta_pagos`, `devoluciones`, `devolucion_detalles` (inmutables). `empresas.monto_max_consumidor_final` (50) y `monto_max_sin_comprobante` (0). `privado.calcular_lineas_venta` (única fuente del cálculo, IVA incluido o no), `privado.explicar_error_venta`. Expuestas: `guardar_cliente`, `calcular_venta`, `registrar_venta`, `solicitar_anulacion_venta`, `anular_venta`, `registrar_devolucion`, `costos_venta`. Un reintento simultáneo con la misma clave devuelve la venta ya creada |
| `20261031000000_caja_fiado.sql` | `cajas` (una abierta por empresa; solo se cierra una vez y se explica una vez; esperado y diferencia ocultos al Vendedor), `caja_movimientos`, `fiado_movimientos` (inmutables), `ventas.caja_id`, `devoluciones.caja_id`. `privado.caja_abierta` (bloqueo compartido), `privado.efectivo_caja`, `privado.saldo_fiado`. Expuestas: `abrir_caja`, `movimiento_caja`, `cerrar_caja`, `resumen_caja`, `explicar_diferencia_caja`, `registrar_abono`, `ajustar_fiado`, `cuentas_fiado`. Nuevas versiones de `registrar_venta` (FIADO, caja para efectivo), `anular_venta` y `registrar_devolucion` (egreso automático o ajuste de fiado) |
| `20261101000000_reportes.sql` | `empresas.limite_ingresos_rimpe` (20000). `privado.error_periodo`, `privado.lineas_netas` (ventas confirmadas − devoluciones, por línea). Expuestas, solo Dueño: `reporte_ventas`, `reporte_margen`, `acumulado_rimpe`, `exportacion_contador` |
| `20261102000000_comprobantes_sri.sql` | `comprobantes` (XML guardado; solo se vincula una vez; se descarta si no tiene venta), `comprobante_lineas` (solo cambia el producto asociado, antes del vínculo), `codigos_sri` (memoria código → presentación). Lectores `privado.xml_texto`, `xml_interno` (CDATA o escapado), `xml_numero`, `digito_clave_acceso` (módulo 11). Expuestas, solo Dueño: `importar_comprobante`, `asociar_linea_comprobante`, `candidatos_comprobante`, `vincular_comprobante`, `crear_venta_de_comprobante`, `descartar_comprobante` |

Interfaz (Fase 11): «Facturas del SRI» (desde Ventas, solo Dueño): subir varios XML, ver el resultado de cada archivo, por cada factura pendiente asociar líneas a productos, vincular a la venta candidata («Es esta venta») o «No la registré: crear la venta», o descartar.

Interfaz (Fase 10): pantalla Reportes (solo Dueño): período (hoy, este mes, mes anterior o rango), ventas netas con IVA, costo, utilidad y margen, cobrado por medio de pago, margen por producto con «Margen (sobre venta)» y «Recargo (sobre costo)», avance hacia el límite RIMPE por mes, y descarga de CSV (ventas, compras, devoluciones, resumen de IVA, inventario valorizado) con `src/shared/csv.ts`.

Interfaz (Fase 9): pantallas Caja (abrir con fondo, ingresos y egresos, cierre a ciegas, historial con diferencia y explicación para el Dueño) y Fiado (por cobrar, cuenta del cliente, abonos, ajustes del Dueño); en «Vender», medio Fiado con saldo disponible y aviso de caja cerrada; en devoluciones, reintegro en efectivo o a la cuenta. Menú desplazable en el celular.

Interfaz (Fase 8): inicio en «Vender» (punto de venta: buscar con 2 letras o escanear y Enter, +/−, kilos, descuento, comprobante, cliente con alta rápida, medio de pago, vuelto, «Cobrar» con candado contra doble toque `useUnSoloEnvio`); ventas (el Vendedor ve las suyas), detalle con costos y utilidad para el Dueño, anular, devolver, pedir anulación; clientes. Menú para ambos roles: Vender, Ventas, Productos (+ Compras para el Dueño).

Interfaz (Fase 7): menú Productos / Compras para el Dueño; lista de compras, nueva compra (con o sin respaldo, alta rápida de proveedor, líneas por presentación con costo sin IVA y descuento, vista previa calculada por la base, clave de idempotencia por compra), detalle con anulación, proveedores.

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
| 2026-10-29 | Windows 11 del usuario: Supabase local | `003_compras` (46: Fase 3 y HU-01, descuento antes del IVA, IVA como costo o no, libra → kg, respaldo, documento repetido y normalizado, idempotencia, fecha futura, todo o nada, anulación al promedio y su límite, inmutabilidad, permisos) | **132/132 pasan** (24 + 62 + 46). Mutación: IVA sin restar el descuento y compra anulada que vuelve a confirmarse → fallan C3 e I4 |
| 2026-10-29 | GitHub Actions, run 40553769987, commit `3aa9844` | Trabajos «Tipos, Vitest y build» y «Migraciones y pgTAP» con la migración de compras | **Pasan los dos** |
| 2026-10-29 | Navegador integrado, celular, datos del seed | Dueño: compra de 2 cajas de aceite con factura `1-1-456` (vista previa $55,20 + $8,28 = $63,48; 24 u a $2,645; stock 34 a $2,455294), anulación con motivo, lista con «anulada». Vendedor: Compras bloqueado y sin menú | **Todo funciona**; las llamadas de la app responden 200 |
| 2026-10-30 | Windows 11 del usuario: Supabase local | `004_ventas` (63: Fase 3 y HU-02/HU-03, descuento, precios sin IVA, stock, idempotencia, pagos, comprobante, Vendedor, devoluciones que cuadran, anulación, inmutabilidad, aislamiento) | **195/195 pasan**. Mutación: sin tope de descuento → falla C5; última devolución proporcional → falla D15 |
| 2026-10-30 | Windows 11 del usuario: `npm run db:test:concurrencia` (dos conexiones) | 1) última unidad vendida a la vez; 2) dos «Cobrar» simultáneos con la misma clave | **2/2 pasan**. Sin bloqueo de fila ni insert previo, la 1 falla (DATOS_INVALIDOS en vez de STOCK_INSUFICIENTE) |
| 2026-10-30 | GitHub Actions, run 40577693759, commit `ba6ea62` | «Tipos, Vitest y build» y «Migraciones y pgTAP» + `venta_ultima_unidad.sh` (dos conexiones) | **Pasan todos los pasos**, también la concurrencia |
| 2026-10-31 | Windows 11 del usuario: Supabase local | `005_caja_fiado` (50: HU-04, cierre a ciegas, límite del Vendedor, abonos, ajustes, anulación y devolución con caja y fiado, inmutabilidad, aislamiento) y `004_ventas` ajustado a la caja | **245/245 pasan**. Mutación: esperado sin abonos y Vendedor sin límite → fallan 10/50 |
| 2026-10-31 | `npm run db:test:concurrencia` | Nuevo caso 3: dos ventas al fiado a la vez que juntas pasan el límite | **3/3 pasan**. Sin bloquear al cliente, el caso 3 falla (las dos pasan y la deuda queda en $6,90 sobre $5) |
| 2026-11-01 | Windows 11 del usuario: Supabase local | `006_reportes` (26: margen del aceite de la Fase 3 18,16 % / 22,18 % y de la galleta de la HU-05 24 % / 31,58 %, anuladas fuera, devoluciones restadas, por medio de pago, período inválido, RIMPE configurable, exportación con base 0 % / gravada / IVA, permisos y aislamiento) | **271/271 pasan**. Mutación: contar anuladas y no restar devoluciones → fallan 6 |
| 2026-11-01 | Vitest | `csv.test.ts` (BOM, `;`, coma decimal, comillas, fórmulas neutralizadas, rangos de mes con febrero bisiesto) | **49/49 pasan** |
| 2026-11-02 | Windows 11 del usuario: Supabase local | `007_comprobantes_sri` (39: sobre con CDATA y factura sola, repetida, otro RUC, ambiente de pruebas, dígito verificador, no autorizada, DOCTYPE, no XML, centavo de IVA, asociación y memoria, crear venta con montos/stock/cliente/pagos, vincular D-012 sin duplicar, descartar, inmutabilidad, permisos) | **310/310 pasan**. Mutación: sin dígito verificador y vincular sin fecha/total → fallan I7 y V6 |
| 2026-11-02 | Supabase local, transacción revertida, con 2 XML reales del dueño (no se guardan en el repositorio) | Factura emitida 001-100-000001529 (firmada, sin sobre de autorización, 17 líneas, IVA 0 %) y factura de un proveedor (con sobre y CDATA) | **Emitida: se importa, no se duplica y crea la venta** ($48,60, 17 líneas, 51 u, efectivo, sin caja, 17 códigos recordados). **Proveedor: rechazada por otro RUC**, como corresponde |
| 2026-11-02 | GitHub Actions, run 40587540252, commit `cab2dff` | «Tipos, Vitest y build» y «Migraciones y pgTAP» + concurrencia | **Pasan todos los pasos** |
| 2026-11-02 | Navegador, 1200 px, 2 XML generados para la bodega del seed | Subir 2 archivos; aceite asociado por código de barras y vinculado a la venta a mano; arroz con código desconocido asociado a mano y venta creada. Base: aceite 9 (sin doble descuento), arroz 43,359, código recordado | **Todo funciona** |
| 2026-11-01 | GitHub Actions, run 40584727008, commit `bab975e` | «Tipos, Vitest y build» y «Migraciones y pgTAP» + concurrencia | **Pasan todos los pasos** |
| 2026-11-01 | Navegador, 1200 px, ventas de ejemplo | Reportes del mes: ventas netas $24,17, IVA $1,68, utilidad $6,92 (28,6 %), margen por producto, RIMPE $24,17 de $20.000; los 4 CSV generados con contenido correcto | **Todo funciona** |
| 2026-10-31 | GitHub Actions, run 40581294249, commit `26102a0` | «Tipos, Vitest y build» y «Migraciones y pgTAP» + concurrencia (3 casos) | **Pasan todos los pasos** |
| 2026-10-31 | Navegador, 1200 px y celular | Vendedor: «Cobrar» bloqueado sin caja, abrir con $20, venta en efectivo, venta al fiado a Doña Rosa (disponible $15 → $8,10), abono de $5, cierre a ciegas contando $28. Dueño: esperado $28,45, falta $0,45, explicación guardada | **Todo funciona**; la única llamada con error es el cierre de una sesión anterior al reset de la base |
| 2026-10-30 | Navegador, 1200 px, datos del seed | Vendedor: buscar + Enter, escanear código, queso 1,25 kg, total $13,45, descuento rechazado (tope 0 %), vuelto $6,55, doble clic en «Cobrar» → una venta, pedir anulación. Dueño: costo y utilidad, anular, vender 3 Colas escaneando y devolver 1 | **Todo funciona**. Se encontró y corrigió: el doble clic mostraba «El registro ya existe» (la venta sí era una sola) |
| 2026-10-28 | Windows 11 del usuario: API local real | Inicio de sesión de `dueno@bodega.test`, RPC `inventario_valorizado`, lectura directa de `existencias.valor_total` | Sesión ok; RPC devuelve valores como texto; lectura directa rechazada con `42501` |

Aviso de `npm install`: el script `postinstall` de esbuild 0.21.5 no se ejecutó (allowScripts de npm 11). No afectó a vite ni vitest.

## Errores conocidos

Ninguno abierto. Resueltos:

- Doble toque en «Cobrar»: la segunda llamada simultánea con la misma clave chocaba con la unicidad y la pantalla mostraba «El registro ya existe» (la base guardaba una sola venta). Corregido en la base (devuelve la venta existente) y en la interfaz (`useUnSoloEnvio`). `registrar_compra` y `ajustar_inventario` aún responden DUPLICADO en esa carrera; la interfaz ya la evita (ver Riesgos).

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

- **Hallazgos con XML reales (2026-11-02), a decidir con el dueño y el contador:**
  - **IVA de las ventas.** La factura real del dueño cobra IVA 0 % en todo (incluida la Coca-Cola), como corresponde a RIMPE Negocio Popular, pero el catálogo tiene productos con 15 %. Si el negocio no cobra IVA en sus ventas, hace falta una configuración de la empresa para vender siempre con 0 % (las compras sí traen IVA). **Confirmar con el contador antes de usar el sistema.**
  - **Recargas telefónicas.** La factura incluye «RECARGA CLARO GIGAS»: es un servicio, no algo con stock. Hoy todo producto controla stock y la venta se bloquearía. Hace falta un tipo de producto sin control de stock (servicio).
  - **Códigos internos.** El portal del SRI usa códigos propios del dueño (0065, REC128…), no códigos de barras: la primera vez hay que asociar cada línea a mano (17 en esta factura); después se recuerdan. Conviene una forma más rápida de asociar (o crear el producto desde la línea).
  - La factura emitida llega **firmada pero sin el sobre de autorización**; se acepta (el importador lee ambos formatos).
  - Si más adelante se importan facturas de **proveedores como compras**: traen ICE (código 3) e IRBPNR por botellas (código 5) que suman al total, el código de barras viene en `codigoAuxiliar` y hay líneas de bonificación a precio 0.
- Una venta con factura que se anula en el sistema no anula la factura en el SRI: eso se hace en el portal (hasta el día 7 del mes siguiente).
- Respuestas del contador: IVA incluido en precios, IVA de compras como costo, notas de venta agrupadas y formato de exportación.
- Confirmar que un sistema de uso propio no requiere el registro de proveedores (Res. NAC-DGERCGC26-00000027).
- Compatibilidad de la firma XAdES con Edge Functions (prototipo antes del MVP-2).
- Plan de Supabase para producción (el gratuito no tiene respaldos automáticos).
- La concurrencia (dos ventas de la última unidad a la vez) depende de `select … for update` en `existencias`; pgTAP corre en una sola sesión y no la prueba. Probarla con dos conexiones en la Fase 7, cuando exista `registrar_venta`.
- `existencias_cantidad_no_negativa` impide stock negativo; si el dueño activa `permitir_venta_sin_stock` (D-004), habrá que quitar esa restricción en una migración.
- La interfaz debe pedir columnas explícitas de `existencias`: `select *` falla por el permiso por columna (D-020).
- El paquete JS pesa más de 500 kB (supabase-js + zod + React). Dividirlo por pantallas cuando lleguen ventas y caja.
- `registrar_compra` y `ajustar_inventario` responden DUPLICADO (no la operación existente) si dos pedidos con la misma clave llegan exactamente a la vez; los datos quedan bien. Igualar a ventas en una migración futura.
- Ir a «Caja» desde «Vender» para abrirla vacía el carrito en curso (la pantalla se desmonta). Mejorar si molesta en el uso real.
- La utilidad de una venta en su detalle no descuenta las devoluciones; los reportes (Fase 10) deben usar ventas − devoluciones.
- Docker Desktop puede apagarse al suspender la PC: si `supabase` dice que no encuentra el motor, abrir Docker Desktop y esperar.
- Sin pruebas automáticas de componentes React (no hay jsdom ni Testing Library): las pantallas se probaron a mano en el navegador. Reevaluar en la Fase 8 (D-018).

## Próximas tareas

1. Decidir con el dueño y el contador los hallazgos de los XML reales (ver Riesgos): IVA 0 % en ventas, productos sin stock (recargas), asociación rápida de códigos.
2. Llevar las preguntas pendientes al contador (ver Riesgos) y ajustar la configuración: precios con IVA, IVA de compras como costo, montos del comprobante, límite RIMPE y formato de la exportación.
3. Puesta en producción: proyecto Supabase con respaldos, despliegue de la interfaz, alta del dueño y del vendedor reales.
