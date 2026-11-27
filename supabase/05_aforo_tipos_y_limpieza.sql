-- =====================================================================
-- EVENTOS X · SCRIPT 5: AFORO 1500, TIPOS DE ENTRADA DESDE LA BASE, LIMPIAR EVENTO
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
-- Se puede correr más de una vez sin romper nada.
-- =====================================================================

-- 1) Aforo: 1500 personas
insert into public.app_config (clave, valor) values ('aforo_max', '1500')
on conflict (clave) do update set valor = '1500';

-- 2) Tipos de entrada (se editan desde el Admin)
create table if not exists public.tipos_entrada (
  id      serial primary key,
  nombre  text    not null,
  precio  integer not null check (precio >= 0),
  cupo    integer check (cupo is null or cupo > 0),   -- vacío = sin cupo propio (solo el aforo general)
  genero  text    check (genero in ('Mujer', 'Hombre')), -- para el Match; vacío = no filtra
  activo  boolean not null default true,
  orden   integer not null default 0
);
alter table public.tipos_entrada enable row level security;
revoke all on public.tipos_entrada from anon, authenticated;

insert into public.tipos_entrada (nombre, precio, genero, orden)
select * from (values ('Mujeres', 25000, 'Mujer', 1), ('Hombres', 50000, 'Hombre', 2)) v(nombre, precio, genero, orden)
where not exists (select 1 from public.tipos_entrada);

-- Texto que se guarda en la entrada y sale en mails y en el Admin: "Mujeres - $25.000"
create or replace function public.etiqueta_tipo(p_nombre text, p_precio int)
returns text language sql immutable as $$
  select p_nombre || ' - $' || replace(to_char(p_precio, 'FM999,999,999'), ',', '.');
$$;

alter table public.entradas add column if not exists genero text;

-- 3) Reserva: valida el tipo contra la tabla, controla cupo por tipo y aforo general
create or replace function public.forzar_reserva_segura()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_aforo int; v_total int; t tipos_entrada%rowtype; v_vendidas int;
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
     or coalesce(length(new.apellido), 0) not between 1 and 40 then
    raise exception 'DATOS_INVALIDOS';
  end if;

  -- El tipo llega como su número (página nueva) o como su texto (página vieja en caché)
  select * into t from tipos_entrada
   where activo and (id::text = trim(new.tipo_entrada) or etiqueta_tipo(nombre, precio) = trim(new.tipo_entrada))
   limit 1;
  if t.id is null then raise exception 'DATOS_INVALIDOS'; end if;
  new.tipo_entrada := etiqueta_tipo(t.nombre, t.precio);
  new.genero       := t.genero;

  -- Aforo y cupos sin carreras: una reserva a la vez
  perform pg_advisory_xact_lock(777001);
  select coalesce(valor::int, 1500) into v_aforo from app_config where clave = 'aforo_max';
  select count(*) into v_total from entradas;
  if v_total >= coalesce(v_aforo, 1500) then raise exception 'AFORO_AGOTADO'; end if;
  if t.cupo is not null then
    select count(*) into v_vendidas from entradas where tipo_entrada = new.tipo_entrada;
    if v_vendidas >= t.cupo then raise exception 'CUPO_AGOTADO'; end if;
  end if;

  return new;
end; $$;

-- 4) La página de Entradas pide los tipos disponibles
create or replace function public.get_tipos_entrada()
returns table (id int, nombre text, precio int, etiqueta text, agotado boolean)
language sql security definer set search_path = public
as $$
  select t.id, t.nombre, t.precio, etiqueta_tipo(t.nombre, t.precio),
         (t.cupo is not null and (select count(*) from entradas e where e.tipo_entrada = etiqueta_tipo(t.nombre, t.precio)) >= t.cupo)
    from tipos_entrada t where t.activo order by t.orden, t.id;
$$;

-- 5) Admin: ver y editar tipos de entrada
create or replace function public.get_tipos_admin(pin_seguridad text)
returns table (id int, nombre text, precio int, cupo int, genero text, activo boolean, orden int, vendidas bigint)
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  return query
  select t.id, t.nombre, t.precio, t.cupo, t.genero, t.activo, t.orden,
         (select count(*) from entradas e where e.tipo_entrada = etiqueta_tipo(t.nombre, t.precio))
    from tipos_entrada t order by t.orden, t.id;
end; $$;

