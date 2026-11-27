-- =====================================================================
-- EVENTOS X · SCRIPT 1: SEGURIDAD + FUNCIONES
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
-- Se puede correr más de una vez sin romper nada.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1) CONFIGURACIÓN PRIVADA (PINs y aforo fuera del código)
--    Nadie puede leer esta tabla desde la web (RLS sin políticas).
-- ---------------------------------------------------------------------
create table if not exists public.app_config (
  clave text primary key,
  valor text not null
);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;

-- Los PINs se guardan encriptados. ⚠️ CAMBIÁ estos valores por PINs NUEVOS
-- (los viejos quedaron escritos en el chat y en el código).
insert into public.app_config (clave, valor) values
  ('pin_admin', extensions.crypt('CAMBIAR_PIN_ADMIN', extensions.gen_salt('bf'))),
  ('pin_staff', extensions.crypt('CAMBIAR_PIN_STAFF', extensions.gen_salt('bf'))),
  ('aforo_max', '650')
on conflict (clave) do nothing;

-- Para cambiar un PIN más adelante:
--   update app_config set valor = extensions.crypt('NUEVO_PIN', extensions.gen_salt('bf')) where clave = 'pin_staff';

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

-- ---------------------------------------------------------------------
-- 2) COLA DE MAILS (la Edge Function "enviar-mails" la procesa)
-- ---------------------------------------------------------------------
create table if not exists public.cola_mails (
  id            bigserial primary key,
  entrada_id    uuid not null references public.entradas(id) on delete cascade,
  tipo          text not null check (tipo in ('qr', 'match')),
  destinatario  text not null,
  estado        text not null default 'pendiente' check (estado in ('pendiente', 'enviando', 'enviado', 'error')),
  intentos      int  not null default 0,
  ultimo_error  text,
  created_at    timestamptz not null default now(),
  enviado_at    timestamptz,
  unique (entrada_id, tipo)
);
create index if not exists cola_mails_estado_idx on public.cola_mails (estado, created_at);
alter table public.cola_mails enable row level security;
revoke all on public.cola_mails from anon, authenticated;

