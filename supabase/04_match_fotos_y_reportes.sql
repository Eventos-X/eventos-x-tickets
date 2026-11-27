-- =====================================================================
-- EVENTOS X · SCRIPT 4: MATCH X CON FOTOS Y REPORTES
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
-- Se puede correr más de una vez sin romper nada.
--
-- - Foto principal obligatoria (de la galería o una selfie, a elección).
-- - Hasta 2 fotos adicionales.
-- - Botón "Reportar": con 3 reportes el perfil se oculta solo y aparece en el admin.
-- Las fotos las sube la Edge Function "subir-foto" (nadie puede subir directo).
-- =====================================================================

-- 1) Columnas nuevas (selfie_url = foto principal del perfil)
alter table public.entradas add column if not exists selfie_url text;
alter table public.entradas add column if not exists fotos      text[] not null default '{}';
alter table public.entradas add column if not exists oculto     boolean not null default false;

-- Las reservas nuevas nunca vienen con fotos ni ocultas desde la web
create or replace function public.forzar_campos_match()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.selfie_url := null; new.fotos := '{}'; new.oculto := false;
  return new;
end; $$;
drop trigger if exists trg_forzar_campos_match on public.entradas;
create trigger trg_forzar_campos_match before insert on public.entradas
  for each row execute function public.forzar_campos_match();

-- 2) Lugar para las fotos (se ven públicamente, solo el servidor puede subir)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-match', 'fotos-match', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 3145728,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- 3) Reportes
create table if not exists public.reportes (
  id          bigserial primary key,
  de_ticket   uuid not null references public.entradas(id) on delete cascade,
  para_ticket uuid not null references public.entradas(id) on delete cascade,
  motivo      text,
  created_at  timestamptz not null default now(),
  unique (de_ticket, para_ticket)
);
alter table public.reportes enable row level security;
revoke all on public.reportes from anon, authenticated;

-- 4) Guardar / quitar fotos (guardar_foto la usa SOLO la Edge Function)
create or replace function public.guardar_foto(p_ticket_id uuid, p_tipo text, p_url text)
returns text[]
language plpgsql security definer set search_path = public
as $$
declare v text[];
begin
  if p_tipo = 'selfie' then
    update entradas set selfie_url = p_url where id = p_ticket_id returning fotos into v;
  else
    select fotos into v from entradas where id = p_ticket_id;
    if coalesce(array_length(v, 1), 0) >= 2 then raise exception 'Máximo 2 fotos adicionales'; end if;
    update entradas set fotos = array_append(fotos, p_url) where id = p_ticket_id returning fotos into v;
  end if;
  return v;
end; $$;
revoke all on function public.guardar_foto(uuid, text, text) from public, anon, authenticated;
grant execute on function public.guardar_foto(uuid, text, text) to service_role;

-- La propia persona puede sacar una foto de su galería
create or replace function public.quitar_foto(p_ticket_id uuid, p_url text)
returns text[]
language plpgsql security definer set search_path = public
as $$
declare v text[];
begin
  update entradas set fotos = array_remove(fotos, p_url)
   where id = p_ticket_id and estado_pago = 'aprobado' and ingresado
  returning fotos into v;
  return coalesce(v, '{}');
end; $$;

-- 5) Activar perfil: ahora exige la foto principal
drop function if exists public.activar_perfil_match(uuid, text, text, text);
create or replace function public.activar_perfil_match(p_ticket_id uuid, p_instagram text, p_interes text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_ig text := lower(trim(replace(coalesce(p_instagram, ''), '@', '')));
begin
  if v_ig !~ '^[a-z0-9._]{1,30}$' then raise exception 'Instagram inválido'; end if;
  if p_interes not in ('Mujeres', 'Hombres', 'Ambos') then raise exception 'Interés inválido'; end if;
  if not exists (select 1 from entradas where id = p_ticket_id and selfie_url is not null) then
    raise exception 'Falta la foto principal';
  end if;
  update entradas set instagram = v_ig, busca_match = true, interes_match = p_interes
   where id = p_ticket_id and estado_pago = 'aprobado' and ingresado;
  if not found then raise exception 'Entrada no habilitada'; end if;
end; $$;

-- 6) Login del Match devuelve también las fotos
drop function if exists public.validar_acceso_match(text, text);
create or replace function public.validar_acceso_match(identificador text, p_email text default null)
returns table (id uuid, nombre text, instagram text, busca_match boolean, interes_match text,
               selfie_url text, fotos text[])
language plpgsql security definer set search_path = public
as $$
declare v text := trim(coalesce(identificador, ''));
begin
  if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return query select e.id, e.nombre, e.instagram, e.busca_match, e.interes_match, e.selfie_url, e.fotos
                   from entradas e where e.id = v::uuid and e.estado_pago = 'aprobado' and e.ingresado;
  elsif v ~ '^\d{8}$' and p_email is not null then
    return query select e.id, e.nombre, e.instagram, e.busca_match, e.interes_match, e.selfie_url, e.fotos
                   from entradas e
                  where e.dni = v and e.email = lower(trim(p_email)) and e.estado_pago = 'aprobado' and e.ingresado;
  end if;