create or replace function public.guardar_tipo_entrada(pin_seguridad text, p_id int, p_nombre text, p_precio int,
                                                       p_cupo int, p_genero text, p_activo boolean, p_orden int)
returns int
language plpgsql security definer set search_path = public
as $$
declare v_id int; v_vieja text;
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  if coalesce(trim(p_nombre), '') = '' or p_precio is null or p_precio < 0 then raise exception 'Datos del tipo inválidos'; end if;
  if p_genero is not null and p_genero not in ('Mujer', 'Hombre') then raise exception 'Género inválido'; end if;

  if p_id is null then
    insert into tipos_entrada (nombre, precio, cupo, genero, activo, orden)
    values (trim(p_nombre), p_precio, p_cupo, p_genero, coalesce(p_activo, true), coalesce(p_orden, 0))
    returning id into v_id;
  else
    select etiqueta_tipo(nombre, precio) into v_vieja from tipos_entrada where id = p_id;
    -- Si ya hay entradas vendidas de este tipo, no se puede cambiar nombre ni precio (se desactiva y se crea otro)
    if v_vieja <> etiqueta_tipo(trim(p_nombre), p_precio)
       and exists (select 1 from entradas where tipo_entrada = v_vieja) then
      raise exception 'Este tipo ya tiene entradas vendidas: desactivalo y creá uno nuevo con el precio nuevo';
    end if;
    update tipos_entrada set nombre = trim(p_nombre), precio = p_precio, cupo = p_cupo, genero = p_genero,
                             activo = coalesce(p_activo, true), orden = coalesce(p_orden, 0)
     where id = p_id returning id into v_id;
  end if;
  return v_id;
end; $$;

-- 6) Match: el género sale del tipo de entrada (no del texto)
drop function if exists public.obtener_candidatos(uuid);
create or replace function public.obtener_candidatos(mi_id uuid)
returns table (id uuid, nombre text, instagram text, me_dio_super boolean, selfie_url text, fotos text[])
language plpgsql security definer set search_path = public
as $$
declare mi_interes text; mi_genero text;
begin
  select interes_match, genero into mi_interes, mi_genero
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
          or (mi_interes = 'Mujeres' and e.genero = 'Mujer')
          or (mi_interes = 'Hombres' and e.genero = 'Hombre'))
     and (e.interes_match = 'Ambos'
          or (e.interes_match = 'Mujeres' and mi_genero = 'Mujer')
          or (e.interes_match = 'Hombres' and mi_genero = 'Hombre'))
     and not exists (select 1 from likes l where l.de_ticket_id = mi_id and l.para_ticket_id = e.id)
     and not exists (select 1 from reportes r where r.de_ticket = mi_id and r.para_ticket = e.id)
   order by 4 desc, random()
   limit 50;
end; $$;

-- 7) Exportar entradas (antes de limpiar)
create or replace function public.exportar_entradas(pin_seguridad text)
returns table (nombre text, apellido text, dni text, email text, tipo_entrada text, estado_pago text,
               ingresado boolean, fecha_ingreso timestamptz, instagram text, created_at timestamptz)
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  return query select e.nombre, e.apellido, e.dni, e.email, e.tipo_entrada, e.estado_pago,
                      e.ingresado, e.fecha_ingreso, e.instagram, e.created_at
                 from entradas e order by e.created_at;
end; $$;

-- 8) Limpiar evento: borra entradas, likes, reportes y mails (las fotos las borra la función "limpiar-evento")
create or replace function public.limpiar_evento(pin_seguridad text, p_confirmacion text)
returns int
language plpgsql security definer set search_path = public
as $$
declare v int;
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  if p_confirmacion is distinct from 'BORRAR' then raise exception 'Falta escribir BORRAR para confirmar'; end if;
  delete from likes where true;
  delete from reportes where true;
  delete from cola_mails where true;
  delete from entradas where true;
  get diagnostics v = row_count;
  return v;
end; $$;
revoke all on function public.limpiar_evento(text, text) from public, anon, authenticated;
grant execute on function public.limpiar_evento(text, text) to service_role;

grant execute on function public.get_tipos_entrada(), public.get_tipos_admin(text),
  public.guardar_tipo_entrada(text, int, text, int, int, text, boolean, int),
  public.obtener_candidatos(uuid), public.exportar_entradas(text)
to anon, authenticated;

select 'Script 5 aplicado' as resultado, (select valor from app_config where clave = 'aforo_max') as aforo;
