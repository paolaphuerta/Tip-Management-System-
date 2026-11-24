# El Sauce · Propinas v3 — Instalación

Esta versión cambia cómo se guarda el reparto en curso. Lo instalamos en dos etapas:

1. **Prueba** en un proyecto de Supabase nuevo, con datos ficticios.
2. **Producción**, cuando la prueba salga bien.

Tu app actual sigue funcionando hasta el último paso.

## Qué archivos hay

| Archivo | Para qué |
|---|---|
| `index.html`, `styles.css`, `app.js`, carpeta `js/` | La aplicación. **Se suben todos juntos**, incluida la carpeta `js`. |
| `config.example.js` | Modelo para crear `config.js` con los datos de tu proyecto. |
| `supabase/01_schema_base.sql` | El esquema original. Solo para el proyecto de prueba (en producción ya existe). |
| `supabase/04_rediseno.sql` | Las tablas y funciones nuevas. Funciona aunque hayas corrido el 02 y el 03, o ninguno de los dos. |
| `supabase/05_activar_produccion.sql` | Cierra los caminos viejos. Se corre **al final**. |
| `tests/` | Pruebas automáticas. No se suben a Cloudflare. |

---

## Etapa 1 · Prueba (unos 20 minutos)

1. En supabase.com crea un proyecto nuevo, por ejemplo `el-sauce-pruebas`.
2. Ve a **SQL Editor**, pega todo `supabase/01_schema_base.sql` y pulsa **Run**.
3. En otra consulta nueva, pega todo `supabase/04_rediseno.sql` y pulsa **Run**. Debe terminar sin errores.
4. Ve a **Authentication › Sign In / Providers › Email** y comprueba que esté activado. Para probar más rápido puedes desactivar «Confirm email» solo en este proyecto.
5. Copia `config.example.js` como `config.js` y pon la **Project URL** y la **publishable key** del proyecto de prueba. Las encuentras en el botón **Connect** o en **Project Settings › API**.
   - La URL va sin `/rest/v1/`. Ejemplo: `https://abcd1234.supabase.co`.
   - Ojo: tu documento `Project_url.docx` guarda la URL con `/rest/v1/`; esa forma no sirve aquí.
6. En Cloudflare crea **otro** proyecto de sitio estático (por ejemplo `el-sauce-pruebas`) y sube la carpeta con `index.html`, `styles.css`, `app.js`, `config.js` y la carpeta `js/`.
7. En Supabase, ve a **Authentication › URL Configuration** y pon la dirección de ese sitio como **Site URL**. Así funcionan los correos de confirmación y de «Olvidé mi contraseña».
8. Prueba con dos cuentas (por ejemplo, tu computadora y tu celular):
   - [ ] Cuenta A: crear el espacio, ir a **Usuarios** y generar un código.
   - [ ] Cuenta B: crear su cuenta y unirse con el código.
   - [ ] Crear una plantilla y cargarla en **Reparto**.
   - [ ] A cambia el total mientras B cambia días u otra persona: los dos cambios se guardan.
   - [ ] Los dos cambian el mismo campo casi al mismo tiempo: a uno le aparece el aviso amarillo para elegir.
   - [ ] B quita a una persona mientras A edita a otra: no se mezclan.
   - [ ] Apagar el wifi del celular, cambiar un dato y volver a prenderlo: se guarda solo.
   - [ ] Cerrar el reparto: aparece en **Historial** para los dos y la suma cuadra al centavo.
   - [ ] Imprimir y exportar CSV desde el historial.
   - [ ] **Usuarios › Quitar acceso** a la cuenta B: B deja de ver datos.

## Etapa 2 · Producción

1. **Respaldo.** Si tu plan de Supabase incluye respaldos, revisa que haya uno reciente en **Database › Backups**. Si no, exporta como mínimo las tablas `repartos` y `templates` a CSV desde **Table Editor**, o usa `supabase db dump` si tienes la CLI.
2. **SQL.** En el proyecto real, ejecuta `supabase/04_rediseno.sql`. No importa si no recuerdas haber corrido el 03: el script revisa qué existe.
   - Tu app publicada sigue funcionando igual después de esto.
   - Si tenías un borrador guardado con la versión 2, se copia a las tablas nuevas.
   - Desde este momento nadie puede crear un segundo espacio. Si alguien crea una cuenta sin invitación, no ve nada.
3. **Frontend.** Sube a tu proyecto real de Cloudflare `index.html`, `styles.css`, `app.js`, la carpeta `js/` y **tu** `config.js` de producción. Ese archivo ya lo tienes y no cambia.
4. **Verifica con dos cuentas** que el borrador se sincroniza. Haz el cierre con el siguiente reparto real; el cierre ya lo comprobaste en la Etapa 1.
5. **Activar.** Cuando ya todos usen la versión nueva, ejecuta `supabase/05_activar_produccion.sql`. Desde ese momento el historial solo acepta repartos calculados y validados por el servidor.
6. Opcional, una semana después: descomenta la última línea de `05` para borrar la tabla vieja `reparto_borrador`.

## Si algo sale mal

- **«Could not find the function public.draft_get»**: falta ejecutar `04_rediseno.sql` en ese proyecto.
- **La app pide configurar Supabase**: revisa que `config.js` se haya subido y que la URL no termine en `/rest/v1/`.
- **El punto verde no se prende**: revisa **Database › Publications › supabase_realtime** y comprueba que la tabla `drafts` esté incluida (el script 04 la agrega). Aun sin punto verde, la app revisa cambios cada 20 segundos.
- **Volver a la versión anterior**: sube de nuevo tus archivos viejos a Cloudflare. Funcionan mientras no hayas ejecutado `05`.

## Reglas del cálculo (sin cambios de política)

- Cada área recibe su porcentaje del total. Los porcentajes deben sumar exactamente 100.
- Dentro de cada área: propina = fondo del área × (peso × días trabajados) ÷ suma del área.
- Días trabajados = días del periodo − descansos y faltas justificadas − faltas injustificadas.
- **Una falta injustificada o estar inactivo deja la propina en $0.** Valida esta regla con tu contador o abogado laboral.
- **Centavos exactos:** se redondea hacia abajo y los centavos que sobran se dan uno por uno a quienes tenían la fracción más grande. La suma siempre es igual al total.
- No se puede cerrar si un área tiene dinero pero nadie elegible. En ese caso, ajusta los porcentajes.
- Al cerrar, el reparto se vacía para iniciar el siguiente. Los porcentajes se conservan.
