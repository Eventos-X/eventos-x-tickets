// =====================================================================
// EVENTOS X · EDGE FUNCTION "enviar-mails"  (Gmail, mails profesionales)
// Dónde: Supabase → Edge Functions → enviar-mails → Code → pegar TODO → Deploy
// Settings: "Verify JWT with legacy secret" APAGADO (la protege CRON_SECRET).
//
// Secrets (Supabase → Edge Functions → Secrets):
//   GMAIL_USER, GMAIL_APP_PASSWORD, CRON_SECRET, SITE_URL, LIMITE_DIARIO (opcional, 450)
//
// ⚙️ DATOS DEL EVENTO: se cambian acá abajo (EVENTO) para cada fiesta.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

const EVENTO = {
  nombre: "Eventos X",
  fechaTexto: "Viernes 18 de diciembre",
  hora: "00:00 hs",
  lugar: "Club Ciudad de Buenos Aires",
  direccion: "Av. del Libertador 7501, Núñez, CABA",
  edadMinima: 21,
  contacto: "contacto.x.eventos@gmail.com",
};

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const GMAIL_USER = Deno.env.get("GMAIL_USER")!;
const GMAIL_APP_PASSWORD = (Deno.env.get("GMAIL_APP_PASSWORD") ?? "").replace(/\s/g, "");
const CRON_SECRET = Deno.env.get("CRON_SECRET")!;
const SITE_URL = (Deno.env.get("SITE_URL") ?? "https://eventos-x.github.io/eventos-x-tickets").replace(/\/$/, "");
const LIMITE_DIARIO = Number(Deno.env.get("LIMITE_DIARIO") ?? "450");
const POR_CORRIDA = 25;

const transporte = nodemailer.createTransport({
  host: "smtp.gmail.com", port: 465, secure: true,
  auth: { user: GMAIL_USER, pass: GMAIL_APP_PASSWORD },
});

type Mail = {
  cola_id: number; tipo: "qr" | "match"; destinatario: string;
  entrada_id: string; nombre: string; apellido: string; tipo_entrada: string;
};

const esc = (s: string) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

// ---------- Link a Google Maps (al tocar la dirección) ----------
const destino = encodeURIComponent(`${EVENTO.lugar}, ${EVENTO.direccion}`);
const LINK_MAPS = `https://www.google.com/maps/search/?api=1&query=${destino}`;

// ---------- Bloques de diseño (tablas + estilos en línea: se ven bien en Gmail, Outlook y celular) ----------
const fila = (titulo: string, valor: string) => `
  <tr>
    <td style="padding:12px 0;border-bottom:1px solid #eef0f3;">
      <div style="font-size:11px;color:#6b7280;text-transform:uppercase;letter-spacing:1px;">${titulo}</div>
      <div style="font-size:15px;color:#111827;font-weight:600;margin-top:3px;">${valor}</div>
    </td>
  </tr>`;

const item = (texto: string) => `
  <tr><td valign="top" style="width:16px;padding:0 0 7px;color:#3b82f6;font-weight:700;">•</td>
      <td style="padding:0 0 7px;font-size:14px;color:#1f2937;line-height:1.55;">${texto}</td></tr>`;

function marco(preheader: string, cabecera: string, cuerpo: string) {
  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f3f4f6;font-family:Segoe UI,Helvetica,Arial,sans-serif;">
  <div style="display:none;max-height:0;overflow:hidden;">${preheader}</div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 12px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:16px;overflow:hidden;">
        <tr><td style="background:#0a0a0a;padding:28px 24px;text-align:center;">
          <div style="font-size:24px;font-weight:900;letter-spacing:3px;color:#ffffff;">EVENTOS <span style="color:#3b82f6;">X</span></div>
          <div style="font-size:15px;color:#d1d5db;margin-top:8px;letter-spacing:.3px;">${cabecera}</div>
        </td></tr>
        <tr><td style="padding:28px 26px;">${cuerpo}</td></tr>
        <tr><td style="background:#f9fafb;padding:18px 24px;text-align:center;font-size:12px;color:#6b7280;line-height:1.6;">
          Consultas: <a href="mailto:${EVENTO.contacto}" style="color:#3b82f6;">${EVENTO.contacto}</a><br>
          © ${new Date().getFullYear()} ${EVENTO.nombre}. Todos los derechos reservados.
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;
}

