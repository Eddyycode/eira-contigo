-- =============================================================================
-- EIRA Contigo · Esquema de producción para Supabase
-- Entrega segura de resultados de Papanicolaou (Nerdearla Vibeathon · Reto 4)
--
-- Ejecutar en el SQL Editor de Supabase o con `supabase db push`.
-- Todos los permisos se aplican con RLS en Postgres, no solo en el frontend.
-- =============================================================================

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;   -- búsqueda difusa de nombres en la asociación

-- -----------------------------------------------------------------------------
-- 1. Enums
-- -----------------------------------------------------------------------------
create type public.rol_usuario as enum ('lab', 'admin', 'medico', 'paciente');

create type public.estado_resultado as enum (
  'cargado',                -- el laboratorio subió el PDF
  'asociado',               -- el admin confirmó a qué paciente pertenece
  'observado',              -- el admin lo devolvió al lab (ilegible / datos no coinciden)
  'revisado',               -- revisión administrativa aprobada
  'autorizado',             -- el médico lo autorizó (a partir de aquí la paciente lo puede ver)
  'rechazado_clinico',      -- el médico pide repetir el estudio
  'notificado',             -- se envió el aviso neutro
  'consultado',             -- la paciente lo vio o descargó
  'seguimiento_pendiente',  -- hay un estudio o cita pendiente
  'cerrado',
  'entregado_asistido'      -- entregado en persona por personal de EIRA
);

create type public.categoria_bethesda as enum (
  'negativo', 'asc_us', 'asc_h', 'lsil', 'hsil', 'agc', 'carcinoma', 'muestra_inadecuada'
);

create type public.conducta_clinica as enum (
  'control_rutina', 'repetir_citologia', 'colposcopia', 'prueba_vph', 'referencia_especialista'
);

create type public.origen_recomendacion as enum ('medico', 'regla');
create type public.canal_aviso          as enum ('sms', 'email', 'asistido');
create type public.estado_aviso         as enum ('pendiente', 'enviado', 'fallido');
create type public.tipo_recurso         as enum ('grupo', 'terapeuta', 'linea', 'madrina', 'circulo');
create type public.estado_solicitud     as enum ('abierta', 'en_proceso', 'atendida');

-- -----------------------------------------------------------------------------
-- 2. Tablas
-- -----------------------------------------------------------------------------
create table public.laboratorios (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id             uuid primary key references auth.users (id) on delete cascade,
  rol            public.rol_usuario not null,
  nombre         text not null,
  laboratorio_id uuid references public.laboratorios (id),
  created_at     timestamptz not null default now(),
  constraint lab_requiere_laboratorio check (rol <> 'lab' or laboratorio_id is not null)
);

create table public.pacientes (
  id                         uuid primary key default gen_random_uuid(),
  folio_eira                 text not null unique,
  nombre                     text not null,
  fecha_nacimiento           date not null,
  telefono                   text,
  email                      text,
  municipio                  text,
  user_id                    uuid unique references auth.users (id) on delete set null,
  contacto_confianza         jsonb,          -- recibe el aviso, NUNCA el resultado
  consentimiento_contacto_at timestamptz,
  created_at                 timestamptz not null default now(),
  constraint contacto_confianza_requiere_consentimiento
    check (contacto_confianza is null or consentimiento_contacto_at is not null)
);
create index pacientes_nombre_trgm on public.pacientes using gin (nombre gin_trgm_ops);

