# Bodega — inventario, ventas y caja

Sistema web (PWA) para una bodega RIMPE Negocio Popular en Ecuador.
Uso propio de un solo negocio. Estado: **Fase 5 — entorno de desarrollo**.

## Requisitos en tu computadora (Windows)

| Herramienta | Para qué | Comprobar |
| --- | --- | --- |
| Git | Control de versiones | `git --version` |
| Node.js 20 o superior | Interfaz y herramientas | `node -v` |
| Docker Desktop (encendido) | Supabase local | `docker info` |
| Cuenta de GitHub | Repositorio y pruebas automáticas | — |

## Primera vez

Abre una terminal (PowerShell) en esta carpeta y ejecuta en orden:

```powershell
# 1. Repositorio Git
git init -b main

# 2. Dependencias (crea package-lock.json)
npm install

# 3. Configuración de Supabase local (crea supabase/config.toml).
#    Si pregunta por configuraciones de VS Code / Deno, responde N.
npx supabase init

# 4. Levantar Supabase local (la primera vez descarga imágenes; tarda)
npx supabase start

# 5. Variables de entorno: copia el ejemplo y pega "API URL" y "anon key"
#    que mostró el paso 4
copy .env.example .env.local

# 6. Pruebas
npm run db:test      # seguridad de la base (pgTAP)
npm test             # reglas en TypeScript (Vitest)
npm run typecheck    # tipos

# 7. Abrir la app en http://localhost:5173
npm run dev

# 8. Primer commit
git add .
git commit -m "Fase 5: entorno base, migración de seguridad y pruebas"
```

## Comandos frecuentes

| Comando | Qué hace |
| --- | --- |
| `npm run dev` | Abre la app en modo desarrollo |
| `npm test` | Pruebas de TypeScript |
| `npm run db:test` | Pruebas de seguridad y reglas en la base |
| `npm run db:reset` | Borra la base local y aplica todas las migraciones desde cero |
| `npm run db:nueva-migracion -- nombre` | Crea un archivo de migración vacío con fecha |
| `npx supabase stop` | Apaga Supabase local |

## Estructura

```
├── docs/
│   ├── DECISIONES.md      ← por qué se eligió cada cosa
│   └── CONTINUIDAD.md     ← resumen para retomar en otra sesión
├── src/
│   ├── lib/               ← cliente de Supabase y variables de entorno
│   ├── shared/            ← utilidades sin reglas de negocio (formato, respuestas)
│   └── modules/           ← un módulo por carpeta (llegan desde la Fase 6)
├── supabase/
│   ├── migrations/        ← cambios de base de datos, en orden y versionados
│   └── tests/database/    ← pruebas pgTAP
└── .github/workflows/     ← pruebas automáticas en GitHub
```

## Reglas del proyecto

1. Ninguna tabla se modifica a mano: todo cambio es una migración nueva.
2. Toda tabla nueva activa RLS en la misma migración.
3. Las escrituras de negocio pasan por funciones SQL; la interfaz no escribe en tablas.
4. Nada es "terminado" hasta que sus pruebas pasan.
5. Ningún secreto en el repositorio ni en variables `VITE_`.

El diseño completo está en los documentos de las Fases 1 a 4 (ver `docs/CONTINUIDAD.md`).