create or replace function public.encolar_mail(p_entrada_id uuid, p_tipo text, p_reenviar boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into cola_mails (entrada_id, tipo, destinatario)
  select id, p_tipo, lower(trim(email)) from entradas where id = p_entrada_id and email is not null
  on conflict (entrada_id, tipo) do update
    set estado = 'pendiente', intentos = 0, ultimo_error = null
    where p_reenviar;
end; $$;
revoke all on function public.encolar_mail(uuid, text, boolean) from public, anon, authenticated;

-- Usadas SOLO por la Edge Function (con la service_role key)
create or replace function public.tomar_lote_mails(p_cantidad int default 100)
returns table (cola_id bigint, tipo text, destinatario text, entrada_id uuid, nombre text, apellido text, tipo_entrada text)
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Mails que quedaron "enviando" más de 10 min (función cortada) vuelven a la cola
  update cola_mails set estado = 'pendiente'
   where estado = 'enviando' and created_at < now() - interval '10 minutes' and intentos < 3;

  return query
  with lote as (
    select c.id from cola_mails c
     where c.estado = 'pendiente'
     order by c.created_at
     limit p_cantidad
     for update skip locked
  )
  update cola_mails c
     set estado = 'enviando', intentos = c.intentos + 1
    from lote, entradas e
   where c.id = lote.id and e.id = c.entrada_id
  returning c.id, c.tipo, c.destinatario, e.id, e.nombre, e.apellido, e.tipo_entrada;
end; $$;

create or replace function public.marcar_mails(p_ids bigint[], p_ok boolean, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_ok then
    update cola_mails set estado = 'enviado', enviado_at = now(), ultimo_error = null where id = any(p_ids);
  else
    update cola_mails
       set estado = case when intentos >= 3 then 'error' else 'pendiente' end,
           ultimo_error = left(p_error, 500)
     where id = any(p_ids);
  end if;
end; $$;

revoke all on function public.tomar_lote_mails(int) from public, anon, authenticated;
revoke all on function public.marcar_mails(bigint[], boolean, text) from public, anon, authenticated;
grant execute on function public.tomar_lote_mails(int) to service_role;
grant execute on function public.marcar_mails(bigint[], boolean, text) to service_role;

-- ---------------------------------------------------------------------
-- 3) RESERVAS (index.html): la web solo puede crear reservas PENDIENTES
-- ---------------------------------------------------------------------
create or replace function public.forzar_reserva_segura()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_aforo int; v_total int;
begin
  -- Valores que el navegador NO puede elegir
  new.id            := coalesce(new.id, gen_random_uuid());
  new.id_venta      := new.id;
  new.estado_pago   := 'pendiente';
  new.ingresado     := false;
  new.fecha_ingreso := null;
  new.busca_match   := false;
  new.instagram     := null;
  new.interes_match := null;
  new.puntuacion    := null;
  new.created_at    := now();

  -- Limpieza y validación de datos
  new.nombre   := trim(new.nombre);
  new.apellido := trim(new.apellido);
  new.dni      := trim(new.dni);
  new.email    := lower(trim(new.email));
  if new.dni !~ '^\d{8}$'
     or new.email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'
     or coalesce(length(new.nombre), 0) not between 1 and 40
     or coalesce(length(new.apellido), 0) not between 1 and 40
     or new.tipo_entrada not in ('Mujeres - $25.000', 'Hombres - $50.000') then
    raise exception 'DATOS_INVALIDOS';
  end if;

  -- Aforo sin carreras: una reserva a la vez
  perform pg_advisory_xact_lock(777001);
  select coalesce(valor::int, 650) into v_aforo from app_config where clave = 'aforo_max';
  select count(*) into v_total from entradas;
  if v_total >= coalesce(v_aforo, 650) then
    raise exception 'AFORO_AGOTADO';
  end if;

  return new;
end; $$;

-- Reemplaza al trigger viejo de aforo (ahora está incluido acá)
do $$
declare t record;
begin
  for t in
    select tgname from pg_trigger
     where tgrelid = 'public.entradas'::regclass and not tgisinternal
       and tgfoid = 'public.check_aforo_maximo'::regproc
  loop
    execute format('drop trigger %I on public.entradas', t.tgname);
  end loop;
end $$;
drop trigger if exists trg_reserva_segura on public.entradas;
create trigger trg_reserva_segura before insert on public.entradas
  for each row execute function public.forzar_reserva_segura();

-- La web solo puede INSERTAR (la política ya existe). Nadie puede leer/editar/borrar directo.
revoke select, update, delete on public.entradas from anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) ADMIN (admin.html)
-- ---------------------------------------------------------------------
create or replace function public.get_pendientes(pin_seguridad text)
returns setof public.entradas
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  return query select * from entradas where estado_pago = 'pendiente' order by created_at desc;
end; $$;