create table public.resultados (
  id                   uuid primary key default gen_random_uuid(),
  paciente_id          uuid references public.pacientes (id),
  laboratorio_id       uuid not null references public.laboratorios (id),
  archivo_path         text not null,         -- ruta dentro del bucket privado "resultados"
  estado               public.estado_resultado not null default 'cargado',
  folio_reportado      text,
  nombre_reportado     text,
  fecha_nac_reportada  date,
  categoria            public.categoria_bethesda,
  conducta             public.conducta_clinica,
  match_score          numeric(5, 2),
  match_justificacion  text,
  subido_por           uuid not null references auth.users (id),
  asociado_por         uuid references auth.users (id),
  revisado_por         uuid references auth.users (id),
  autorizado_por       uuid references auth.users (id),
  created_at           timestamptz not null default now(),
  autorizado_at        timestamptz,
  constraint asociado_requiere_paciente
    check (estado in ('cargado', 'observado') or paciente_id is not null),
  constraint autorizado_requiere_clinica
    check (estado not in ('autorizado', 'notificado', 'consultado', 'seguimiento_pendiente', 'cerrado')
           or (categoria is not null and conducta is not null and autorizado_por is not null))
);
create index resultados_estado_idx   on public.resultados (estado);
create index resultados_paciente_idx on public.resultados (paciente_id);

-- La nota clínica privada (sección 7 del SPEC: resultados.nota_clinica_privada) vive en su
-- propia tabla: RLS filtra filas, no columnas, y así ni la paciente ni el laboratorio pueden
-- leerla aunque vean la fila del resultado.
create table public.notas_clinicas (
  resultado_id         uuid primary key references public.resultados (id) on delete cascade,
  nota_clinica_privada text not null,
  autor_id             uuid not null default auth.uid() references auth.users (id),
  updated_at           timestamptz not null default now()
);

create table public.recomendaciones (
  id             uuid primary key default gen_random_uuid(),
  resultado_id   uuid not null references public.resultados (id) on delete cascade,
  estudio        text not null,
  origen         public.origen_recomendacion not null default 'medico',
  confirmada     boolean not null default false,
  confirmada_por uuid references auth.users (id),
  created_at     timestamptz not null default now(),
  constraint confirmada_requiere_medico check (not confirmada or confirmada_por is not null)
);

create table public.avisos (
  id           uuid primary key default gen_random_uuid(),
  resultado_id uuid not null references public.resultados (id) on delete cascade,
  canal        public.canal_aviso not null,
  destinatario text not null,
  -- Aviso neutro: sin diagnóstico, sin hallazgos, sin adjuntos.
  plantilla    text not null default
    'Hola, {nombre_pila}. EIRA tiene un documento disponible para ti. Entra a {url} con tu folio.',
  estado       public.estado_aviso not null default 'pendiente',
  enviado_at   timestamptz,
  created_at   timestamptz not null default now()
);

