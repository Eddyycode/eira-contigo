# EIRA Contigo

Entrega segura de resultados de Papanicolaou, con acompañamiento después del resultado.

Prototipo para el **Reto 4** de la **Nerdearla Vibeathon by Devin**, para **EIRA Movimiento Rosa A.C.**

> **Aviso:** TODOS los datos de este repositorio (pacientes, folios, resultados, PDFs, testimonios y recursos de apoyo) son **ficticios**. La única excepción es la Línea de la Vida (800 911 2000), que es real.

## Qué problema resuelve

Hoy el laboratorio entrega a EIRA los resultados impresos. EIRA los escanea, los asocia a cada paciente por su nombre y se los manda por WhatsApp (más de 300 al mes). Esto tiene varios problemas:

- **Las entregas dependen de WhatsApp.** Si bloquean la cuenta, se detienen.
- **No hay control de acceso ni registro.** La revisión no queda documentada y no hay seguimiento.
- **La asociación es manual y por nombre.** Es fácil confundir a dos pacientes con nombres parecidos.
- **La paciente recibe un PDF suelto.** No trae explicación ni le dice a quién acudir.

EIRA Contigo sustituye ese proceso por un flujo trazable:

```
carga (lab) → asociación verificada (admin) → revisión administrativa (admin)
→ autorización clínica (médico) → aviso neutro → acceso autenticado (paciente) → bitácora
```

- Una persona confirma cada asociación; **el sistema nunca asocia en automático**.
- La paciente **no ve nada hasta que el médico autoriza**.
- El aviso es neutro: sin diagnóstico, sin hallazgos y sin adjuntos.
- Las descargas usan **URLs firmadas que vencen en 5 minutos**. Nunca hay enlaces públicos.
- Cada acción queda en una **bitácora que solo admite inserciones**.
- Después del resultado, la paciente ve una explicación en lenguaje claro aprobada por EIRA, los estudios recomendados por el médico, espacios seguros para hablar y su red de apoyo.

**Si mañana bloquean WhatsApp, las entregas siguen.**

## Cómo correr el demo

El demo es estático y **no necesita credenciales** ni backend. Usa una de estas opciones:

- Abre `index.html` directamente en el navegador.
- O sírvelo localmente:

  ```bash
  npx serve .
  ```

  y abre la URL que imprime (por defecto http://localhost:3000).

## Diseño de producción con Supabase

El demo simula el backend en el navegador. En producción, el diseño usa Supabase:

| Pieza | Qué hace | Archivo |
|---|---|---|
| **Auth** | Personal (lab, admin, médico) con correo y contraseña. Paciente con folio EIRA + fecha de nacimiento + código OTP por SMS o correo. | — |
| **Postgres + RLS por rol** | Los permisos viven en la base de datos, no solo en el frontend. Triggers validan qué transiciones de estado puede hacer cada rol. | [`supabase/schema.sql`](supabase/schema.sql) |
| **Storage privado** | Bucket `resultados` privado, solo PDFs. Ruta `{paciente_id}/{resultado_id}.pdf`. La paciente no tiene acceso directo al bucket. | [`supabase/schema.sql`](supabase/schema.sql) |
| **Edge Function `signed-url`** | Valida rol y estado, devuelve una URL firmada de 300 s y registra la acción en la bitácora. | [`supabase/functions/signed-url/index.ts`](supabase/functions/signed-url/index.ts) |

### Roles (RLS)

| Rol | Puede | No puede |
|---|---|---|
| `lab` | Subir PDFs y ver el estado de las cargas de **su** laboratorio | Ver datos de pacientes, autorizar, ver cargas de otros laboratorios |
| `admin` | Asociar, revisar, enviar avisos, gestionar directorio de apoyo, contenido y testimonios | Autorizar clínicamente o modificar categoría y conducta |
| `medico` | Autorizar o rechazar, asignar categoría y conducta, recomendar estudios, aprobar contenido | — |
| `paciente` | Ver **solo sus** resultados en estado `autorizado`, `notificado`, `consultado` o `cerrado`, y pedir apoyo | Cualquier otra cosa |

La nota clínica privada se guarda en una tabla aparte (`notas_clinicas`) que solo puede leer el médico. RLS filtra filas, no columnas, así que esto evita que la paciente o el laboratorio la vean.

### Estados del resultado

```
cargado → asociado → revisado → autorizado → notificado → consultado → seguimiento_pendiente | cerrado
   ↘ observado (admin lo devuelve al lab)
                         ↘ rechazado_clinico (el médico pide repetir el estudio)
autorizado | notificado → entregado_asistido (entrega en persona)
```

### Despliegue

Requiere la [Supabase CLI](https://supabase.com/docs/guides/cli) y un proyecto de Supabase.

```bash
supabase link --project-ref <tu-project-ref>
supabase db push                       # o pega supabase/schema.sql en el SQL Editor
supabase functions deploy signed-url
supabase secrets set ALLOWED_ORIGIN=https://tu-dominio.example   # opcional, CORS
```

La Edge Function usa `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY`, que Supabase inyecta automáticamente. **Nunca expongas la service role key en el frontend.**

Para descargar un resultado, el frontend llama a la función con el token de la sesión:

```js
const { data } = await supabase.functions.invoke('signed-url', {
  body: { resultado_id, accion: 'descargar' }, // o 'ver'
});
window.location.href = data.url; // vence en 300 s
```

## Lo que el sistema NO hace

- No diagnostica ni interpreta resultados con IA en vivo. Toda explicación la aprueba un médico.
- No incluye diagnósticos en los avisos.
- No muestra datos de otras pacientes.
- No asocia resultados en automático.
- No usa enlaces públicos.

## Ayuda

Si necesitas hablar con alguien: **Línea de la Vida 800 911 2000** (gratuita, 24/7). En una emergencia, llama al **911**.

## Licencia

[MIT](LICENSE)