end; $$;

-- 7) Candidatos: con fotos, sin ocultos y sin los que ya reporté
drop function if exists public.obtener_candidatos(uuid);
create or replace function public.obtener_candidatos(mi_id uuid)
returns table (id uuid, nombre text, instagram text, me_dio_super boolean, selfie_url text, fotos text[])
language plpgsql security definer set search_path = public
as $$
declare mi_interes text; mi_tipo text;
begin
  select interes_match, tipo_entrada into mi_interes, mi_tipo
    from entradas where entradas.id = mi_id and ingresado and busca_match;
  if mi_interes is null then return; end if;

  return query
  select e.id, e.nombre, e.instagram,
         exists (select 1 from likes l where l.de_ticket_id = e.id and l.para_ticket_id = mi_id and l.accion = 'superlike'),
         e.selfie_url, e.fotos
    from entradas e
   where e.ingresado and e.busca_match and not e.oculto and e.id <> mi_id
     and e.selfie_url is not null and coalesce(e.instagram, '') <> ''
     and (mi_interes = 'Ambos'
          or (mi_interes = 'Mujeres' and e.tipo_entrada ilike '%Mujer%')
          or (mi_interes = 'Hombres' and e.tipo_entrada ilike '%Hombre%'))
     and (e.interes_match = 'Ambos'
          or (e.interes_match = 'Mujeres' and mi_tipo ilike '%Mujer%')
          or (e.interes_match = 'Hombres' and mi_tipo ilike '%Hombre%'))
     and not exists (select 1 from likes l where l.de_ticket_id = mi_id and l.para_ticket_id = e.id)
     and not exists (select 1 from reportes r where r.de_ticket = mi_id and r.para_ticket = e.id)
   order by 4 desc, random()
   limit 50;
end; $$;

drop function if exists public.obtener_mis_matches(uuid);
create or replace function public.obtener_mis_matches(mi_id uuid)
returns table (id uuid, nombre text, instagram text, es_super boolean, selfie_url text)
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from entradas where entradas.id = mi_id and ingresado) then return; end if;
  return query
  select e.id, e.nombre, e.instagram, (dado.accion = 'superlike' or recibido.accion = 'superlike'), e.selfie_url
    from likes dado
    join likes recibido on recibido.de_ticket_id = dado.para_ticket_id and recibido.para_ticket_id = mi_id
    join entradas e on e.id = dado.para_ticket_id
   where dado.de_ticket_id = mi_id and not e.oculto
     and dado.accion in ('like', 'superlike') and recibido.accion in ('like', 'superlike')
   order by greatest(dado.created_at, recibido.created_at) desc;
end; $$;

-- 8) Reportar: con 3 reportes distintos el perfil se oculta solo
create or replace function public.reportar_perfil(mi_id uuid, objetivo_id uuid, p_motivo text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if mi_id = objetivo_id then return; end if;
  if not exists (select 1 from entradas where id = mi_id and ingresado and busca_match) then return; end if;
  insert into reportes (de_ticket, para_ticket, motivo) values (mi_id, objetivo_id, left(p_motivo, 200))
  on conflict (de_ticket, para_ticket) do nothing;
  if (select count(*) from reportes where para_ticket = objetivo_id) >= 3 then
    update entradas set oculto = true where id = objetivo_id;
  end if;
end; $$;

-- 9) Admin: ver perfiles reportados y ocultarlos / restaurarlos
create or replace function public.get_reportados(pin_seguridad text)
returns table (id uuid, nombre text, apellido text, instagram text, selfie_url text, oculto boolean, num_reportes bigint, motivos text)
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  return query
  select e.id, e.nombre, e.apellido, e.instagram, e.selfie_url, e.oculto, count(r.id),
         string_agg(distinct coalesce(r.motivo, ''), ' · ')
    from entradas e join reportes r on r.para_ticket = e.id
   group by e.id
   order by e.oculto desc, count(r.id) desc;
end; $$;

create or replace function public.moderar_perfil(p_ticket_id uuid, p_ocultar boolean, pin_seguridad text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  update entradas set oculto = p_ocultar where id = p_ticket_id;
  if not p_ocultar then delete from reportes where para_ticket = p_ticket_id; end if;
end; $$;

grant execute on function public.quitar_foto(uuid, text), public.activar_perfil_match(uuid, text, text),
  public.validar_acceso_match(text, text), public.obtener_candidatos(uuid), public.obtener_mis_matches(uuid),
  public.reportar_perfil(uuid, uuid, text), public.get_reportados(text), public.moderar_perfil(uuid, boolean, text)
to anon, authenticated;
