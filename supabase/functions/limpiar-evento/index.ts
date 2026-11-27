// =====================================================================
// EVENTOS X · EDGE FUNCTION "limpiar-evento"
// Borra todas las entradas, likes, reportes, mails en cola y fotos del Match.
// La llama el botón "Limpiar evento" del Admin (pide PIN de admin + escribir BORRAR).
// También la llama una tarea diaria para borrar los datos del Match vencidos (modo "vencidos").
// Dónde: Supabase → Edge Functions → Deploy a new function → Via Editor
//        Nombre: limpiar-evento → pegar TODO este código → Deploy
// No necesita secrets nuevos.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// Borra las fotos de algunas entradas (borrado automático de datos vencidos)
async function borrarFotosDe(ids: string[]): Promise<number> {
  const bucket = supabase.storage.from("fotos-match");
  let borradas = 0;
  for (const id of ids) {
    const { data: archivos } = await bucket.list(id, { limit: 100 });
    const rutas = (archivos ?? []).map((a) => `${id}/${a.name}`);
    if (rutas.length) { await bucket.remove(rutas); borradas += rutas.length; }
  }
  return borradas;
}

// Borra todos los archivos del bucket de fotos (carpeta por entrada)
async function borrarFotos(): Promise<number> {
  const bucket = supabase.storage.from("fotos-match");
  let borradas = 0;
  for (let vuelta = 0; vuelta < 50; vuelta++) {
    const { data: carpetas, error } = await bucket.list("", { limit: 100 });
    if (error) throw error;
    if (!carpetas || carpetas.length === 0) break;
    const rutas: string[] = [];
    for (const c of carpetas) {
      if (c.id) { rutas.push(c.name); continue; } // archivo suelto en la raíz
      const { data: archivos } = await bucket.list(c.name, { limit: 100 });
      for (const a of archivos ?? []) rutas.push(`${c.name}/${a.name}`);
    }
    if (rutas.length === 0) break;
    const { error: e2 } = await bucket.remove(rutas);
    if (e2) throw e2;
    borradas += rutas.length;
  }
  return borradas;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  try {
    const cuerpo = await req.json();

    // Modo automático (tarea diaria): borra los datos del Match vencidos. Protegido con CRON_SECRET.
    if (cuerpo.modo === "vencidos") {
      if (req.headers.get("Authorization") !== `Bearer ${Deno.env.get("CRON_SECRET")}`) return json({ error: "No autorizado" }, 401);
      const { data: ids, error } = await supabase.rpc("purgar_match_vencidos");
      if (error) throw error;
      const fotos = await borrarFotosDe((ids ?? []) as string[]);
      return json({ ok: true, perfiles: (ids ?? []).length, fotos });
    }

    const { pin, confirmacion } = cuerpo;
    const { data: entradas, error } = await supabase.rpc("limpiar_evento", { pin_seguridad: pin, p_confirmacion: confirmacion });
    if (error) return json({ error: error.message }, 400);
    const fotos = await borrarFotos();
    return json({ ok: true, entradas, fotos });
  } catch (e) {
    console.error(e);
    return json({ error: "No se pudo completar la limpieza" }, 500);
  }
});
