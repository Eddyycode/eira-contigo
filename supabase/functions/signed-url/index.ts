// Edge Function: signed-url
//
// Devuelve una URL firmada de 300 s para ver o descargar el PDF de un resultado.
// 1. Autentica al usuario con su JWT.
// 2. Valida su rol y el estado del resultado.
// 3. Firma la URL con el service_role (el bucket "resultados" es privado).
// 4. Registra la acción (o el intento denegado) en la bitácora.
//
// POST /functions/v1/signed-url
// Authorization: Bearer <access_token del usuario>
// Body: { "resultado_id": "<uuid>", "accion": "ver" | "descargar" }

import { createClient } from "jsr:@supabase/supabase-js@2";

const EXPIRA_SEGUNDOS = 300;

const ESTADOS_PACIENTE = ["autorizado", "notificado", "consultado", "cerrado"];
const ESTADOS_MEDICO = [
  "revisado",
  "autorizado",
  "rechazado_clinico",
  "notificado",
  "consultado",
  "seguimiento_pendiente",
  "cerrado",
  "entregado_asistido",
];

type Rol = "lab" | "admin" | "medico" | "paciente";
type Accion = "ver" | "descargar";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return json({ error: "No autenticado" }, 401);

  let resultadoId: string;
  let accion: Accion;
  try {
    const body = await req.json();
    resultadoId = String(body?.resultado_id ?? "");
    accion = body?.accion === "descargar" ? "descargar" : "ver";
  } catch {
    return json({ error: "Cuerpo inválido" }, 400);
  }
  if (!UUID_RE.test(resultadoId)) return json({ error: "resultado_id inválido" }, 400);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(supabaseUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 1. Usuario autenticado
  const token = authHeader.slice("Bearer ".length);
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData?.user) return json({ error: "Sesión inválida" }, 401);
  const userId = userData.user.id;

  const { data: profile } = await admin
    .from("profiles")
    .select("rol, laboratorio_id")
    .eq("id", userId)
    .maybeSingle();
  if (!profile) return json({ error: "Sin perfil" }, 403);
  const rol = profile.rol as Rol;

  const registrar = (accionBitacora: string, detalle: Record<string, unknown>) =>
    admin.from("bitacora").insert({
      actor_id: userId,
      rol,
      accion: accionBitacora,
      entidad: "resultado",
      entidad_id: resultadoId,
      detalle: {
        ...detalle,
        ip: req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null,
        user_agent: req.headers.get("user-agent"),
      },
    });

  const denegar = async (motivo: string) => {
    await registrar("acceso_denegado", { motivo, accion_solicitada: accion });
    // Mismo mensaje para "no existe" y "no es tuyo": no revela si el resultado existe.
    return json({ error: "No disponible" }, 404);
  };

  // 2. Resultado
  const { data: resultado } = await admin
    .from("resultados")
    .select("id, paciente_id, laboratorio_id, estado, archivo_path")
    .eq("id", resultadoId)
    .maybeSingle();
  if (!resultado) return denegar("no_existe");

  // 3. Validación de rol y estado
  switch (rol) {
    case "paciente": {
      const { data: paciente } = await admin
        .from("pacientes")
        .select("id")
        .eq("user_id", userId)
        .maybeSingle();
      if (!paciente || paciente.id !== resultado.paciente_id) return denegar("no_es_su_resultado");
      if (!ESTADOS_PACIENTE.includes(resultado.estado)) return denegar(`estado_${resultado.estado}`);
      break;
    }
    case "medico":
      if (!ESTADOS_MEDICO.includes(resultado.estado)) return denegar(`estado_${resultado.estado}`);
      break;
    case "admin":
      break; // revisión administrativa: legibilidad y documento correcto
    default:
      return denegar("rol_sin_acceso"); // el laboratorio solo ve el estado de sus cargas
  }

  // 4. URL firmada de 300 s
  const { data: firmada, error: firmaError } = await admin.storage
    .from("resultados")
    .createSignedUrl(resultado.archivo_path, EXPIRA_SEGUNDOS, {
      download: accion === "descargar" ? `resultado-${resultado.id}.pdf` : false,
    });
  if (firmaError || !firmada?.signedUrl) {
    console.error("createSignedUrl", firmaError);
    return json({ error: "No se pudo generar el enlace" }, 500);
  }

  // 5. Bitácora (si no se puede registrar, no se entrega la URL)
  const { error: bitacoraError } = await registrar(accion, {
    expira_en_segundos: EXPIRA_SEGUNDOS,
    estado: resultado.estado,
  });
  if (bitacoraError) {
    console.error("bitacora", bitacoraError);
    return json({ error: "No se pudo registrar el acceso" }, 500);
  }

  // Primera consulta de la paciente: autorizado/notificado -> consultado
  if (rol === "paciente" && (resultado.estado === "autorizado" || resultado.estado === "notificado")) {
    await admin
      .from("resultados")
      .update({ estado: "consultado" })
      .eq("id", resultado.id)
      .eq("estado", resultado.estado);
  }

  return json({
    url: firmada.signedUrl,
    expira_en: EXPIRA_SEGUNDOS,
    expira_at: new Date(Date.now() + EXPIRA_SEGUNDOS * 1000).toISOString(),
  });
});