create table public.bitacora (
  id         bigint generated always as identity primary key,
  actor_id   uuid references auth.users (id),
  rol        public.rol_usuario,
  accion     text not null,   -- subir, asociar, revisar, autorizar, notificar, ver, descargar, ...
  entidad    text not null,
  entidad_id uuid,
  detalle    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index bitacora_entidad_idx on public.bitacora (entidad, entidad_id, created_at);

create table public.contenido_educativo (
  id           uuid primary key default gen_random_uuid(),
  categoria    public.categoria_bethesda,  -- null = contenido para todas las pacientes
  titulo       text not null,
  cuerpo_md    text not null,
  version      int not null default 1,
  aprobado_por uuid references auth.users (id),
  aprobado_at  timestamptz,
  publicado    boolean not null default false,
  constraint publicado_requiere_aprobacion
    check (not publicado or (aprobado_por is not null and aprobado_at is not null))
);

create table public.reglas_recomendacion (
  id               uuid primary key default gen_random_uuid(),
  nombre           text not null,
  condicion        jsonb not null,
  estudio_sugerido text not null,
  activa           boolean not null default false,
  aprobada_por     uuid references auth.users (id),
  constraint activa_requiere_aprobacion check (not activa or aprobada_por is not null)
);

create table public.recursos_apoyo (
  id                  uuid primary key default gen_random_uuid(),
  tipo                public.tipo_recurso not null,
  nombre              text not null,
  municipio           text,
  modalidad           text check (modalidad in ('presencial', 'en_linea', 'mixta')),
  costo               text,
  contacto            text,
  verificado_por_eira boolean not null default false
);

create table public.solicitudes_apoyo (
  id           uuid primary key default gen_random_uuid(),
  paciente_id  uuid not null references public.pacientes (id) on delete cascade,
  tipo         text not null default 'hablar_con_eira',
  recurso_id   uuid references public.recursos_apoyo (id),
  mensaje      text,
  estado       public.estado_solicitud not null default 'abierta',
  atendida_por uuid references auth.users (id),
  created_at   timestamptz not null default now()
);

create table public.testimonios (
  id                uuid primary key default gen_random_uuid(),
  categoria         public.categoria_bethesda,
  texto             text not null,     -- ya anonimizado
  consentimiento_at timestamptz not null,
  revisado_por      uuid references auth.users (id),
  publicado         boolean not null default false,
  constraint publicado_requiere_revision check (not publicado or revisado_por is not null)
);

-- -----------------------------------------------------------------------------
-- 3. Funciones auxiliares para RLS
--    SECURITY DEFINER evita recursión de RLS al consultar profiles / pacientes.
-- -----------------------------------------------------------------------------
create or replace function public.rol_actual()
returns public.rol_usuario
language sql stable security definer set search_path = public as $$
  select rol from public.profiles where id = auth.uid()
$$;

create or replace function public.laboratorio_actual()
returns uuid
language sql stable security definer set search_path = public as $$
  select laboratorio_id from public.profiles where id = auth.uid()
$$;

create or replace function public.paciente_actual()
returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.pacientes where user_id = auth.uid()
$$;

-- Estados en los que la paciente puede ver su resultado.
create or replace function public.estado_visible_paciente(e public.estado_resultado)
returns boolean
language sql immutable as $$
  select e in ('autorizado', 'notificado', 'consultado', 'cerrado')
$$;

create or replace function public.resultado_visible_paciente(p_resultado_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.resultados r
    where r.id = p_resultado_id
      and r.paciente_id = public.paciente_actual()
      and public.estado_visible_paciente(r.estado)
  )
$$;

-- Categorías de los resultados visibles de la paciente actual (para contenido y testimonios).
create or replace function public.categorias_paciente_actual()
returns setof public.categoria_bethesda
language sql stable security definer set search_path = public as $$
  select distinct r.categoria from public.resultados r
  where r.paciente_id = public.paciente_actual()
    and public.estado_visible_paciente(r.estado)
    and r.categoria is not null
$$;

-- -----------------------------------------------------------------------------
-- 4. Reglas de negocio en triggers
-- -----------------------------------------------------------------------------

-- 4.1 Transiciones de estado permitidas por rol. El service_role (Edge Functions) no tiene
--     auth.uid() y puede, por ejemplo, marcar un resultado como "consultado".
create or replace function public.validar_resultado()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_rol      public.rol_usuario := public.rol_actual();
  v_paciente public.pacientes;
begin
  if auth.uid() is null then
    return new;  -- service_role / tareas del sistema
  end if;

  if new.laboratorio_id is distinct from old.laboratorio_id
     or new.subido_por is distinct from old.subido_por
     or new.created_at is distinct from old.created_at then
    raise exception 'No se puede modificar el origen del resultado';
  end if;

  -- Solo el médico toca los campos clínicos.
  if v_rol <> 'medico' and (
       new.categoria      is distinct from old.categoria
    or new.conducta       is distinct from old.conducta
    or new.autorizado_por is distinct from old.autorizado_por
    or new.autorizado_at  is distinct from old.autorizado_at) then
    raise exception 'Solo el médico puede modificar la información clínica';
  end if;

  if new.estado is distinct from old.estado then
    if not (
      (v_rol = 'admin' and (old.estado, new.estado) in (
          ('cargado',    'asociado'),
          ('cargado',    'observado'),
          ('asociado',   'observado'),
          ('asociado',   'revisado'),
          ('autorizado', 'notificado'),
          ('autorizado', 'entregado_asistido'),
          ('notificado', 'entregado_asistido'),
          ('consultado', 'seguimiento_pendiente'),
          ('consultado', 'cerrado'),
          ('seguimiento_pendiente', 'cerrado'),
          ('entregado_asistido',    'cerrado')))
      or
      (v_rol = 'medico' and (old.estado, new.estado) in (
          ('revisado', 'autorizado'),
          ('revisado', 'rechazado_clinico')))
    ) then
      raise exception 'Transición % -> % no permitida para el rol %', old.estado, new.estado, v_rol;
    end if;

    if new.estado = 'asociado' then
      new.asociado_por := auth.uid();
      -- El sistema nunca asocia en automático: si folio o fecha de nacimiento no coinciden,
      -- la persona que confirma debe escribir una justificación.
      select * into v_paciente from public.pacientes where id = new.paciente_id;
      if (new.folio_reportado is distinct from v_paciente.folio_eira
          or new.fecha_nac_reportada is distinct from v_paciente.fecha_nacimiento)
         and coalesce(btrim(new.match_justificacion), '') = '' then
        raise exception 'El folio o la fecha de nacimiento no coinciden: se requiere justificación';
      end if;
    elsif new.estado = 'revisado' then
      new.revisado_por := auth.uid();
    elsif new.estado in ('autorizado', 'rechazado_clinico') then
      new.autorizado_por := auth.uid();
      new.autorizado_at  := now();
    end if;
  elsif new.paciente_id is distinct from old.paciente_id then
    raise exception 'La paciente solo se asigna al confirmar la asociación';
  end if;

  return new;
end;
$$;

create trigger resultados_validar
  before update on public.resultados
  for each row execute function public.validar_resultado();

-- 4.2 Cada alta y cambio de estado queda en la bitácora del lado del servidor.
create or replace function public.registrar_estado_resultado()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.bitacora (actor_id, rol, accion, entidad, entidad_id, detalle)
    values (auth.uid(), public.rol_actual(), 'subir', 'resultado', new.id,
            jsonb_build_object('estado', new.estado, 'archivo_path', new.archivo_path));
  elsif new.estado is distinct from old.estado then
    insert into public.bitacora (actor_id, rol, accion, entidad, entidad_id, detalle)
    values (auth.uid(), public.rol_actual(),
            case new.estado
              when 'asociado'           then 'asociar'
              when 'observado'          then 'observar'
              when 'revisado'           then 'revisar'
              when 'autorizado'         then 'autorizar'
              when 'rechazado_clinico'  then 'rechazar'
              when 'notificado'         then 'notificar'
              when 'consultado'         then 'consultar'
              when 'entregado_asistido' then 'entregar_asistido'
              when 'cerrado'            then 'cerrar'
              else 'cambiar_estado'
            end,
            'resultado', new.id,
            jsonb_build_object('de', old.estado, 'a', new.estado));
  end if;
  return new;
end;
$$;

create trigger resultados_bitacora
  after insert or update on public.resultados
  for each row execute function public.registrar_estado_resultado();

-- 4.3 Bitácora: solo INSERT. Bloquea UPDATE / DELETE / TRUNCATE incluso para service_role.
create or replace function public.bitacora_solo_insert()
returns trigger
language plpgsql as $$
begin
  raise exception 'La bitácora solo admite inserciones (% bloqueado)', tg_op;
end;
$$;

create trigger bitacora_no_update_delete
  before update or delete on public.bitacora
  for each row execute function public.bitacora_solo_insert();

create trigger bitacora_no_truncate
  before truncate on public.bitacora
  for each statement execute function public.bitacora_solo_insert();

-- -----------------------------------------------------------------------------
-- 5. Privilegios base
-- -----------------------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke update, delete, truncate on public.bitacora from authenticated, anon;
grant  select, insert on public.bitacora to authenticated;
-- profiles solo los crea/edita el service_role: nadie puede cambiarse el rol.
revoke insert, update, delete on public.profiles from authenticated;

-- -----------------------------------------------------------------------------
-- 6. Row Level Security
-- -----------------------------------------------------------------------------
alter table public.laboratorios         enable row level security;
alter table public.profiles             enable row level security;
alter table public.pacientes            enable row level security;
alter table public.resultados           enable row level security;
alter table public.notas_clinicas       enable row level security;
alter table public.recomendaciones      enable row level security;
alter table public.avisos               enable row level security;
alter table public.bitacora             enable row level security;
alter table public.contenido_educativo  enable row level security;
alter table public.reglas_recomendacion enable row level security;
alter table public.recursos_apoyo       enable row level security;
alter table public.solicitudes_apoyo    enable row level security;
alter table public.testimonios          enable row level security;

-- laboratorios -----------------------------------------------------------------
create policy laboratorios_select on public.laboratorios for select to authenticated
  using (public.rol_actual() in ('admin', 'medico') or id = public.laboratorio_actual());
create policy laboratorios_admin on public.laboratorios for all to authenticated
  using (public.rol_actual() = 'admin') with check (public.rol_actual() = 'admin');

-- profiles ---------------------------------------------------------------------
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.rol_actual() in ('admin', 'medico'));