create or replace function public.aprobar_ticket(ticket_id uuid, pin_seguridad text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  update entradas set estado_pago = 'aprobado' where id = ticket_id and estado_pago = 'pendiente';
  if not found then raise exception 'La reserva ya no está pendiente'; end if;
  perform encolar_mail(ticket_id, 'qr');  -- el mail con el QR sale solo
end; $$;

create or replace function public.borrar_ticket(ticket_id uuid, pin_seguridad text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  delete from entradas where id = ticket_id and estado_pago = 'pendiente';
end; $$;

create or replace function public.reenviar_qr(p_dni text, pin_seguridad text)
returns text
language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_email text;
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  select id, email into v_id, v_email from entradas where dni = trim(p_dni) and estado_pago = 'aprobado';
  if v_id is null then raise exception 'No hay entrada aprobada con ese DNI'; end if;
  perform encolar_mail(v_id, 'qr', true);
  return v_email;
end; $$;

create or replace function public.get_estado_mails(pin_seguridad text)
returns json
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  return (select json_build_object(
    'pendientes', count(*) filter (where estado in ('pendiente', 'enviando')),
    'enviados',   count(*) filter (where estado = 'enviado'),
    'errores',    count(*) filter (where estado = 'error')
  ) from cola_mails);
end; $$;

create or replace function public.get_reporte_ventas(pin_seguridad text)
returns table(nombre text, apellido text, dni text, estado_pago text, tipo_entrada text, created_at timestamptz)
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  return query select e.nombre, e.apellido, e.dni, e.estado_pago, e.tipo_entrada, e.created_at
                 from entradas e order by e.created_at desc;
end; $$;

-- ---------------------------------------------------------------------
-- 5) PUERTA (scan-staff.html): validar + marcar ingreso en UN solo paso
-- ---------------------------------------------------------------------
drop function if exists public.marcar_ingreso(uuid, text);
drop function if exists public.buscar_ticket_id(text, text);
drop function if exists public.buscar_ticket_dni(text, text);

create or replace function public.registrar_ingreso(p_codigo text, pin_seguridad text)
returns table (resultado text, nombre text, apellido text, dni text, tipo_entrada text, fecha_ingreso timestamptz)
language plpgsql security definer set search_path = public
as $$
declare
  v_codigo text := trim(coalesce(p_codigo, ''));
  v_uuid   text := substring(v_codigo from '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');
  e        entradas%rowtype;
begin
  if not pin_ok('staff', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;

  if v_uuid is not null then
    select * into e from entradas x where x.id = v_uuid::uuid or x.id_venta = v_uuid::uuid limit 1;
  elsif v_codigo ~ '^\d{8}$' then
    select * into e from entradas x where x.dni = v_codigo limit 1;
  end if;

  if e.id is null then
    return query select 'no_existe'::text, null::text, null::text, null::text, null::text, null::timestamptz;
    return;
  end if;
  if e.estado_pago <> 'aprobado' then
    return query select 'pendiente'::text, e.nombre, e.apellido, e.dni, e.tipo_entrada, null::timestamptz;
    return;
  end if;

  -- Atómico: si dos guardias escanean a la vez, solo uno gana
  update entradas x set ingresado = true, fecha_ingreso = now()
   where x.id = e.id and coalesce(x.ingresado, false) = false;

  if found then
    perform encolar_mail(e.id, 'match');  -- mail con el link al Match
    return query select 'ok'::text, e.nombre, e.apellido, e.dni, e.tipo_entrada, now();
  else
    return query select 'ya_ingreso'::text, e.nombre, e.apellido, e.dni, e.tipo_entrada, e.fecha_ingreso;
  end if;
end; $$;

create or replace function public.get_contadores(pin_seguridad text)
returns json
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('staff', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  return (select json_build_object(
    'vendidas',   count(*) filter (where estado_pago = 'aprobado'),
    'ingresados', count(*) filter (where estado_pago = 'aprobado' and ingresado)
  ) from entradas);
end; $$;

-- ---------------------------------------------------------------------
-- 6) MATCH (match.html)
--    El ID de la entrada (link del mail) funciona como llave.
--    Con DNI hace falta también el email.
-- ---------------------------------------------------------------------
drop function if exists public.validar_acceso_match(text);
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

create or replace function public.activar_perfil_match(p_ticket_id uuid, p_instagram text, p_interes text, p_foto text default '')
returns void
language plpgsql security definer set search_path = public
as $$
declare v_ig text := lower(trim(replace(coalesce(p_instagram, ''), '@', '')));
begin
  if v_ig !~ '^[a-z0-9._]{1,30}$' then raise exception 'Instagram inválido'; end if;
  if p_interes not in ('Mujeres', 'Hombres', 'Ambos') then raise exception 'Interés inválido'; end if;
  update entradas set instagram = v_ig, busca_match = true, interes_match = p_interes
   where id = p_ticket_id and estado_pago = 'aprobado' and ingresado;
  if not found then raise exception 'Entrada no habilitada'; end if;
end; $$;

drop function if exists public.obtener_candidatos(uuid);
create or replace function public.obtener_candidatos(mi_id uuid)
returns table (id uuid, nombre text, instagram text, me_dio_super boolean)
language plpgsql security definer set search_path = public
as $$
declare mi_interes text; mi_tipo text;
begin
  select interes_match, tipo_entrada into mi_interes, mi_tipo
    from entradas where entradas.id = mi_id and ingresado and busca_match;
  if mi_interes is null then return; end if;

  return query
  select e.id, e.nombre, e.instagram,
         exists (select 1 from likes l where l.de_ticket_id = e.id and l.para_ticket_id = mi_id and l.accion = 'superlike')
    from entradas e
   where e.ingresado and e.busca_match and e.id <> mi_id
     and coalesce(e.instagram, '') <> ''
     and (mi_interes = 'Ambos'
          or (mi_interes = 'Mujeres' and e.tipo_entrada ilike '%Mujer%')
          or (mi_interes = 'Hombres' and e.tipo_entrada ilike '%Hombre%'))
     -- y que a la otra persona también le interese mi género
     and (e.interes_match = 'Ambos'
          or (e.interes_match = 'Mujeres' and mi_tipo ilike '%Mujer%')
          or (e.interes_match = 'Hombres' and mi_tipo ilike '%Hombre%'))
     and not exists (select 1 from likes l where l.de_ticket_id = mi_id and l.para_ticket_id = e.id)
   order by 4 desc, random()
   limit 50;
end; $$;

create or replace function public.registrar_interaccion(mi_id uuid, objetivo_id uuid, tipo_accion text)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if tipo_accion not in ('like', 'superlike', 'pass') or mi_id = objetivo_id then return false; end if;
  if not exists (select 1 from entradas where id = mi_id and ingresado and busca_match) then return false; end if;

  insert into likes (de_ticket_id, para_ticket_id, accion)
  values (mi_id, objetivo_id, tipo_accion)
  on conflict (de_ticket_id, para_ticket_id) do nothing;

  -- Like y Súper Like cuentan los dos para el match
  return tipo_accion in ('like', 'superlike') and exists (
    select 1 from likes where de_ticket_id = objetivo_id and para_ticket_id = mi_id and accion in ('like', 'superlike')
  );
end; $$;

create or replace function public.obtener_mis_matches(mi_id uuid)
returns table (id uuid, nombre text, instagram text, es_super boolean)
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from entradas where entradas.id = mi_id and ingresado) then return; end if;
  return query
  select e.id, e.nombre, e.instagram, (dado.accion = 'superlike' or recibido.accion = 'superlike')
    from likes dado
    join likes recibido on recibido.de_ticket_id = dado.para_ticket_id and recibido.para_ticket_id = mi_id
    join entradas e on e.id = dado.para_ticket_id
   where dado.de_ticket_id = mi_id
     and dado.accion in ('like', 'superlike') and recibido.accion in ('like', 'superlike')
   order by greatest(dado.created_at, recibido.created_at) desc;
end; $$;

-- NPS: solo se puede puntuar una vez
create or replace function public.guardar_nps(ticket_id uuid, puntaje integer)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if puntaje not between 1 and 5 then return; end if;
  update entradas set puntuacion = puntaje where id = ticket_id and puntuacion is null;
end; $$;

-- ---------------------------------------------------------------------
-- 7) CERRAR ACCESOS PÚBLICOS PELIGROSOS
-- ---------------------------------------------------------------------
-- likes: antes cualquiera podía leer/borrar/inventar likes de todos
drop policy if exists "Permitir gestion publica de likes" on public.likes;
revoke all on public.likes from anon, authenticated;

-- Tabla del evento anterior: que nadie pueda insertar basura
drop policy if exists "Permitir compras publicas" on public."entradas Janos 23.05.26";

-- Vistas de estadísticas: solo visibles desde el panel de Supabase
revoke all on public.vista_estadisticas_usuarios from anon, authenticated;
revoke all on public.vista_historial_tinder from anon, authenticated;

-- Funciones públicas que usa la web
grant execute on function public.get_pendientes(text), public.aprobar_ticket(uuid, text), public.borrar_ticket(uuid, text),
  public.reenviar_qr(text, text), public.get_estado_mails(text), public.get_reporte_ventas(text),
  public.registrar_ingreso(text, text), public.get_contadores(text),
  public.validar_acceso_match(text, text), public.activar_perfil_match(uuid, text, text, text),
  public.obtener_candidatos(uuid), public.registrar_interaccion(uuid, uuid, text),
  public.obtener_mis_matches(uuid), public.guardar_nps(uuid, integer)
to anon, authenticated;
