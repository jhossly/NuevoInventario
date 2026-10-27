# Registro de decisiones

Cada decisión tiene un número fijo. Si una decisión cambia, no se borra:
se marca como **Reemplazada por D-XXX** y se agrega la nueva.

| # | Fecha | Decisión | Motivo | Estado |
| --- | --- | --- | --- | --- |
| D-001 | 2026-10-25 | Sistema de uso propio para una sola bodega RIMPE Negocio Popular; sin SaaS ni suscripciones | Respuesta del dueño del proyecto | Vigente |
| D-002 | 2026-10-26 | MVP-1: inventario, compras, ventas, fiado, caja, reportes e importación de XML del SRI. MVP-2: facturación integrada con la firma .p12 | Valor rápido sin esperar certificación del SRI | Vigente |
| D-003 | 2026-10-26 | Costo promedio ponderado | Simple y suficiente para una bodega | Vigente (confirmar con contador) |
| D-004 | 2026-10-26 | Ventas sin stock bloqueadas por defecto (configurable) | Inventario confiable desde el inicio | Vigente |
| D-005 | 2026-10-26 | Toda venta lleva el comprobante que exige la norma; el origen de la compra no decide si una venta se factura | La obligación nace de la venta | Vigente |
| D-006 | 2026-10-26 | Monolito modular: React + Vite + TypeScript (PWA) sobre Supabase | Un desarrollador, un negocio | Vigente |
| D-007 | 2026-10-26 | Reglas de negocio en funciones SQL transaccionales; Edge Functions solo para XML y firma | Atomicidad y una sola fuente de reglas | Vigente |
| D-008 | 2026-10-26 | Libro de movimientos de inventario inmutable + tabla `existencias` derivada | Trazabilidad de cada cambio de stock | Vigente |
| D-009 | 2026-10-26 | `empresa_id` en todas las tablas de negocio, sin administración multiempresa | Barato ahora, caro después | Vigente |
| D-010 | 2026-10-26 | Precisión: cantidades `numeric(14,3)`, costos `numeric(16,6)`, dinero `numeric(12,2)` | Gramos y promedios sin pérdida | Vigente |
| D-011 | 2026-10-26 | Redondeo solo en funciones SQL (mitad hacia arriba); la interfaz solo formatea | Una sola fuente de verdad | Vigente |
| D-012 | 2026-10-26 | Venta con factura se registra al instante; el XML importado se vincula a ella (mismo día y total ±$0,01, confirmado por el dueño) | Descontar al instante sin duplicar | Vigente |
| D-013 | 2026-10-27 | Cuatro barreras: autenticación, permisos SQL, RLS y funciones `security definer` con `search_path` vacío | Ninguna barrera única basta | Vigente |
| D-014 | 2026-10-27 | Vistas siempre con `security_invoker = true` | Una vista definer se salta RLS | Vigente |
| D-015 | 2026-10-27 | Vendedor no ve costos por defecto (`empresas.vendedor_ve_costos`) | Protege el margen del negocio | Vigente |
| D-016 | 2026-10-27 | Firma .p12 cifrada en Storage + clave en secretos + contraseña en Vault (opción A) | Tres piezas separadas | Vigente; prototipo antes del MVP-2 |
| D-017 | 2026-10-27 | Sin registro público: el dueño invita usuarios | Nadie ajeno crea cuenta | Vigente |
| D-018 | 2026-10-27 | Sin ESLint por ahora; TypeScript estricto + pruebas | Menos dependencias al inicio; se reevalúa en la Fase 8 | Vigente |
| D-019 | 2026-10-27 | Valores `numeric` llegan a la interfaz como texto | `number` de JavaScript pierde precisión | Vigente |
| D-020 | 2026-10-28 | Costos de `existencias` ocultos por permiso de columna; el valor se lee con `inventario_valorizado()` y el kardex con RLS según `ve_costos()`. Reemplaza la "vista separada solo para Dueño" de la Fase 4 | Dueño y Vendedor usan el mismo rol de base: una vista `security_invoker` (D-014) no puede separarlos | Vigente |
| D-021 | 2026-10-28 | Ajustes con signo (APERTURA > 0 con costo y solo sin movimientos previos; AJUSTE ≠ 0 y MERMA < 0, ambos con motivo). La clave de idempotencia de los ajustes vive en `movimientos_inventario` | Trazabilidad; los ajustes no tienen documento propio | Vigente |
| D-022 | 2026-10-28 | Conteo en dos pasos: `guardar_conteo` (borrador editable) y `confirmar_conteo` (recalcula el stock del sistema al confirmar, todo o nada, y congela el conteo) | El dueño cuenta con calma; el stock puede moverse mientras tanto | Vigente |
| D-023 | 2026-10-29 | Anular una compra saca sus unidades al costo promedio vigente (movimiento ANULACION_COMPRA); si ya se vendió parte, no se anula y se corrige con un ajuste | Mismo motor para toda salida; el valor del inventario nunca queda negativo | Vigente (confirmar con contador) |
| D-024 | 2026-10-29 | Los cálculos de una compra viven solo en `privado.calcular_lineas_compra`; la vista previa de la interfaz usa `calcular_compra`, que no guarda | D-011 sin duplicar redondeos en TypeScript | Vigente |
| D-025 | 2026-10-29 | Compra en un solo paso (se registra ya confirmada, sin borrador); el número de documento del SRI se normaliza (`1-1-123` → `001-001-000000123`) y no se repite por proveedor salvo que la anterior esté anulada | El dueño registra la factura que tiene en la mano; evita duplicados por formato | Vigente |

## Dependencias y por qué

| Paquete | Para qué |
| --- | --- |
| react, react-dom | Interfaz |
| @supabase/supabase-js | Autenticación y llamadas a la base |
| @tanstack/react-query | Caché, estados de carga y reintentos de lecturas |
| zod | Validación de entradas y de configuración |
| vite, @vitejs/plugin-react | Servidor de desarrollo y compilación |
| typescript | Tipos estáticos |
| vitest | Pruebas de TypeScript |
| tailwindcss, postcss, autoprefixer | Estilos adaptables |
| supabase (CLI) | Base local, migraciones y pruebas pgTAP |
