-- =====================================================================
-- EVENTOS X · SCRIPT 6: MATCH X — LÍMITE POR HORA, PACKS EXTRA, DESHACER Y FRASE
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
-- Se puede correr más de una vez sin romper nada.
--
-- - Cada persona puede evaluar (like, súper like o pasar) hasta 20 perfiles por hora.
-- - 1 súper like por hora.
-- - Packs de 10 evaluaciones extra: por ahora los carga el Admin (después se conecta el pago).
-- - Deshacer el último "pasar" (si fue hace menos de 2 minutos).
-- - Frase corta en el perfil (opcional).
-- Los números se cambian en la tabla app_config.
-- =====================================================================

-- 1) Configuración (editable en Supabase → Table Editor → app_config)
insert into public.app_config (clave, valor) values
  ('match_por_hora', '20'),
  ('superlikes_por_hora', '1'),
  ('pack_cantidad', '10'),
  ('pack_precio', '2000'),
  ('pack_instrucciones', 'Pedí tu pack en la barra mostrando tu DNI.')
on conflict (clave) do nothing;

alter table public.entradas add column if not exists swipes_extra integer not null default 0;
alter table public.entradas add column if not exists bio text;
create index if not exists likes_de_fecha_idx on public.likes (de_ticket_id, created_at);

-- Las reservas nuevas no pueden venir con extras ni frase
create or replace function public.forzar_campos_match()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.selfie_url := null; new.fotos := '{}'; new.oculto := false;
  new.swipes_extra := 0; new.bio := null;
  return new;
end; $$;

create or replace function public.cfg_int(p_clave text, p_defecto int)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select valor::int from app_config where clave = p_clave), p_defecto);
$$;

-- 2) Estado de las evaluaciones de una persona
create or replace function public.estado_swipes(mi_id uuid)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_limite int := cfg_int('match_por_hora', 20);
  v_lim_super int := cfg_int('superlikes_por_hora', 1);
  v_usados int; v_supers int; v_extra int; v_reset timestamptz;
begin
  select swipes_extra into v_extra from entradas where id = mi_id and ingresado;
  if v_extra is null then return null; end if;
  select count(*), count(*) filter (where accion = 'superlike'), min(created_at) + interval '1 hour'
    into v_usados, v_supers, v_reset
    from likes where de_ticket_id = mi_id and created_at > now() - interval '1 hour';
  return json_build_object(
    'limite', v_limite,
    'usados', v_usados,
    'restantes_hora', greatest(v_limite - v_usados, 0),
    'extra', v_extra,
    'superlikes_restantes', greatest(v_lim_super - v_supers, 0),
    'reset_en', v_reset,
    'pack_cantidad', cfg_int('pack_cantidad', 10),
    'pack_precio', cfg_int('pack_precio', 0),
    'pack_instrucciones', (select valor from app_config where clave = 'pack_instrucciones')
  );
end; $$;

-- 3) Registrar like / súper like / pasar, respetando los límites
drop function if exists public.registrar_interaccion(uuid, uuid, text);
create or replace function public.registrar_interaccion(mi_id uuid, objetivo_id uuid, tipo_accion text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_limite int := cfg_int('match_por_hora', 20);
  v_lim_super int := cfg_int('superlikes_por_hora', 1);
  v_usados int; v_supers int; v_extra int; v_match boolean := false;
begin
  if tipo_accion not in ('like', 'superlike', 'pass') or mi_id = objetivo_id then
    return json_build_object('ok', false, 'motivo', 'invalido');
  end if;
  select swipes_extra into v_extra from entradas where id = mi_id and ingresado and busca_match for update;
  if v_extra is null then return json_build_object('ok', false, 'motivo', 'perfil_inactivo'); end if;
  if exists (select 1 from likes where de_ticket_id = mi_id and para_ticket_id = objetivo_id) then
    return json_build_object('ok', false, 'motivo', 'repetido');
  end if;

  select count(*), count(*) filter (where accion = 'superlike') into v_usados, v_supers
    from likes where de_ticket_id = mi_id and created_at > now() - interval '1 hour';

  if tipo_accion = 'superlike' and v_supers >= v_lim_super then
    return json_build_object('ok', false, 'motivo', 'sin_superlikes');
  end if;

  if v_usados >= v_limite then
    if v_extra > 0 then
      update entradas set swipes_extra = swipes_extra - 1 where id = mi_id;
    else
      return json_build_object('ok', false, 'motivo', 'limite');
    end if;
  end if;

  insert into likes (de_ticket_id, para_ticket_id, accion) values (mi_id, objetivo_id, tipo_accion);

  v_match := tipo_accion in ('like', 'superlike') and exists (
    select 1 from likes where de_ticket_id = objetivo_id and para_ticket_id = mi_id and accion in ('like', 'superlike'));

  return json_build_object('ok', true, 'match', v_match) ;
end; $$;

-- 4) Deshacer el último "pasar" (hasta 2 minutos después); devuelve la evaluación
create or replace function public.deshacer_ultimo(mi_id uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_obj uuid; v_id uuid;
begin
  select l.id, l.para_ticket_id into v_id, v_obj from likes l
   where l.de_ticket_id = mi_id order by l.created_at desc limit 1;
  if v_id is null then return null; end if;
  if not exists (select 1 from likes where id = v_id and accion = 'pass' and created_at > now() - interval '2 minutes') then
    return null;
  end if;
  delete from likes where id = v_id;
  return v_obj;
end; $$;

-- 5) Activar perfil con frase opcional
drop function if exists public.activar_perfil_match(uuid, text, text);
create or replace function public.activar_perfil_match(p_ticket_id uuid, p_instagram text, p_interes text, p_bio text default null)
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
  update entradas set instagram = v_ig, busca_match = true, interes_match = p_interes,
                      bio = nullif(left(trim(coalesce(p_bio, '')), 80), '')
   where id = p_ticket_id and estado_pago = 'aprobado' and ingresado;
  if not found then raise exception 'Entrada no habilitada'; end if;
