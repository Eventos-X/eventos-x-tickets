-- =====================================================================
-- EVENTOS X · SCRIPT 9: EL PERFIL DE MATCH X NO SE PUEDE EDITAR UNA VEZ ACTIVADO
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
-- =====================================================================
create or replace function public.perfil_bloqueado(p_id uuid) returns boolean
language sql stable security definer set search_path = public
as $$ select coalesce((select busca_match from entradas where id = p_id), false) $$;

create or replace function public.activar_perfil_match(p_ticket_id uuid, p_instagram text, p_interes text, p_bio text, p_token text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_ig text := lower(trim(replace(coalesce(p_instagram, ''), '@', '')));
begin
  if not match_ok(p_ticket_id, p_token) then raise exception 'SESION_CERRADA'; end if;
  if perfil_bloqueado(p_ticket_id) then raise exception 'PERFIL_BLOQUEADO'; end if;
  if v_ig !~ '^[a-z0-9._]{1,30}$' then raise exception 'Instagram inválido'; end if;
  if p_interes not in ('Mujeres', 'Hombres', 'Ambos') then raise exception 'Interés inválido'; end if;
  if not exists (select 1 from entradas where id = p_ticket_id and selfie_url is not null) then raise exception 'Falta la foto principal'; end if;
  update entradas set instagram = v_ig, busca_match = true, interes_match = p_interes,
         bio = nullif(left(trim(coalesce(p_bio, '')), 80), '')
   where id = p_ticket_id;
end; $$;

create or replace function public.guardar_foto(p_ticket_id uuid, p_tipo text, p_url text)
returns text[] language plpgsql security definer set search_path = public
as $$
declare v text[];
begin
  if perfil_bloqueado(p_ticket_id) then raise exception 'PERFIL_BLOQUEADO'; end if;
  if p_tipo = 'selfie' then
    update entradas set selfie_url = p_url where id = p_ticket_id returning fotos into v;
  else
    select fotos into v from entradas where id = p_ticket_id;
    if coalesce(array_length(v, 1), 0) >= 2 then raise exception 'Máximo 2 fotos adicionales'; end if;
    update entradas set fotos = array_append(fotos, p_url) where id = p_ticket_id returning fotos into v;
  end if;
  return v;
end; $$;

create or replace function public.quitar_foto(p_ticket_id uuid, p_url text, p_token text)
returns text[] language plpgsql security definer set search_path = public
as $$
declare v text[];
begin
  if not match_ok(p_ticket_id, p_token) then raise exception 'SESION_CERRADA'; end if;
  if perfil_bloqueado(p_ticket_id) then raise exception 'PERFIL_BLOQUEADO'; end if;
  update entradas set fotos = array_remove(fotos, p_url) where id = p_ticket_id returning fotos into v;
  return coalesce(v, '{}');
end; $$;

revoke execute on function public.perfil_bloqueado(uuid) from public, anon, authenticated;
revoke execute on function public.guardar_foto(uuid, text, text) from public, anon, authenticated;

select 'Script 9 aplicado' as resultado;
