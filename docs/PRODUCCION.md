# Puesta en producción

Pasos para usar el sistema de verdad: la base en Supabase (en internet), la página publicada en Vercel y la bodega real con sus usuarios. Se hace una sola vez. Calcula unas 2 horas.

Las cuentas son tuyas: créalas tú con tu correo. Nunca compartas por chat la contraseña de la base ni la clave `service_role`.

---

## Antes de empezar

- [ ] Hablar con el contador (ver «Riesgos» en `CONTINUIDAD.md`): desde qué fecha rige el IVA 0 %, si los precios incluyen IVA, si el IVA de compras va como costo, el formato de la exportación y el límite RIMPE.
- [ ] Tener a mano: RUC (13 dígitos), razón social, nombre comercial, correo del dueño y de quien vende.
- [ ] En esta computadora: `git pull` para tener la última versión del repositorio.

---

## 1. Crear el proyecto en Supabase

1. Entra a https://supabase.com y crea una cuenta (puedes usar «Continue with GitHub»).
2. **New project**:
   - **Name:** `bodega` (o el que quieras).
   - **Database password:** pulsa «Generate a password» y **guárdala en un lugar seguro** (un gestor de contraseñas o papel guardado). La necesitas en el paso 2.
   - **Region:** `East US (North Virginia)` (la más cercana con buena conexión desde Ecuador; `South America (São Paulo)` también sirve).
   - **Plan:** el gratuito sirve para empezar, pero **no hace respaldos automáticos** y pausa el proyecto si no se usa en 7 días. Para datos reales conviene **Pro** (unos $25 al mes). Ver «Respaldos» al final.
3. Espera a que termine de crearse (1–2 minutos).
4. Anota dos datos de **Project Settings → API** (o «Data API»):
   - **Project URL** (algo como `https://abcdefgh.supabase.co`).
   - **anon public key** (una clave larga que empieza con `eyJ…` o `sb_publishable_…`). Esta sí puede ir en la página.
   - La **service_role key** NO se usa en ningún paso: no la copies a ningún lado.
5. Anota el **Reference ID** del proyecto (Project Settings → General), son unas 20 letras.

## 2. Subir las tablas y reglas (migraciones)

En la terminal, dentro de la carpeta del proyecto:

```bash
npx supabase login
```

Se abre el navegador para autorizar. Luego:

```bash
npx supabase link --project-ref TU_REFERENCE_ID
```

Pide la **Database password** del paso 1. Luego:

```bash
npx supabase db push
```

Muestra la lista de migraciones (`20261027000000_base_seguridad.sql` … `20261104000000_productos_sin_stock.sql`) y pregunta si las aplica: responde `Y`. **No** sube los datos de prueba (`seed.sql`): la base queda vacía.

## 3. Cerrar el registro de usuarios

En Supabase: **Authentication → Sign In / Providers** (o «Providers → Email»):

- Desactiva **«Allow new users to sign up»**. Así nadie de afuera puede crearse una cuenta; los usuarios los creas tú (paso 4).
- Deja activo el ingreso con **Email**.

Aunque alguien lograra crearse una cuenta, no vería nada (no pertenece a ninguna bodega), pero es mejor cerrarlo.

## 4. Crear los usuarios

**Authentication → Users → Add user → Create new user**, una vez por persona:

- **Email:** el correo de la persona.
- **Password:** una contraseña de al menos 8 caracteres. Dísela a la persona en persona.
- Marca **«Auto Confirm User»**.

Crea el del dueño y el de quien vende (si todavía no hay vendedor, solo el del dueño).

## 5. Dar de alta la bodega

1. Abre `supabase/produccion/alta_bodega.sql` en el editor y copia todo su contenido.
2. En Supabase: **SQL Editor → New query**, pega el contenido.
3. Cambia **solo** los valores entre comillas de la sección «Datos de la bodega»: RUC, razón social, nombre comercial, correos y nombres. Si aún no hay vendedor, deja `v_correo_vendedor` como `''`.
4. Pulsa **Run**. Debe decir «Listo: bodega …» y mostrar una tabla con los correos y su rol (`DUENO`, `VENDEDOR`).