function armarMail(m: Mail) {
  const nombre = esc(m.nombre);
  if (m.tipo === "qr") {
    const qr = `https://api.qrserver.com/v1/create-qr-code/?size=500x500&margin=12&data=${encodeURIComponent(m.entrada_id)}`;
    const cuerpo = `
      <p style="font-size:17px;color:#111827;margin:0 0 8px;font-weight:600;">Hola ${nombre},</p>
      <p style="font-size:15px;color:#374151;margin:0 0 22px;line-height:1.6;">Confirmamos la acreditación de tu pago. A continuación encontrás tu entrada personal para ${EVENTO.nombre}.</p>

      <div style="text-align:center;background:#f9fafb;border:1px solid #e5e7eb;border-radius:14px;padding:22px;margin-bottom:22px;">
        <div style="font-size:11px;color:#6b7280;text-transform:uppercase;letter-spacing:1.5px;margin-bottom:12px;">Entrada</div>
        <img src="${qr}" width="240" height="240" alt="Código QR de tu entrada" style="display:block;margin:0 auto;border:8px solid #ffffff;border-radius:8px;">
        <div style="font-size:18px;font-weight:800;color:#111827;margin-top:14px;">${nombre} ${esc(m.apellido)}</div>
        <div style="display:inline-block;background:#111827;color:#ffffff;font-size:12px;font-weight:700;padding:5px 14px;border-radius:20px;margin-top:8px;">${esc(m.tipo_entrada)}</div>
        <div style="font-size:11px;color:#9ca3af;margin-top:10px;">Código: ${esc(m.entrada_id)}</div>
      </div>

      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;">
        ${fila("Fecha", `${EVENTO.fechaTexto} · ${EVENTO.hora}`)}
        ${fila("Lugar", `${EVENTO.lugar}<br><a href="${LINK_MAPS}" target="_blank" style="font-weight:400;color:#3b82f6;font-size:14px;text-decoration:underline;">${EVENTO.direccion}</a>`)}
      </table>

      <div style="background:#eff6ff;border-radius:12px;padding:16px 18px;">
        <div style="font-size:14px;font-weight:800;color:#1e3a8a;margin-bottom:10px;">Información de ingreso</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
          ${item("Presentá este código QR desde tu celular, con el brillo de la pantalla al máximo.")}
          ${item("Es obligatorio presentar <b>DNI</b> (físico o en Mi Argentina) a nombre del titular.")}
          ${item(`Evento exclusivo para mayores de <b>${EVENTO.edadMinima} años</b>.`)}
          ${item("La entrada es personal e intransferible y habilita <b>un único ingreso</b>.")}
        </table>
      </div>
      <p style="font-size:14px;color:#374151;margin:22px 0 0;line-height:1.6;">Te esperamos.<br><b>Equipo ${EVENTO.nombre}</b></p>`;
    return {
      subject: `🎟️ Tu entrada para ${EVENTO.nombre} · ${EVENTO.fechaTexto}`,
      text: `Hola ${m.nombre}, confirmamos tu entrada para ${EVENTO.nombre}.\n\n` +
        `Fecha: ${EVENTO.fechaTexto} · ${EVENTO.hora}\nLugar: ${EVENTO.lugar}, ${EVENTO.direccion}\nMapa: ${LINK_MAPS}\n\n` +
        `Tu QR: ${qr}\nCódigo: ${m.entrada_id}\n\n` +
        `Presentá el QR desde tu celular junto con tu DNI. Mayores de ${EVENTO.edadMinima} años. Entrada personal, un único ingreso.\n\nEquipo ${EVENTO.nombre}`,
      html: marco(`Tu entrada está confirmada: ${EVENTO.fechaTexto} · ${EVENTO.hora} en ${EVENTO.lugar}`,
        "Tu entrada está confirmada", cuerpo),
    };
  }

  const link = `${SITE_URL}/match.html?id=${encodeURIComponent(m.entrada_id)}`;
  const cuerpo = `
    <p style="font-size:17px;color:#111827;margin:0 0 8px;font-weight:600;">Hola ${nombre},</p>
    <p style="font-size:15px;color:#374151;margin:0 0 24px;line-height:1.6;">Tu ingreso quedó registrado. Activá tu perfil en <b>Match X</b> y ya podés embarrarte.</p>
    <div style="text-align:center;margin-bottom:24px;">
      <a href="${link}" target="_blank" style="display:inline-block;background:#ec4899;color:#ffffff;text-decoration:none;font-weight:800;font-size:15px;letter-spacing:.5px;padding:15px 32px;border-radius:30px;">ENTRAR A MATCH X</a>
    </div>
    <div style="background:#fdf2f8;border-radius:12px;padding:16px 18px;">
      <div style="font-size:14px;font-weight:800;color:#9d174d;margin-bottom:10px;">Cómo funciona</div>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
        ${item("Subí tu foto principal (de la galería o una selfie) y hasta dos fotos adicionales.")}
        ${item("Deslizá a la derecha para dar <b>Barro</b> y a la izquierda para pasar.")}
        ${item("Tenés 20 perfiles y 1 <b>Súper Barro</b> por hora.")}
        ${item("Si el Barro es mutuo, se genera un match y pueden contactarse por Instagram.")}
      </table>
    </div>
    <p style="font-size:12px;color:#6b7280;margin:16px 0 0;line-height:1.6;">Este link es personal y funciona en un solo celular a la vez.</p>
    <p style="font-size:14px;color:#374151;margin:20px 0 0;line-height:1.6;">Que lo disfrutes.<br><b>Equipo ${EVENTO.nombre}</b></p>`;
  return {
    subject: "🔥 Ya estás adentro: entrá a Match X",
    text: `Hola ${m.nombre}, tu ingreso quedó registrado. Activá tu perfil en Match X y ya podés embarrarte: ${link}\n\nEquipo ${EVENTO.nombre}`,
    html: marco("Tu ingreso quedó registrado. Activá tu perfil en Match X.", "Ya estás en la fiesta", cuerpo),
  };
}

