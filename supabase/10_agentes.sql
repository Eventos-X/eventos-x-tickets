-- =====================================================================
-- EVENTOS X · SCRIPT 10: AGENTES AUTOMÁTICOS
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
--
--  1) agente_pendientes  (cada hora)
--     · Reserva pendiente hace +24 h  → mail al comprador pidiendo el pago (una sola vez).
--     · Reserva pendiente hace +36 h  → se borra y libera el cupo.
--     · Aviso a contacto con la lista de recordatorios y bajas.
--  2) agente_gmail       (cada 5 min)
--     · Si los mails de las últimas 24 h + la cola llegan al 80% / 100% del límite diario → aviso.
--  3) agente_moderador   (cada 5 min)
--     · 3 reportes o un reporte por motivo grave → BANEO (oculto + sin acceso a Match X) y aviso.
--     · El admin puede restaurar desde la solapa Match X (botón "Restaurar").
--
-- Los avisos llegan por mail a contacto.x.eventos@gmail.com (la Edge Function "enviar-mails" los manda).
-- =====================================================================

-- ---------- Configuración ----------
insert into app_config (clave, valor) values
  ('agente_mail_avisos', 'contacto.x.eventos@gmail.com'),
  ('agente_horas_recordatorio', '24'),
  ('agente_horas_baja', '36'),
  ('agente_limite_mails', '450'),
  ('agente_reportes_baneo', '3')
on conflict (clave) do nothing;

-- ---------- Cola de mails: nuevos tipos (recordatorio al comprador y alerta al organizador) ----------
alter table public.cola_mails alter column entrada_id drop not null;
alter table public.cola_mails add column if not exists asunto text;
alter table public.cola_mails add column if not exists cuerpo text;
alter table public.cola_mails drop constraint if exists cola_mails_tipo_check;
alter table public.cola_mails add constraint cola_mails_tipo_check check (tipo in ('qr', 'match', 'recordatorio', 'alerta'));

drop function if exists public.tomar_lote_mails(int);
create or replace function public.tomar_lote_mails(p_cantidad int default 100)
returns table (cola_id bigint, tipo text, destinatario text, entrada_id uuid, nombre text, apellido text,
               tipo_entrada text, asunto text, cuerpo text)
language plpgsql security definer set search_path = public
as $$
begin
  update cola_mails set estado = 'pendiente'
   where estado = 'enviando' and created_at < now() - interval '10 minutes' and intentos < 3;
  return query
  with lote as (
    select c.id from cola_mails c
     where c.estado = 'pendiente'
     order by (c.tipo = 'alerta') desc, c.created_at   -- los avisos al organizador salen primero
     limit p_cantidad
     for update skip locked
  )
  update cola_mails c
     set estado = 'enviando', intentos = c.intentos + 1
    from lote
   where c.id = lote.id
  returning c.id, c.tipo, c.destinatario, c.entrada_id,
            (select e.nombre from entradas e where e.id = c.entrada_id),
            (select e.apellido from entradas e where e.id = c.entrada_id),
            (select e.tipo_entrada from entradas e where e.id = c.entrada_id),
            c.asunto, c.cuerpo;
end; $$;
revoke all on function public.tomar_lote_mails(int) from public, anon, authenticated;
grant execute on function public.tomar_lote_mails(int) to service_role;

-- Encolar un aviso para el organizador
create or replace function public.encolar_alerta(p_asunto text, p_cuerpo text)
returns void language sql security definer set search_path = public as $$
  insert into cola_mails (entrada_id, tipo, destinatario, asunto, cuerpo)
  select null, 'alerta', (select valor from app_config where clave = 'agente_mail_avisos'), p_asunto, p_cuerpo;
$$;
revoke all on function public.encolar_alerta(text, text) from public, anon, authenticated;

-- ---------- Baneo en Match X ----------
alter table public.entradas add column if not exists baneado boolean not null default false;

create or replace function public.match_vigente(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from entradas
     where id = p_id and estado_pago = 'aprobado' and ingresado and not match_borrado and not baneado
       and fecha_ingreso > now() - make_interval(hours => cfg_int('match_acceso_horas', 12))
  );
$$;

