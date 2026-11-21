# SPEC: EIRA Contigo (entrega segura de resultados de Papanicolaou + acompañamiento)

Nerdearla Vibeathon by Devin · Reto 4 · EIRA Movimiento Rosa A.C.

---

## 1. Problema

El laboratorio entrega a EIRA los resultados impresos. EIRA los escanea, los asocia a la paciente por su nombre y se los manda por WhatsApp (más de 300 al mes). Cuando bloquean la cuenta de WhatsApp, las entregas se detienen. La revisión no queda documentada, no hay control de acceso ni seguimiento, y la paciente recibe un PDF suelto, sin explicación y sin saber a quién acudir.

## 2. Propuesta

Una plataforma web (mobile-first del lado de la paciente) con dos capas:

1. **Núcleo (lo que pide el reto):** carga → asociación verificada → revisión administrativa → autorización clínica → aviso neutro → acceso autenticado → bitácora.
2. **Capa "Después de tu resultado":** explicación en lenguaje claro, estudios recomendados por el médico, espacios seguros para hablar, historias de otras mujeres con su consentimiento y red de apoyo.

> Regla del equipo: el núcleo se termina primero. La capa de acompañamiento se monta encima de resultados ya autorizados.

## 3. Stack

- **Frontend:** Vue 3 + Vite + Tailwind
- **Backend:** Supabase (Auth, Postgres con RLS, Storage privado, Edge Functions)
- **Notificaciones:** simuladas en una "bandeja de avisos" visible en el panel. Opcional: Resend (correo) y Twilio (SMS)
- **Opcional:** Claude API para generar *borradores* de explicación que el médico revisa y aprueba

## 4. Roles y permisos (aplicados con RLS en Postgres, no solo en el frontend)

| Rol | Puede | No puede |
|---|---|---|
| Laboratorio | Subir PDFs y ver el estado de lo que subió | Ver datos de contacto, autorizar, ver lo que subieron otros laboratorios |
| Admin EIRA | Asociar PDF a expediente, hacer la revisión administrativa, enviar avisos, gestionar el directorio de apoyo y los testimonios, ver el panel | Autorizar clínicamente |
| Médico | Autorizar o rechazar, asignar categoría y conducta a seguir, recomendar estudios, aprobar el contenido educativo | — |
| Paciente | Ver y descargar **solo sus** resultados autorizados, ver el contenido, solicitar apoyo | Cualquier otra cosa |

## 5. Flujo y estados

```
cargado → asociado → revisado → autorizado → notificado → consultado → seguimiento_pendiente | cerrado
            ↘ observado (admin lo devuelve al lab: ilegible / datos no coinciden)
                              ↘ rechazado_clinico (el médico pide repetir el estudio)
```

1. **Carga (lab):** sube el PDF con el folio EIRA, el nombre y la fecha de nacimiento tal como vienen en el reporte.
2. **Asociación con verificación de identidad (admin):** el sistema busca candidatas por folio, nombre (búsqueda difusa), fecha de nacimiento y teléfono, y muestra cada una con un puntaje. **Una persona confirma; el sistema nunca asocia en automático.** Si el folio o la fecha de nacimiento no coinciden, la asociación solo se puede confirmar escribiendo una justificación.
3. **Revisión administrativa:** se revisa que el documento sea legible, que los datos estén completos y que sea el documento correcto. Si algo falla, pasa a `observado`.
4. **Autorización clínica (médico):** el médico ve el PDF y asigna la categoría del resultado (catálogo Bethesda simplificado), la conducta a seguir, los estudios recomendados y una nota privada. **Hasta este paso la paciente no ve nada.**
5. **Aviso neutro (SMS o correo):**
   > "Hola, [nombre de pila]. EIRA tiene un documento disponible para ti. Entra aquí con tu fecha de nacimiento: [url]/#f=[folio en dígitos]"

   No lleva diagnóstico, hallazgos, palabras como "anormal" ni archivos adjuntos. El enlace solo precarga el folio, que la paciente ya tiene; quien lo abra sigue necesitando su fecha de nacimiento y el OTP.
6. **Acceso de la paciente:** folio EIRA + fecha de nacimiento + código OTP (por SMS o correo). El folio es `EIRA-` + 6 dígitos y el último es verificador (Luhn): un número mal escrito se detecta al capturarlo, antes de enviar nada. Se acepta con o sin `EIRA-`, con espacios y con la letra O como cero. El enlace del aviso abre la entrada con el folio ya escrito, y el código OTP se autollena desde el SMS (`autocomplete="one-time-code"`) y entra en cuanto se completa. La descarga usa una URL firmada que vence en 5 minutos. **Nunca hay enlaces públicos permanentes.**
7. **Bitácora:** cada acción (subir, asociar, revisar, autorizar, notificar, ver, descargar) queda registrada con quién la hizo, cuándo y sobre qué. Solo admite inserciones: nada se edita ni se borra.

