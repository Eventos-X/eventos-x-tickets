-- =====================================================================
-- EVENTOS X · SCRIPT 7: MATCH X — SOLO POR EL LINK DEL MAIL, UNA SESIÓN, CON VENCIMIENTO
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
-- Se puede correr más de una vez sin romper nada.
--
-- - Se entra SOLO con el link personal del mail (se saca el ingreso con DNI + mail).
-- - Una sesión activa a la vez: el último celular que abre el link es el único válido.
-- - El link sirve 12 horas desde el ingreso a la fiesta (match_acceso_horas).
-- - A las 24 horas (match_retencion_horas) el Match de esa persona se reinicia solo: se borran fotos,
--   likes, matches y reportes. Antes de borrar se guarda su scoring en match_estadisticas.
-- - Se quitan los packs pagos (queda solo el límite por hora).
-- =====================================================================

insert into public.app_config (clave, valor) values
  ('match_acceso_horas', '12'),
  ('match_retencion_horas', '24')
on conflict (clave) do update set valor = excluded.valor;
delete from public.app_config where clave = 'match_retencion_dias';
delete from public.app_config where clave in ('pack_cantidad', 'pack_precio', 'pack_instrucciones');

alter table public.entradas add column if not exists sesion_hash text;
alter table public.entradas add column if not exists match_borrado boolean not null default false;

create or replace function public.forzar_campos_match()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.selfie_url := null; new.fotos := '{}'; new.oculto := false;
  new.swipes_extra := 0; new.bio := null; new.sesion_hash := null; new.match_borrado := false;
  return new;
end; $$;

-- ¿El link todavía está vigente para esta entrada?
create or replace function public.match_vigente(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from entradas
     where id = p_id and estado_pago = 'aprobado' and ingresado and not match_borrado
       and fecha_ingreso > now() - make_interval(hours => cfg_int('match_acceso_horas', 12))
  );
$$;

-- ¿La sesión (celular) es la activa?
create or replace function public.match_ok(p_id uuid, p_token text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select match_vigente(p_id) and p_token is not null and exists (
    select 1 from entradas where id = p_id and sesion_hash = encode(digest(p_token, 'sha256'), 'hex'));
$$;

-- 1) Entrar con el link: crea la sesión de ESTE celular (la anterior queda cerrada)
drop function if exists public.validar_acceso_match(text, text);
create or replace function public.iniciar_sesion_match(p_id uuid)
returns table (token text, id uuid, nombre text, instagram text, busca_match boolean, interes_match text,
               selfie_url text, fotos text[], bio text)
language plpgsql security definer set search_path = public, extensions
as $$
declare v_token text := encode(gen_random_bytes(24), 'hex');
begin
  if not match_vigente(p_id) then return; end if;
  update entradas set sesion_hash = encode(digest(v_token, 'sha256'), 'hex') where entradas.id = p_id;
  return query select v_token, e.id, split_part(e.nombre, ' ', 1), e.instagram, e.busca_match, e.interes_match,
                      e.selfie_url, e.fotos, e.bio
                 from entradas e where e.id = p_id;
end; $$;

-- Para retomar sin crear sesión nueva (al recargar la página)
create or replace function public.retomar_sesion_match(p_id uuid, p_token text)
returns table (id uuid, nombre text, instagram text, busca_match boolean, interes_match text,
               selfie_url text, fotos text[], bio text)
language plpgsql security definer set search_path = public
as $$
begin
  if not match_ok(p_id, p_token) then return; end if;
  return query select e.id, split_part(e.nombre, ' ', 1), e.instagram, e.busca_match, e.interes_match,
                      e.selfie_url, e.fotos, e.bio
                 from entradas e where e.id = p_id;
end; $$;

