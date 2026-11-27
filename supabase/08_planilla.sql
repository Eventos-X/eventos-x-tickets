-- =====================================================================
-- EVENTOS X · SCRIPT 8: DATOS PARA LA PLANILLA DE GOOGLE SHEETS
-- Dónde: Supabase → SQL Editor → New query → pegar TODO → Run
-- La planilla llama a esta función con el PIN de admin (se carga una sola vez en la planilla).
-- =====================================================================

create or replace function public.datos_planilla(pin_seguridad text)
returns table (
  fecha_compra   timestamptz,
  nombre         text,
  apellido       text,
  dni            text,
  email          text,
  tipo_entrada   text,
  sexo           text,
  precio         int,
  estado_pago    text,
  ingreso        text,
  hora_ingreso   timestamptz,
  instagram      text,
  en_match       text
)
language plpgsql security definer set search_path = public
as $$
begin
  if not pin_ok('admin', pin_seguridad) then raise exception 'PIN Incorrecto'; end if;
  return query
  select e.created_at, e.nombre, e.apellido, e.dni, e.email, e.tipo_entrada,
         coalesce(e.genero, case when e.tipo_entrada ilike '%mujer%' then 'Mujer'
                                 when e.tipo_entrada ilike '%hombre%' then 'Hombre' end, 'Sin dato'),
         coalesce(t.precio, nullif(regexp_replace(split_part(e.tipo_entrada, '$', 2), '[^0-9]', '', 'g'), '')::int, 0),
         case e.estado_pago when 'aprobado' then 'Aprobada' else 'Pendiente' end,
         case when e.ingresado then 'Sí' else 'No' end,
         e.fecha_ingreso,
         e.instagram,
         case when e.busca_match then 'Sí' else 'No' end
    from entradas e
    left join tipos_entrada t on etiqueta_tipo(t.nombre, t.precio) = e.tipo_entrada
   order by e.created_at;
end; $$;

grant execute on function public.datos_planilla(text) to anon, authenticated;

select 'Script 8 aplicado' as resultado;