-- pacientes (el laboratorio NO ve datos de contacto) ---------------------------
create policy pacientes_staff_select on public.pacientes for select to authenticated
  using (public.rol_actual() in ('admin', 'medico'));
create policy pacientes_propia_select on public.pacientes for select to authenticated
  using (user_id = auth.uid());
create policy pacientes_admin_insert on public.pacientes for insert to authenticated
  with check (public.rol_actual() = 'admin');
create policy pacientes_admin_update on public.pacientes for update to authenticated
  using (public.rol_actual() = 'admin') with check (public.rol_actual() = 'admin');

-- resultados -------------------------------------------------------------------
-- Laboratorio: sube y ve solo lo de su laboratorio.
create policy resultados_lab_insert on public.resultados for insert to authenticated
  with check (
    public.rol_actual() = 'lab'
    and estado = 'cargado'
    and paciente_id is null
    and subido_por = auth.uid()
    and laboratorio_id = public.laboratorio_actual()
    and categoria is null and conducta is null and autorizado_por is null
  );
create policy resultados_lab_select on public.resultados for select to authenticated
  using (public.rol_actual() = 'lab' and laboratorio_id = public.laboratorio_actual());

-- Admin y médico: ven todo; las transiciones permitidas las valida validar_resultado().
create policy resultados_staff_select on public.resultados for select to authenticated
  using (public.rol_actual() in ('admin', 'medico'));