end; $$;

-- 6) Login y candidatos devuelven la frase
drop function if exists public.validar_acceso_match(text, text);
create or replace function public.validar_acceso_match(identificador text, p_email text default null)
returns table (id uuid, nombre text, instagram text, busca_match boolean, interes_match text,
               selfie_url text, fotos text[], bio text)
language plpgsql security definer set search_path = public
as $$
declare v text := trim(coalesce(identificador, ''));
begin
  if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return query select e.id, e.nombre, e.instagram, e.busca_match, e.interes_match, e.selfie_url, e.fotos, e.bio
                   from entradas e where e.id = v::uuid and e.estado_pago = 'aprobado' and e.ingresado;
  elsif v ~ '^\d{8}$' and p_email is not null then
    return query select e.id, e.nombre, e.instagram, e.busca_match, e.interes_match, e.selfie_url, e.fotos, e.bio
                   from entradas e
                  where e.dni = v and e.email = lower(trim(p_email)) and e.estado_pago = 'aprobado' and e.ingresado;
  end if;
end; $$;

drop function if exists public.obtener_candidatos(uuid);
create or replace function public.obtener_candidatos(mi_id uuid)
returns table (id uuid, nombre text, instagram text, me_dio_super boolean, selfie_url text, fotos text[], bio text)
language plpgsql security definer set search_path = public
as $$
declare mi_interes text; mi_genero text;
begin
  select interes_match, genero into mi_interes, mi_genero
    from entradas where entradas.id = mi_id and ingresado and busca_match;
  if mi_interes is null then return; end if;

  return query
  select e.id, split_part(e.nombre, ' ', 1), e.instagram,
         exists (select 1 from likes l where l.de_ticket_id = e.id and l.para_ticket_id = mi_id and l.accion = 'superlike'),
         e.selfie_url, e.fotos, e.bio
    from entradas e
   where e.ingresado and e.busca_match and not e.oculto and e.id <> mi_id
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

-- 7) Admin: sumar evaluaciones extra a una persona (por DNI)
create or replace function public.sumar_swipes(pin_seguridad text, p_dni text, p_cantidad int)
returns json
language plpgsql security definer set search_path = public
as $$
declare v_nombre text; v_extra int;
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  if p_cantidad is null or p_cantidad < 1 or p_cantidad > 500 then raise exception 'Cantidad inválida'; end if;
  update entradas set swipes_extra = swipes_extra + p_cantidad
   where dni = trim(p_dni) and estado_pago = 'aprobado'
  returning nombre || ' ' || apellido, swipes_extra into v_nombre, v_extra;
  if v_nombre is null then raise exception 'No hay entrada aprobada con ese DNI'; end if;
  return json_build_object('nombre', v_nombre, 'extra', v_extra);
end; $$;

grant execute on function public.estado_swipes(uuid), public.registrar_interaccion(uuid, uuid, text),
  public.deshacer_ultimo(uuid), public.activar_perfil_match(uuid, text, text, text),
  public.validar_acceso_match(text, text), public.obtener_candidatos(uuid), public.sumar_swipes(text, text, int)
to anon, authenticated;
revoke all on function public.cfg_int(text, int) from public, anon, authenticated;

select 'Script 6 aplicado' as resultado;