Si dice un error («No existe el usuario…», «El RUC debe tener 13 dígitos»…), corrige y vuelve a ejecutar: mientras haya error no se guarda nada. Se ejecuta una sola vez; una segunda vez avisa «Ya hay una bodega registrada».

## 6. Publicar la página en Vercel

1. Entra a https://vercel.com y crea una cuenta con **GitHub**.
2. **Add New → Project → Import** el repositorio `jhossly/NuevoInventario`.
3. Vercel reconoce **Vite**. Revisa:
   - **Build Command:** `npm run build`
   - **Output Directory:** `dist`
4. En **Environment Variables** agrega las dos del paso 1:
   - `VITE_SUPABASE_URL` = la Project URL
   - `VITE_SUPABASE_ANON_KEY` = la anon public key
5. **Deploy**. Al terminar te da una dirección como `https://nuevo-inventario.vercel.app`.
6. Cada `git push` a `main` vuelve a publicar la página sola.

La app usa rutas con `#` (`/#/productos`), así que no hace falta configurar nada más en Vercel.

## 7. Comprobar

Desde la computadora y desde el celular, abre la dirección de Vercel:

- [ ] El dueño entra con su correo y contraseña y ve el nombre de la bodega arriba, sin productos.
- [ ] Crea un producto de prueba, le carga stock con una apertura, lo vende y lo ve en Ventas y Reportes. Después **anula esa venta** para que no cuente.
- [ ] Quien vende entra con su usuario y **no** ve Compras, Reportes ni costos.
- [ ] En el celular: menú del navegador → **«Agregar a pantalla de inicio»** para abrirla como una app.

## 8. Cargar los datos reales

1. **IVA de ventas:** Reportes → «IVA de ventas» → la fecha y el modo que confirmó el contador.
2. **Catálogo:**
   - Rápido: Ventas → «Facturas SRI» → sube tus XML de facturas emitidas y usa **«Crear producto»** en cada línea sin producto.
   - A mano: Productos → «Nuevo» para lo que no aparece en facturas. Marca «Controla stock» solo en lo que se cuenta; desmárcalo en recargas y servicios.
3. **Stock inicial:** en cada producto, «Ajustar stock» → **Apertura** con la cantidad y lo que costó cada unidad. Mejor un día de poco movimiento, contando de verdad.
4. **Clientes con fiado:** Ventas → Clientes, con su límite. Si ya deben, regístralo como ajuste en Fiado.
5. **Caja:** cada día, abrir con el fondo y cerrar contando.

**Durante 1 o 2 semanas usa el sistema junto con tu Excel** y compara el stock y las ventas. Cuando cuadren, deja el Excel.

---

## Respaldos

- **Plan Pro:** Supabase guarda un respaldo diario (7 días). Recomendado.
- **Plan gratuito:** haz un respaldo manual al menos cada semana:

  ```bash
  npx supabase db dump --linked --data-only -f respaldos/respaldo-AAAA-MM-DD.sql
  ```

  La carpeta `respaldos/` está en `.gitignore`: Git no la sube. Copia el archivo también fuera de la computadora (Google Drive, USB). **Nunca lo subas a GitHub**: tiene tus ventas y clientes.

## Si algo pasa

- **Olvidaron una contraseña:** Authentication → Users → el usuario → cambiarle la contraseña.
- **Alguien deja de trabajar:** en la base, su membresía se desactiva (pídelo en una sesión de trabajo); sus ventas quedan registradas con su nombre.
- **Cambios futuros del sistema:** después de cada cambio con migración nueva, `npx supabase db push` (sube solo lo nuevo) y `git push` (Vercel publica la página).