create policy resultados_admin_update on public.resultados for update to authenticated
  using (public.rol_actual() = 'admin') with check (public.rol_actual() = 'admin');
create policy resultados_medico_update on public.resultados for update to authenticated
  using (public.rol_actual() = 'medico' and estado = 'revisado')
  with check (public.rol_actual() = 'medico');

-- Paciente: solo SUS resultados y solo autorizados o posteriores.
create policy resultados_paciente_select on public.resultados for select to authenticated
  using (
    public.rol_actual() = 'paciente'
    and paciente_id = public.paciente_actual()
    and public.estado_visible_paciente(estado)
  );

-- notas_clinicas (solo médico) -------------------------------------------------
create policy notas_medico on public.notas_clinicas for all to authenticated
  using (public.rol_actual() = 'medico') with check (public.rol_actual() = 'medico');

-- recomendaciones --------------------------------------------------------------
create policy recomendaciones_medico on public.recomendaciones for all to authenticated
  using (public.rol_actual() = 'medico') with check (public.rol_actual() = 'medico');
create policy recomendaciones_admin_select on public.recomendaciones for select to authenticated
  using (public.rol_actual() = 'admin');
create policy recomendaciones_paciente_select on public.recomendaciones for select to authenticated
  using (confirmada and public.resultado_visible_paciente(resultado_id));

