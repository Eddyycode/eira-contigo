Demo en vivo: https://eddyycode.github.io/eira-contigo/

# EIRA Contigo

Entrega digital segura de resultados de Papanicolaou, con acompañamiento para la paciente.
**Reto 4 · Nerdearla Vibeathon by Devin · para EIRA Movimiento Rosa A.C.**

> ⚠️ Prototipo. **Todos los datos son ficticios.** No usar con datos reales de pacientes. Cualquier uso clínico requiere la revisión posterior de EIRA.

## El problema
Hoy EIRA recibe los resultados impresos, los escanea, los asocia a cada paciente por su nombre y los manda por WhatsApp (más de 300 al mes). Cuando bloquean la cuenta, las entregas se detienen. La revisión no queda documentada, no hay control de acceso y la paciente recibe un PDF suelto, sin explicación.

## Qué hace
**Núcleo (lo que pide el reto)**
1. **Laboratorio:** sube el PDF escaneado con los datos tal como vienen en el reporte.
2. **Admin EIRA:** el sistema sugiere expedientes con un puntaje de coincidencia (folio, fecha de nacimiento y nombre) y **una persona confirma**. Nunca se asocia en automático, y si el folio o la fecha no coinciden se exige una justificación. Después viene una revisión administrativa con lista de verificación.
3. **Médica:** autoriza el resultado y asigna categoría (Bethesda simplificado), conducta a seguir y estudios recomendados. El sistema sugiere estudios con reglas configurables, pero la médica confirma. Los resultados graves se marcan como **entrega acompañada**: no se publican en línea y se entregan en persona.
4. **Aviso neutro** por SMS o correo, **sin diagnóstico**. Para pacientes sin teléfono propio o sin conectividad hay entrega asistida.
5. **Paciente:** entra con folio, fecha de nacimiento y un código OTP. El documento se abre con un **enlace firmado que vence en 5 minutos**; no hay enlaces públicos.
6. **Bitácora** de solo inserción: quién hizo qué, cuándo y sobre qué resultado. Además, un panel de estados con resultados atorados.

**Acompañamiento ("Después de tu resultado")**
- Qué significa el resultado, en lenguaje claro y con texto aprobado por EIRA.
- Qué sigue: la conducta indicada, los estudios recomendados y la opción de apartar lugar en la próxima brigada.
- No estás sola: historias compartidas **con consentimiento** (nunca datos de otras pacientes), grupos de apoyo, terapia, madrinas, Línea de la Vida (800 911 2000) y el botón "Quiero hablar con alguien de EIRA".
- Contenido de prevención.

**Brigadas e historiales**
- Registro de brigadas por municipio y fecha, con sus servicios.
- Recuperación del historial de cada paciente por brigada, o buscándola por folio o nombre.
- La paciente ve su propio historial y el catálogo de **Servicios EIRA** con las próximas brigadas de su municipio. Esta sección es solo informativa.

## Cómo correrlo
No necesita instalación ni credenciales:

```bash
# opción 1: abrir index.html en el navegador
# opción 2:
npx serve .
```

Para la demo, cambia de rol con los botones de arriba: Laboratorio → Admin EIRA → Médica → Admin EIRA (Avisos) → Paciente. En el formulario del laboratorio está **"Llenar con ejemplo"** y en el acceso de la paciente, **"Usar paciente de ejemplo"**. El código OTP aparece en pantalla en modo demo. **"Reiniciar demo"** restaura los datos semilla.

El prototipo guarda su estado en el `localStorage` del navegador y simula el backend en el cliente.

## Diseño de producción
- **Supabase:** Auth (OTP por SMS o correo), Postgres con **RLS por rol** (lab, admin, médico, paciente), **Storage privado** y una **Edge Function** que valida rol y estado antes de emitir una URL firmada de 300 s y registrar la descarga en la bitácora.
- La tabla `bitacora` solo admite `INSERT`.
- La paciente solo puede leer sus resultados con estado `autorizado`, `notificado`, `consultado` o `cerrado`.
- Notificaciones con Twilio (SMS) o Resend (correo), siempre con plantillas neutras.

Ver [`SPEC-eira-resultados.md`](SPEC-eira-resultados.md), [`supabase/schema.sql`](supabase/schema.sql) (tablas, RLS y bucket privado) y [`supabase/functions/signed-url`](supabase/functions/signed-url/index.ts) (URL firmada de 300 s).

## Lo que NO hace
- No diagnostica ni interpreta resultados con IA. Toda explicación la aprueba personal médico.
- No incluye diagnósticos en los avisos.
- No muestra datos de otras pacientes.
- No asocia resultados en automático.
- No usa enlaces públicos.

## Licencia
MIT