-- Restaurar desde el Admin también quita el baneo
create or replace function public.moderar_perfil(p_ticket_id uuid, p_ocultar boolean, pin_seguridad text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  update entradas set oculto = p_ocultar, baneado = p_ocultar where id = p_ticket_id;
  if not p_ocultar then delete from reportes where para_ticket = p_ticket_id; end if;
end; $$;

-- ---------- Registro de lo que hacen los agentes ----------
create table if not exists public.agente_log (
  id bigserial primary key,
  agente text not null,
  detalle text,
  created_at timestamptz not null default now()
);
alter table public.agente_log enable row level security;
revoke all on public.agente_log from anon, authenticated;

-- =====================================================================
-- AGENTE 1: RESERVAS PENDIENTES
-- =====================================================================
create or replace function public.agente_pendientes()
returns text language plpgsql security definer set search_path = public
as $$
declare
  h_rec int := cfg_int('agente_horas_recordatorio', 24);
  h_baja int := cfg_int('agente_horas_baja', 36);
  r record; recordados text := ''; bajas text := ''; n_rec int := 0; n_baja int := 0; total int;
begin
  -- Bajas: pendientes hace más de 36 h
  for r in select id, nombre, apellido, dni, tipo_entrada, created_at from entradas
            where estado_pago = 'pendiente' and created_at < now() - make_interval(hours => h_baja)
  loop
    delete from entradas where id = r.id;
    n_baja := n_baja + 1;
    bajas := bajas || format(E'• %s %s (DNI %s) – %s – reservó el %s\n', r.nombre, r.apellido, r.dni, r.tipo_entrada,
                              to_char(r.created_at at time zone 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI'));
  end loop;

  -- Recordatorios: pendientes hace más de 24 h que todavía no lo recibieron
  for r in select e.id, e.nombre, e.apellido, e.dni, e.tipo_entrada, e.created_at from entradas e
            where e.estado_pago = 'pendiente' and e.created_at < now() - make_interval(hours => h_rec)
              and not exists (select 1 from cola_mails c where c.entrada_id = e.id and c.tipo = 'recordatorio')
  loop
    perform encolar_mail(r.id, 'recordatorio');
    n_rec := n_rec + 1;
    recordados := recordados || format(E'• %s %s (DNI %s) – %s – se libera el %s\n', r.nombre, r.apellido, r.dni, r.tipo_entrada,
                    to_char((r.created_at + make_interval(hours => h_baja)) at time zone 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI'));
  end loop;

  if n_rec + n_baja > 0 then
    select count(*) into total from entradas where estado_pago = 'pendiente';
    perform encolar_alerta(
      format('Reservas pendientes: %s recordatorio(s), %s cupo(s) liberado(s)', n_rec, n_baja),
      format(E'Hay %s reserva(s) pendiente(s) de aprobación en total.\n\n', total) ||
      case when n_rec > 0 then format(E'Se envió recordatorio de pago a (sin aprobar hace +%s h):\n%s\nSi alguna de estas personas YA PAGÓ, aprobala desde el Admin antes del horario indicado para que no se libere su cupo.\n\n', h_rec, recordados) else '' end ||
      case when n_baja > 0 then format(E'Se liberaron estos cupos (sin pago hace +%s h):\n%s\n', h_baja, bajas) else '' end);
    insert into agente_log (agente, detalle) values ('pendientes', format('recordatorios=%s bajas=%s', n_rec, n_baja));
  end if;
  return format('recordatorios=%s bajas=%s', n_rec, n_baja);
end; $$;

-- encolar_mail ahora acepta el tipo 'recordatorio'
create or replace function public.encolar_mail(p_entrada_id uuid, p_tipo text, p_reenviar boolean default false)
returns void language plpgsql security definer set search_path = public
as $$
begin
  insert into cola_mails (entrada_id, tipo, destinatario)
  select id, p_tipo, lower(trim(email)) from entradas where id = p_entrada_id and email is not null
  on conflict (entrada_id, tipo) do update
    set estado = 'pendiente', intentos = 0, ultimo_error = null
    where p_reenviar;
end; $$;
revoke all on function public.encolar_mail(uuid, text, boolean) from public, anon, authenticated;

-- =====================================================================
-- AGENTE 2: CUPO DIARIO DE GMAIL
-- =====================================================================
create or replace function public.agente_gmail()
returns text language plpgsql security definer set search_path = public
as $$
declare
  limite int := cfg_int('agente_limite_mails', 450);
  enviados int; en_cola int; uso int; nivel int; ultimo int;
begin
  select count(*) filter (where estado = 'enviado' and enviado_at > now() - interval '24 hours'),
         count(*) filter (where estado in ('pendiente', 'enviando'))
    into enviados, en_cola from cola_mails;
  uso := round(100.0 * (enviados + en_cola) / limite);
  nivel := case when uso >= 100 then 100 when uso >= 80 then 80 else 0 end;
  ultimo := coalesce((select max(split_part(split_part(detalle, ' ', 1), '=', 2)::int) from agente_log
                       where agente = 'gmail' and created_at > now() - interval '3 hours'), 0);
  if nivel > ultimo then
    perform encolar_alerta(
      case when nivel = 100 then 'URGENTE: se alcanzó el límite diario de mails'
           else 'Atención: mails al 80% del límite diario' end,
      format(E'Enviados en las últimas 24 h: %s\nEn cola esperando: %s\nLímite diario de Gmail: %s (%s%% usado)\n\n', enviados, en_cola, limite, uso) ||
      case when nivel = 100
        then E'Los mails que superen el límite (QR o Match X) quedan en cola y salen recién cuando se libere cupo.\nOpciones: reducir aprobaciones por ahora, o sumar un segundo remitente.'
        else E'Si siguen entrando mails a este ritmo, se va a alcanzar el límite pronto.' end);
    insert into agente_log (agente, detalle) values ('gmail', format('nivel=%s enviados=%s cola=%s', nivel, enviados, en_cola));
  end if;
  return format('uso=%s%% nivel=%s', uso, nivel);
end; $$;

-- =====================================================================
-- AGENTE 3: MODERADOR DE MATCH X
-- =====================================================================
create or replace function public.agente_moderador()
returns text language plpgsql security definer set search_path = public
as $$
declare
  umbral int := cfg_int('agente_reportes_baneo', 3);
  graves text := '(menor|nene|nena|acos|amenaz|violen|golpe|pegó|pego|drog|robo|rob[oó]|desnud|porno|sexual|abus|extors|estaf|arma|odio|racis|nazi)';
  r record; n int := 0;
begin
  for r in
    select e.id, e.nombre, e.apellido, e.dni, e.instagram, count(rp.id) as cant,
           string_agg(coalesce(nullif(trim(rp.motivo), ''), '(sin motivo)'), ' · ') as motivos,
           bool_or(lower(coalesce(rp.motivo, '')) ~ graves) as grave
      from entradas e join reportes rp on rp.para_ticket = e.id
     where not e.baneado
     group by e.id
  loop
    if r.cant >= umbral or r.grave then
      update entradas set baneado = true, oculto = true, sesion_hash = null where id = r.id;
      n := n + 1;
      perform encolar_alerta(
        case when r.grave then format('URGENTE Match X: baneado @%s por reporte grave', r.instagram)
             else format('Match X: baneado @%s (%s reportes)', r.instagram, r.cant) end,
        format(E'Persona: %s %s (DNI %s) · Instagram @%s\nReportes recibidos: %s\nMotivos: %s\n\n',
               r.nombre, r.apellido, r.dni, r.instagram, r.cant, r.motivos) ||
        case when r.grave then E'El motivo indica una posible situación grave: conviene avisar a seguridad del evento.\n\n' else '' end ||
        E'Se ocultó su perfil y se le quitó el acceso a Match X. Si fue un error, restauralo desde el Admin → solapa Match X → Restaurar.');
      insert into agente_log (agente, detalle) values ('moderador', format('baneo %s grave=%s reportes=%s', r.id, r.grave, r.cant));
    end if;
  end loop;
  return format('baneados=%s', n);
end; $$;

revoke all on function public.agente_pendientes() from public, anon, authenticated;
revoke all on function public.agente_gmail() from public, anon, authenticated;
revoke all on function public.agente_moderador() from public, anon, authenticated;

-- ---------- Programación (pg_cron) ----------
select cron.unschedule(jobname) from cron.job where jobname in ('agente-pendientes', 'agente-gmail', 'agente-moderador');
select cron.schedule('agente-pendientes', '7 * * * *',   $$select public.agente_pendientes()$$);
select cron.schedule('agente-gmail',      '*/5 * * * *', $$select public.agente_gmail()$$);
select cron.schedule('agente-moderador',  '*/5 * * * *', $$select public.agente_moderador()$$);

select 'Script 10 aplicado' as resultado;
