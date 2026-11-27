-- =====================================================================
-- EVENTOS X · SCRIPT 2: ENVÍO AUTOMÁTICO DE MAILS CADA 1 MINUTO
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
-- Correrlo DESPUÉS de crear la Edge Function "enviar-mails".
-- ⚠️ Reemplazá PEGAR_ACA_TU_CRON_SECRET por la misma clave que pusiste
--    en el secret CRON_SECRET de la Edge Function.
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Guardamos la clave en el Vault (encriptada)
do $$
begin
  if exists (select 1 from vault.secrets where name = 'cron_secret') then
    perform vault.update_secret((select id from vault.secrets where name = 'cron_secret'), 'PEGAR_ACA_TU_CRON_SECRET');
  else
    perform vault.create_secret('PEGAR_ACA_TU_CRON_SECRET', 'cron_secret');
  end if;
end $$;

-- Si ya existía la tarea, la reemplazamos
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
  -- Solo llama a la función si hay mails esperando (ahorra disco en el plan gratis)
  where exists (select 1 from public.cola_mails where estado in ('pendiente', 'enviando'));
  $$
);

-- Para ver cómo va la cola:
--   select estado, count(*) from cola_mails group by estado;
-- Para ver errores:
--   select destinatario, ultimo_error from cola_mails where estado = 'error';
