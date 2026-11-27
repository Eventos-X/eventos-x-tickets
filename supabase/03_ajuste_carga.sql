-- =====================================================================
-- EVENTOS X · SCRIPT 3: BAJAR LA CARGA DE LA BASE (plan gratis)
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
-- Se puede correr más de una vez sin romper nada.
-- =====================================================================

-- 1) La tarea de mails solo llama a la función si HAY mails esperando.
--    (La clave sigue saliendo del Vault, no está escrita acá.)
do $$
begin
  perform cron.unschedule('enviar-mails');
exception when others then null;
end $$;

select cron.schedule(
  'enviar-mails',
  '* * * * *',
  $$
  select net.http_post(
    url     := 'https://vogizootbnhvbeugroyr.supabase.co/functions/v1/enviar-mails',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000
  )
  where exists (select 1 from public.cola_mails where estado in ('pendiente', 'enviando'));
  $$
);

-- 2) Limpieza diaria del historial (4 AM): borra registros de más de 2 días
do $$
begin
  perform cron.unschedule('limpiar-historial');
exception when others then null;
end $$;

select cron.schedule(
  'limpiar-historial',
  '0 7 * * *',  -- 07:00 UTC = 04:00 Argentina
  $$ delete from cron.job_run_details where end_time < now() - interval '2 days'; $$
);

-- Limpieza ahora mismo del historial acumulado
delete from cron.job_run_details where end_time < now() - interval '2 days';

-- 3) PIN incorrecto: sin demora (la demora ocupaba la base y permitía trabarla)
create or replace function public.pin_ok(p_rol text, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_hash text;
begin
  select valor into v_hash from app_config where clave = 'pin_' || p_rol;
  return v_hash is not null and p_pin is not null and v_hash = crypt(p_pin, v_hash);
end; $$;
revoke all on function public.pin_ok(text, text) from public, anon, authenticated;

-- Match: también sin demora cuando los datos no coinciden
create or replace function public.validar_acceso_match(identificador text, p_email text default null)
returns table (id uuid, nombre text, instagram text, busca_match boolean, interes_match text)
language plpgsql security definer set search_path = public
as $$
declare v text := trim(coalesce(identificador, ''));
begin
  if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return query select e.id, e.nombre, e.instagram, e.busca_match, e.interes_match
                   from entradas e where e.id = v::uuid and e.estado_pago = 'aprobado' and e.ingresado;
  elsif v ~ '^\d{8}$' and p_email is not null then
    return query select e.id, e.nombre, e.instagram, e.busca_match, e.interes_match
                   from entradas e
                  where e.dni = v and e.email = lower(trim(p_email)) and e.estado_pago = 'aprobado' and e.ingresado;
  end if;
end; $$;

-- Verificación
select jobname, schedule, active from cron.job order by jobname;
