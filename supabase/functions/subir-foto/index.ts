// =====================================================================
// EVENTOS X · EDGE FUNCTION "subir-foto"  (fotos del perfil de Match X)
// Dónde: Supabase → Edge Functions → Deploy a new function → Via Editor
//        Nombre: subir-foto → pegar TODO este código → Deploy
// Settings: "Verify JWT with legacy secret" puede quedar ENCENDIDO
// (la página la llama con la anon key, que cumple esa verificación).
// No necesita secrets nuevos.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const TIPOS: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };
const MAX_BYTES = 3 * 1024 * 1024;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  try {
    const form = await req.formData();
    const ticketId = String(form.get("ticket_id") ?? "");
    const tipo = form.get("tipo") === "principal" ? "selfie" : "galeria"; // "selfie" = foto principal en la base
    const archivo = form.get("foto");

    if (!/^[0-9a-f-]{36}$/i.test(ticketId)) return json({ error: "Entrada inválida" }, 400);
    // Solo la sesión activa (el último celular que abrió el link del mail) puede subir fotos
    const { data: sesionOk } = await supabase.rpc("match_ok", { p_id: ticketId, p_token: String(form.get("token") ?? "") });
    if (!sesionOk) return json({ error: "Tu sesión se cerró: abrí de nuevo el link del mail" }, 403);
    if (!(archivo instanceof File)) return json({ error: "Falta la foto" }, 400);
    const ext = TIPOS[archivo.type];
    if (!ext) return json({ error: "Formato no permitido (JPG, PNG o WEBP)" }, 400);
    if (archivo.size > MAX_BYTES) return json({ error: "La foto pesa más de 3 MB" }, 400);

    // Solo entradas aprobadas que ya entraron a la fiesta
    const { data: e } = await supabase.from("entradas")
      .select("id, fotos").eq("id", ticketId).eq("estado_pago", "aprobado").eq("ingresado", true).maybeSingle();
    if (!e) return json({ error: "Entrada no habilitada" }, 403);
    if (tipo === "galeria" && (e.fotos?.length ?? 0) >= 2) return json({ error: "Máximo 2 fotos adicionales" }, 400);

    const ruta = `${ticketId}/${tipo}-${Date.now()}.${ext}`;
    const { error: errSubida } = await supabase.storage.from("fotos-match")
      .upload(ruta, await archivo.arrayBuffer(), { contentType: archivo.type, upsert: false });
    if (errSubida) throw errSubida;
    const url = supabase.storage.from("fotos-match").getPublicUrl(ruta).data.publicUrl;

    const { data: fotos, error } = await supabase.rpc("guardar_foto", { p_ticket_id: ticketId, p_tipo: tipo, p_url: url });
    if (error) throw error;
    return json({ ok: true, url, fotos });
  } catch (err) {
    console.error(err);
    return json({ error: "No se pudo subir la foto" }, 500);
  }
});