-- 2) Todas las funciones del Match ahora piden la sesión (p_token)
drop function if exists public.estado_swipes(uuid);
create or replace function public.estado_swipes(mi_id uuid, p_token text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_limite int := cfg_int('match_por_hora', 20);
  v_lim_super int := cfg_int('superlikes_por_hora', 1);
  v_usados int; v_supers int; v_reset timestamptz;
begin
  if not match_ok(mi_id, p_token) then return json_build_object('sesion', false); end if;
  select count(*), count(*) filter (where accion = 'superlike'), min(created_at) + interval '1 hour'
    into v_usados, v_supers, v_reset
    from likes where de_ticket_id = mi_id and created_at > now() - interval '1 hour';
  return json_build_object('sesion', true, 'limite', v_limite, 'usados', v_usados,
    'restantes_hora', greatest(v_limite - v_usados, 0), 'extra', 0,
    'superlikes_restantes', greatest(v_lim_super - v_supers, 0), 'reset_en', v_reset);
end; $$;

drop function if exists public.registrar_interaccion(uuid, uuid, text);
create or replace function public.registrar_interaccion(mi_id uuid, objetivo_id uuid, tipo_accion text, p_token text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_limite int := cfg_int('match_por_hora', 20);
  v_lim_super int := cfg_int('superlikes_por_hora', 1);
  v_usados int; v_supers int; v_match boolean := false;
begin
  if not match_ok(mi_id, p_token) then return json_build_object('ok', false, 'motivo', 'sesion'); end if;
  if tipo_accion not in ('like', 'superlike', 'pass') or mi_id = objetivo_id then
    return json_build_object('ok', false, 'motivo', 'invalido');
  end if;
  perform 1 from entradas where id = mi_id and busca_match for update;
  if not found then return json_build_object('ok', false, 'motivo', 'perfil_inactivo'); end if;
  if exists (select 1 from likes where de_ticket_id = mi_id and para_ticket_id = objetivo_id) then
    return json_build_object('ok', false, 'motivo', 'repetido');
  end if;
  select count(*), count(*) filter (where accion = 'superlike') into v_usados, v_supers
    from likes where de_ticket_id = mi_id and created_at > now() - interval '1 hour';
  if tipo_accion = 'superlike' and v_supers >= v_lim_super then
    return json_build_object('ok', false, 'motivo', 'sin_superlikes');
  end if;
  if v_usados >= v_limite then return json_build_object('ok', false, 'motivo', 'limite'); end if;

  insert into likes (de_ticket_id, para_ticket_id, accion) values (mi_id, objetivo_id, tipo_accion);
  v_match := tipo_accion in ('like', 'superlike') and exists (
    select 1 from likes where de_ticket_id = objetivo_id and para_ticket_id = mi_id and accion in ('like', 'superlike'));
  return json_build_object('ok', true, 'match', v_match);
end; $$;

drop function if exists public.deshacer_ultimo(uuid);
create or replace function public.deshacer_ultimo(mi_id uuid, p_token text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_obj uuid; v_id uuid;
begin
  if not match_ok(mi_id, p_token) then return null; end if;
  select l.id, l.para_ticket_id into v_id, v_obj from likes l
   where l.de_ticket_id = mi_id order by l.created_at desc limit 1;
  if v_id is null then return null; end if;
  if not exists (select 1 from likes where id = v_id and accion = 'pass' and created_at > now() - interval '2 minutes') then
    return null;
  end if;
  delete from likes where id = v_id;
  return v_obj;
end; $$;

drop function if exists public.activar_perfil_match(uuid, text, text, text);
create or replace function public.activar_perfil_match(p_ticket_id uuid, p_instagram text, p_interes text, p_bio text, p_token text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_ig text := lower(trim(replace(coalesce(p_instagram, ''), '@', '')));
begin
  if not match_ok(p_ticket_id, p_token) then raise exception 'SESION_CERRADA'; end if;
  if v_ig !~ '^[a-z0-9._]{1,30}$' then raise exception 'Instagram inválido'; end if;
  if p_interes not in ('Mujeres', 'Hombres', 'Ambos') then raise exception 'Interés inválido'; end if;
  if not exists (select 1 from entradas where id = p_ticket_id and selfie_url is not null) then
    raise exception 'Falta la foto principal';
  end if;
  update entradas set instagram = v_ig, busca_match = true, interes_match = p_interes,
                      bio = nullif(left(trim(coalesce(p_bio, '')), 80), '')
   where id = p_ticket_id;
end; $$;

drop function if exists public.quitar_foto(uuid, text);
create or replace function public.quitar_foto(p_ticket_id uuid, p_url text, p_token text)
returns text[]
language plpgsql security definer set search_path = public
as $$
declare v text[];
begin
  if not match_ok(p_ticket_id, p_token) then raise exception 'SESION_CERRADA'; end if;
  update entradas set fotos = array_remove(fotos, p_url) where id = p_ticket_id returning fotos into v;
  return coalesce(v, '{}');
end; $$;

drop function if exists public.obtener_candidatos(uuid);
create or replace function public.obtener_candidatos(mi_id uuid, p_token text)
returns table (id uuid, nombre text, instagram text, me_dio_super boolean, selfie_url text, fotos text[], bio text)
language plpgsql security definer set search_path = public
as $$
declare mi_interes text; mi_genero text;
begin
  if not match_ok(mi_id, p_token) then return; end if;
  select interes_match, genero into mi_interes, mi_genero
    from entradas where entradas.id = mi_id and busca_match;
  if mi_interes is null then return; end if;

  return query
  select e.id, split_part(e.nombre, ' ', 1), e.instagram,
         exists (select 1 from likes l where l.de_ticket_id = e.id and l.para_ticket_id = mi_id and l.accion = 'superlike'),
         e.selfie_url, e.fotos, e.bio
    from entradas e
   where e.ingresado and e.busca_match and not e.oculto and not e.match_borrado and e.id <> mi_id
     and e.selfie_url is not null and coalesce(e.instagram, '') <> ''
     and (mi_interes = 'Ambos'
          or (mi_interes = 'Mujeres' and e.genero = 'Mujer')
          or (mi_interes = 'Hombres' and e.genero = 'Hombre'))
     and (e.interes_match = 'Ambos'
          or (e.interes_match = 'Mujeres' and mi_genero = 'Mujer')
          or (e.interes_match = 'Hombres' and mi_genero = 'Hombre'))
     and not exists (select 1 from likes l where l.de_ticket_id = mi_id and l.para_ticket_id = e.id)
     and not exists (select 1 from reportes r where r.de_ticket = mi_id and r.para_ticket = e.id)
   order by 4 desc, random()
   limit 30;
end; $$;

drop function if exists public.obtener_mis_matches(uuid);
create or replace function public.obtener_mis_matches(mi_id uuid, p_token text)
returns table (id uuid, nombre text, instagram text, es_super boolean, selfie_url text)
language plpgsql security definer set search_path = public
as $$
begin
  if not match_ok(mi_id, p_token) then return; end if;
  return query
  select e.id, split_part(e.nombre, ' ', 1), e.instagram, (dado.accion = 'superlike' or recibido.accion = 'superlike'), e.selfie_url
    from likes dado
    join likes recibido on recibido.de_ticket_id = dado.para_ticket_id and recibido.para_ticket_id = mi_id
    join entradas e on e.id = dado.para_ticket_id
   where dado.de_ticket_id = mi_id and not e.oculto and not e.match_borrado
     and dado.accion in ('like', 'superlike') and recibido.accion in ('like', 'superlike')
   order by greatest(dado.created_at, recibido.created_at) desc;
end; $$;

drop function if exists public.reportar_perfil(uuid, uuid, text);
create or replace function public.reportar_perfil(mi_id uuid, objetivo_id uuid, p_motivo text, p_token text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if mi_id = objetivo_id or not match_ok(mi_id, p_token) then return; end if;
  insert into reportes (de_ticket, para_ticket, motivo) values (mi_id, objetivo_id, left(p_motivo, 200))
  on conflict (de_ticket, para_ticket) do nothing;
  if (select count(*) from reportes where para_ticket = objetivo_id) >= 3 then
    update entradas set oculto = true where id = objetivo_id;
  end if;
end; $$;

-- 3) Sin packs pagos
drop function if exists public.sumar_swipes(text, text, int);

-- 4) SCORING de cada persona en el Match
--    Valoración 0 a 100:
--      70 pts · aceptación = Barros recibidos / veces que la vieron (Barros + pases recibidos)
--      20 pts · matches (5 o más = puntaje completo)
--      10 pts · Súper Barros recibidos (3 o más = puntaje completo)
--     -15 pts por cada reporte recibido
--    Categoría: Estrella (80+), Popular (60+), Activo/a (40+), Tranqui (menos de 40)
create table if not exists public.match_estadisticas (
  id                 bigserial primary key,
  entrada_id         uuid,
  nombre             text,
  dni                text,
  instagram          text,
  tipo_entrada       text,
  fecha_ingreso      timestamptz,
  barros_dados       int, super_dados int, pases_dados int,
  barros_recibidos   int, super_recibidos int, pases_recibidos int,
  matches            int,
  reportes_recibidos int,
  valoracion         int,
  categoria          text,
  guardado_en        timestamptz not null default now()
);
alter table public.match_estadisticas enable row level security;
revoke all on public.match_estadisticas from anon, authenticated;

create or replace function public.calcular_scoring(p_ids uuid[] default null)
returns table (entrada_id uuid, nombre text, dni text, instagram text, tipo_entrada text, fecha_ingreso timestamptz,
               barros_dados int, super_dados int, pases_dados int,
               barros_recibidos int, super_recibidos int, pases_recibidos int,
               matches int, reportes_recibidos int, valoracion int, categoria text)
language sql stable security definer set search_path = public
as $$
  with base as (
    select e.id, e.nombre || ' ' || e.apellido as nombre, e.dni, e.instagram, e.tipo_entrada, e.fecha_ingreso,
      (select count(*) from likes l where l.de_ticket_id = e.id and l.accion = 'like')::int        as bd,
      (select count(*) from likes l where l.de_ticket_id = e.id and l.accion = 'superlike')::int   as sd,
      (select count(*) from likes l where l.de_ticket_id = e.id and l.accion = 'pass')::int        as pd,
      (select count(*) from likes l where l.para_ticket_id = e.id and l.accion = 'like')::int      as br,
      (select count(*) from likes l where l.para_ticket_id = e.id and l.accion = 'superlike')::int as sr,
      (select count(*) from likes l where l.para_ticket_id = e.id and l.accion = 'pass')::int      as pr,
      (select count(*) from likes a join likes b on b.de_ticket_id = a.para_ticket_id and b.para_ticket_id = a.de_ticket_id
        where a.de_ticket_id = e.id and a.accion in ('like','superlike') and b.accion in ('like','superlike'))::int as m,
      (select count(*) from reportes r where r.para_ticket = e.id)::int as rr
    from entradas e
    where (p_ids is null and (e.busca_match or exists (select 1 from likes l where l.de_ticket_id = e.id or l.para_ticket_id = e.id)))
       or e.id = any(p_ids)
  ), puntaje as (
    select b.*, greatest(0, least(100, round(
        70 * case when (b.br + b.sr + b.pr) > 0 then (b.br + b.sr)::numeric / (b.br + b.sr + b.pr) else 0 end
      + 20 * least(b.m / 5.0, 1)
      + 10 * least(b.sr / 3.0, 1)
      - 15 * b.rr)))::int as val
    from base b
  )
  select id, nombre, dni, instagram, tipo_entrada, fecha_ingreso, bd, sd, pd, br, sr, pr, m, rr, val,
         case when val >= 80 then 'Estrella' when val >= 60 then 'Popular' when val >= 40 then 'Activo/a' else 'Tranqui' end
    from puntaje;
$$;

-- Admin: ranking en vivo (los que están en la fiesta ahora) o historial guardado
create or replace function public.get_ranking_match(pin_seguridad text, p_historial boolean default false)
returns table (nombre text, dni text, instagram text, tipo_entrada text, barros_dados int, super_dados int, pases_dados int,
               barros_recibidos int, super_recibidos int, pases_recibidos int, matches int, reportes_recibidos int,
               valoracion int, categoria text, fecha timestamptz)
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  if p_historial then
    return query select m.nombre, m.dni, m.instagram, m.tipo_entrada, m.barros_dados, m.super_dados, m.pases_dados,
                        m.barros_recibidos, m.super_recibidos, m.pases_recibidos, m.matches, m.reportes_recibidos,
                        m.valoracion, m.categoria, m.guardado_en
                   from match_estadisticas m order by m.guardado_en desc, m.valoracion desc limit 2000;
  else
    return query select c.nombre, c.dni, c.instagram, c.tipo_entrada, c.barros_dados, c.super_dados, c.pases_dados,
                        c.barros_recibidos, c.super_recibidos, c.pases_recibidos, c.matches, c.reportes_recibidos,
                        c.valoracion, c.categoria, c.fecha_ingreso
                   from calcular_scoring(null) c order by c.valoracion desc, c.matches desc;
  end if;
end; $$;

-- 5) Reinicio automático: a las 24 hs del ingreso se guarda el scoring y se borra el Match de esa persona
create or replace function public.purgar_match_vencidos()
returns uuid[]
language plpgsql security definer set search_path = public
as $$
declare v_ids uuid[];
begin
  select array_agg(id) into v_ids from entradas
   where not match_borrado and fecha_ingreso is not null
     and fecha_ingreso < now() - make_interval(hours => cfg_int('match_retencion_horas', 24));
  if v_ids is null then return '{}'; end if;

  insert into match_estadisticas (entrada_id, nombre, dni, instagram, tipo_entrada, fecha_ingreso,
         barros_dados, super_dados, pases_dados, barros_recibidos, super_recibidos, pases_recibidos,
         matches, reportes_recibidos, valoracion, categoria)
  select * from calcular_scoring(v_ids) c
   where c.instagram is not null or (c.barros_dados + c.super_dados + c.pases_dados + c.barros_recibidos + c.super_recibidos + c.pases_recibidos) > 0;

  delete from likes where de_ticket_id = any(v_ids) or para_ticket_id = any(v_ids);
  delete from reportes where de_ticket = any(v_ids) or para_ticket = any(v_ids);
  update entradas set selfie_url = null, fotos = '{}', instagram = null, bio = null, busca_match = false,
                      sesion_hash = null, match_borrado = true
   where id = any(v_ids);
  return v_ids;
end; $$;

-- Permisos
revoke all on function public.match_vigente(uuid), public.match_ok(uuid, text), public.purgar_match_vencidos(),
  public.calcular_scoring(uuid[]) from public, anon, authenticated;
grant execute on function public.match_ok(uuid, text), public.purgar_match_vencidos() to service_role;
grant execute on function public.iniciar_sesion_match(uuid), public.retomar_sesion_match(uuid, text),
  public.estado_swipes(uuid, text), public.registrar_interaccion(uuid, uuid, text, text),
  public.deshacer_ultimo(uuid, text), public.activar_perfil_match(uuid, text, text, text, text),
  public.quitar_foto(uuid, text, text), public.obtener_candidatos(uuid, text),
  public.obtener_mis_matches(uuid, text), public.reportar_perfil(uuid, uuid, text, text),
  public.get_ranking_match(text, boolean)
to anon, authenticated;

-- 6) Tarea de reinicio: corre cada hora (a los 15 minutos) y reinicia a quien cumplió 24 hs
do $$ begin perform cron.unschedule('purgar-match'); exception when others then null; end $$;
select cron.schedule('purgar-match', '15 * * * *', $$
  select net.http_post(
    url     := 'https://vogizootbnhvbeugroyr.supabase.co/functions/v1/limpiar-evento',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body    := '{"modo":"vencidos"}'::jsonb,
    timeout_milliseconds := 55000);
$$);

select 'Script 7 aplicado' as resultado;