### Alternativas asistidas (para pacientes sin correo, sin teléfono propio o sin internet)

- **Entrega asistida:** la paciente va a una jornada o a la sede, el personal de EIRA verifica su identidad y le entrega el resultado. Se registra como `entregado_asistido`.
- **Código impreso de un solo uso:** se le da a la paciente cuando le toman la muestra.
- **Contacto de confianza:** una persona que la paciente autoriza, con su consentimiento registrado. Recibe el aviso, **nunca el resultado**.

## 6. Capa "Después de tu resultado"

Solo aparece dentro del acceso autenticado y solo para resultados ya autorizados.

### 6.1 Educación y prevención
- Contenido por categoría de resultado, en lenguaje claro, escrito y aprobado por EIRA (con versión y nombre de quien lo aprobó). Secciones: "¿Qué significa este resultado?", "¿Qué sigue?", "Mitos y realidades".
- Contenido para todas las pacientes: VPH y vacunación, autoexploración mamaria y cada cuánto repetir los estudios según lo indique su médico.
- Opcional: Claude escribe un borrador a partir del contenido ya aprobado, y el médico lo edita y lo aprueba antes de publicarlo. **Nunca se genera texto clínico en vivo para la paciente.**

### 6.2 Estudios recomendados
- Al autorizar, el médico elige la conducta a seguir de un catálogo: control de rutina, repetir citología, colposcopía, prueba de VPH o referencia a especialista.
- El sistema sugiere estudios complementarios con reglas configurables que define el médico de EIRA (referencias: NOM-014-SSA2 para cáncer cervicouterino y NOM-041-SSA2 para cáncer de mama), usando la edad y los antecedentes del expediente. Ejemplo: si la paciente tiene edad de tamizaje mamario y no tiene mastografía registrada, se sugiere la revisión mamaria de EIRA.
- **Las sugerencias las confirma el médico.** La paciente solo ve las recomendaciones confirmadas.
- La paciente puede pedir que le recuerden su próximo estudio y apartar lugar en la siguiente jornada de su municipio.

### 6.3 Espacios seguros para hablar
- Directorio curado por EIRA con grupos de apoyo, terapeutas (gratuitos o de bajo costo) y líneas de ayuda. Filtros por municipio, modalidad (presencial o en línea) y costo. Cada recurso tiene la marca `verificado_por_eira`.
- Botón **"Quiero hablar con alguien de EIRA"**: crea una solicitud de contacto que atiende el equipo. En el MVP no hay chat en vivo.
- Siempre visible: **Línea de la Vida 800 911 2000** (gratuita, 24/7). En una emergencia, llamar al **911**.

### 6.4 Situaciones similares, sin exponer a nadie
**Nunca se muestran datos ni resultados de otras pacientes.** En su lugar:
- **Historias compartidas con consentimiento:** testimonios que otras mujeres aceptaron compartir. Se guarda el consentimiento, se anonimizan, EIRA los revisa antes de publicarlos y se etiquetan por categoría. Cada paciente ve las historias de su misma categoría.
- **Cifras agregadas de EIRA:** "Este año EIRA acompañó a N mujeres con un resultado como el tuyo". Solo se muestra si N ≥ 10, para que nadie pueda ser identificada.

### 6.5 Red de apoyo
- **Círculos de apoyo** por situación, moderados por EIRA. La paciente pide unirse y EIRA confirma. En el MVP: directorio y solicitud, sin foro abierto.
- **Acompañantes ("madrinas"):** voluntarias que ya pasaron por un proceso parecido. EIRA las conecta con la paciente cuando ella lo pide.
- **Contacto de confianza:** la paciente puede invitar a alguien a acompañarla. Esa persona no ve el resultado, a menos que ella lo comparta de forma explícita.

## 7. Modelo de datos (Supabase)

```
profiles(id uuid pk → auth.users, rol enum[lab,admin,medico,paciente], nombre, laboratorio_id)

pacientes(id, folio_eira unique, nombre, fecha_nacimiento, telefono, email, municipio,
          user_id → auth.users null, contacto_confianza jsonb, consentimiento_contacto_at)

resultados(id, paciente_id null, archivo_path, estado enum,
           folio_reportado, nombre_reportado, fecha_nac_reportada,
           categoria, conducta, nota_clinica_privada,
           match_score, match_justificacion,
           subido_por, asociado_por, revisado_por, autorizado_por,
           created_at, autorizado_at)

recomendaciones(id, resultado_id, estudio, origen enum[medico,regla], confirmada bool, confirmada_por)

avisos(id, resultado_id, canal enum[sms,email,asistido], destinatario, plantilla, estado, enviado_at)

bitacora(id, actor_id, rol, accion, entidad, entidad_id, detalle jsonb, created_at)   -- solo INSERT

contenido_educativo(id, categoria, titulo, cuerpo_md, version, aprobado_por, aprobado_at, publicado)

reglas_recomendacion(id, nombre, condicion jsonb, estudio_sugerido, activa, aprobada_por)

recursos_apoyo(id, tipo enum[grupo,terapeuta,linea,madrina,circulo], nombre, municipio,
               modalidad, costo, contacto, verificado_por_eira)

solicitudes_apoyo(id, paciente_id, tipo, recurso_id null, mensaje, estado, atendida_por)

testimonios(id, categoria, texto, consentimiento_at, revisado_por, publicado)
```