-- avisos -----------------------------------------------------------------------
create policy avisos_admin on public.avisos for all to authenticated
  using (public.rol_actual() = 'admin') with check (public.rol_actual() = 'admin');
create policy avisos_medico_select on public.avisos for select to authenticated
  using (public.rol_actual() = 'medico');

-- bitacora (solo INSERT; lectura para admin y médico) --------------------------
create policy bitacora_insert on public.bitacora for insert to authenticated
  with check (actor_id = auth.uid() and rol is not distinct from public.rol_actual());
create policy bitacora_select on public.bitacora for select to authenticated
  using (public.rol_actual() in ('admin', 'medico'));

-- contenido_educativo ----------------------------------------------------------
create policy contenido_staff on public.contenido_educativo for all to authenticated
  using (public.rol_actual() in ('admin', 'medico'))
  with check (public.rol_actual() in ('admin', 'medico'));
create policy contenido_paciente_select on public.contenido_educativo for select to authenticated
  using (
    publicado
    and public.rol_actual() = 'paciente'
    and (categoria is null or categoria in (select public.categorias_paciente_actual()))
  );

-- reglas_recomendacion ---------------------------------------------------------
create policy reglas_medico on public.reglas_recomendacion for all to authenticated
  using (public.rol_actual() = 'medico') with check (public.rol_actual() = 'medico');
create policy reglas_admin_select on public.reglas_recomendacion for select to authenticated
  using (public.rol_actual() = 'admin');

-- recursos_apoyo ---------------------------------------------------------------
create policy recursos_admin on public.recursos_apoyo for all to authenticated
  using (public.rol_actual() = 'admin') with check (public.rol_actual() = 'admin');
create policy recursos_select on public.recursos_apoyo for select to authenticated
  using (verificado_por_eira or public.rol_actual() in ('admin', 'medico'));

-- solicitudes_apoyo ------------------------------------------------------------
create policy solicitudes_paciente_insert on public.solicitudes_apoyo for insert to authenticated
  with check (paciente_id = public.paciente_actual() and estado = 'abierta' and atendida_por is null);
create policy solicitudes_paciente_select on public.solicitudes_apoyo for select to authenticated
  using (paciente_id = public.paciente_actual());
create policy solicitudes_admin on public.solicitudes_apoyo for all to authenticated
  using (public.rol_actual() = 'admin') with check (public.rol_actual() = 'admin');

-- testimonios ------------------------------------------------------------------
create policy testimonios_admin on public.testimonios for all to authenticated
  using (public.rol_actual() = 'admin') with check (public.rol_actual() = 'admin');
create policy testimonios_paciente_select on public.testimonios for select to authenticated
  using (
    publicado
    and public.rol_actual() = 'paciente'
    and categoria in (select public.categorias_paciente_actual())
  );

-- -----------------------------------------------------------------------------
-- 7. Storage: bucket privado "resultados"
--    Ruta final: {paciente_id}/{resultado_id}.pdf
--    Carga del laboratorio (antes de asociar): cargas/{laboratorio_id}/{resultado_id}.pdf
--    La paciente NO tiene acceso directo: descarga solo con la Edge Function signed-url.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('resultados', 'resultados', false, 10485760, array['application/pdf'])
on conflict (id) do update set public = false;

create policy resultados_storage_lab_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'resultados'
    and public.rol_actual() = 'lab'
    and (storage.foldername(name))[1] = 'cargas'
    and (storage.foldername(name))[2] = public.laboratorio_actual()::text
  );

-- El admin revisa legibilidad y mueve el archivo a {paciente_id}/ al asociar.
create policy resultados_storage_admin_select on storage.objects for select to authenticated
  using (bucket_id = 'resultados' and public.rol_actual() = 'admin');
create policy resultados_storage_admin_update on storage.objects for update to authenticated
  using (bucket_id = 'resultados' and public.rol_actual() = 'admin')
  with check (bucket_id = 'resultados' and public.rol_actual() = 'admin');