async function enviadosUltimas24h(): Promise<number> {
  const desde = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count, error } = await supabase.from("cola_mails").select("id", { count: "exact", head: true })
    .eq("estado", "enviado").gte("enviado_at", desde);
  if (error) throw error;
  return count ?? 0;
}

Deno.serve(async (req) => {
  if (req.headers.get("Authorization") !== `Bearer ${CRON_SECRET}`) {
    return new Response("No autorizado", { status: 401 });
  }
  try {
    const yaEnviados = await enviadosUltimas24h();
    const cupo = Math.min(POR_CORRIDA, LIMITE_DIARIO - yaEnviados);
    if (cupo <= 0) return Response.json({ ok: true, enviados: 0, pausa: "límite diario alcanzado", yaEnviados });

    const { data, error } = await supabase.rpc("tomar_lote_mails", { p_cantidad: cupo });
    if (error) throw error;
    const lote = (data ?? []) as Mail[];

    let enviados = 0;
    const errores: string[] = [];
    for (const m of lote) {
      try {
        await transporte.sendMail({ from: `${EVENTO.nombre} <${GMAIL_USER}>`, replyTo: EVENTO.contacto, to: m.destinatario, ...armarMail(m) });
        await supabase.rpc("marcar_mails", { p_ids: [m.cola_id], p_ok: true });
        enviados++;
      } catch (e) {
        await supabase.rpc("marcar_mails", { p_ids: [m.cola_id], p_ok: false, p_error: String(e) });
        errores.push(String(e));
        if (/auth|login|credentials|535/i.test(String(e))) break;
      }
    }
    return Response.json({ ok: errores.length === 0, enviados, errores: errores.slice(0, 3), yaEnviados });
  } catch (e) {
    console.error(e);
    return Response.json({ ok: false, error: String(e) }, { status: 500 });
  }
});