**Storage:** bucket `resultados` privado, con la ruta `resultados/{paciente_id}/{resultado_id}.pdf`. Las descargas pasan por una Edge Function que valida el rol y que el estado sea `autorizado` o posterior, devuelve una URL firmada de 300 s y registra la descarga en la bitácora.

**Catálogo de categorías (Bethesda simplificado):** negativo para lesión intraepitelial o malignidad · ASC-US · ASC-H · LSIL · HSIL · AGC · carcinoma · muestra inadecuada.

## 8. Pantallas

**Personal:**
1. Login del personal
2. Laboratorio: subir PDF y lista de sus cargas con su estado
3. Admin: bandeja de asociación (candidatas con puntaje y botón para confirmar), revisión y envío de avisos
4. Médico: cola de autorización (PDF a la izquierda, formulario a la derecha)
5. Panel de estados: conteo por estado, resultados atorados y filtro por municipio
6. Bitácora de cada resultado
7. Admin: directorio de apoyo, contenido educativo y testimonios

**Paciente (mobile-first):**
8. Acceso con folio, fecha de nacimiento y OTP
9. Mis documentos
10. Resultado: descargar el PDF · **Qué significa** · **Qué sigue** (estudios) · **No estás sola** (historias, red y espacios seguros) · **Quiero hablar con alguien**

## 9. Lo que el sistema NO hace (mencionarlo en el pitch)

- No diagnostica ni interpreta resultados con IA en vivo. Toda explicación la aprueba un médico.
- No incluye diagnósticos en los avisos.
- No muestra datos de otras pacientes.
- No asocia resultados en automático.
- No usa enlaces públicos.

## 10. Plan para entregar a las 16:00 (alcance recortado)

**Construir en este orden, hasta las 15:30 como máximo:**
1. Esquema mínimo: `pacientes`, `resultados` (con estado), `bitacora`, `contenido_educativo`, `recursos_apoyo`, y RLS por rol.
2. Bucket privado y descarga con URL firmada.
3. Lado del personal: subir PDF → asociar (candidatas con puntaje y botón de confirmar) → autorizar (categoría, conducta y un estudio recomendado) → aviso simulado en el panel.
4. Lado de la paciente: acceso con folio, fecha de nacimiento y OTP (puede ser un código simulado) → ver y descargar → pestaña "Después de tu resultado" con el contenido semilla, el estudio recomendado, el directorio de apoyo, 1 testimonio de ejemplo y el botón "Quiero hablar con alguien".
5. Bitácora visible por resultado.

**Queda como roadmap en el pitch, sin construir:** reglas automáticas de recomendación, borradores con Claude, notificaciones reales, entrega asistida, círculos y madrinas, cifras agregadas.

**15:30 a 15:50, entrega:** README (cómo correrlo, qué variables de entorno y servicios necesita, aviso de que todos los datos son ficticios), licencia MIT, repo público y envío en Devpost.
**15:50 a 16:00:** ensayar el pitch de 2 minutos.

## 11. Datos semilla (todos ficticios y marcados como tal)

- 3 pacientes ficticias; dos con nombres parecidos para lucir la detección de coincidencias
- 3 PDFs sintéticos con la leyenda "DOCUMENTO DE PRUEBA – DATOS FICTICIOS"
- 1 usuario por rol
- Contenido educativo de ejemplo marcado con "texto de ejemplo, lo debe validar EIRA"
- 5 recursos de apoyo ficticios. Única excepción: la Línea de la Vida, que es real

## 12. Guion de la demo (2 min)

1. El laboratorio sube el PDF de "María Ejemplo".
2. El admin ve que el sistema encontró 2 candidatas parecidas y confirma la correcta con el folio y la fecha de nacimiento.
3. El médico autoriza el resultado y marca la conducta a seguir y un estudio recomendado.
4. En el panel aparece el aviso enviado; se lee en voz alta para mostrar que no lleva diagnóstico.
5. La paciente entra desde el celular con folio + OTP, descarga el PDF (la URL vence), ve la explicación, el estudio recomendado, las historias y la red de apoyo, y pide hablar con alguien.
6. La bitácora muestra cada paso, con quién lo hizo y cuándo.
7. Cierre: **"Si mañana bloquean WhatsApp, las entregas siguen."** Y una línea de visión: el expediente de la paciente ya está diseñado para conectarse después con el expediente único (Reto 1) y con los indicadores de impacto (Reto 3).