-- =====================================================================
-- Fiesta fin de año 2026 - Funciones del módulo "Gestión de nómina"
-- Ruta en el repositorio: sql/09_gestion_nomina.sql
-- Requiere haber ejecutado 01 al 06
-- Se puede ejecutar más de una vez sin problema
-- Ejecutar COMPLETO en Supabase > SQL Editor > New query > Run
-- (verificar que el selector NO esté en "Logs")
--
-- Funciones (solo administradores):
--   cargar_nomina(filas, reemplazar)  -> carga la nómina desde la página
--       reemplazar = true : borra registros, sorteos, ganadores y nómina
--                           y carga la nueva (números vuelven a empezar en 1)
--       reemplazar = false: agrega colaboradores nuevos y actualiza los
--                           existentes; no borra nada
--   limpiar_registros()               -> borra registros, sorteos y ganadores
--                                        y conserva la nómina
-- Todo se hace en un solo paso: si algo falla, no se cambia nada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Cargar nómina
-- ---------------------------------------------------------------------
create or replace function public.cargar_nomina(p_filas jsonb, p_reemplazar boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existentes integer;
  v_total      integer;
  v_problema   text;
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;

  if p_filas is null or jsonb_typeof(p_filas) <> 'array' or jsonb_array_length(p_filas) = 0 then
    raise exception 'El archivo no tiene colaboradores para cargar.';
  end if;

  -- Datos normalizados del archivo
  create temp table _carga on commit drop as
  select
    upper(regexp_replace(coalesce(x->>'identificacion', ''), '[^0-9A-Za-z]', '', 'g'))  as identificacion,
    trim(regexp_replace(coalesce(x->>'nombres', ''),   '\s+', ' ', 'g'))                  as nombres,
    trim(regexp_replace(coalesce(x->>'apellidos', ''), '\s+', ' ', 'g'))                  as apellidos,
    nullif(trim(coalesce(x->>'fecha_vinculacion', '')), '')                               as fecha_texto,
    nullif(trim(regexp_replace(coalesce(x->>'cargo', ''), '\s+', ' ', 'g')), '')          as cargo,
    trim(regexp_replace(coalesce(x->>'empresa', ''),   '\s+', ' ', 'g'))                  as empresa,
    nullif(trim(coalesce(x->>'tipo_personal', '')), '')                                   as tipo_personal
  from jsonb_array_elements(p_filas) x;

  -- Validaciones (las mismas que hace la página antes de enviar)
  select 'Fila sin identificación, nombres, apellidos o empresa (' || coalesce(nullif(identificacion, ''), 'sin identificación') || ').'
  into v_problema
  from _carga
  where identificacion = '' or nombres = '' or apellidos = '' or empresa = ''
  limit 1;
  if v_problema is not null then raise exception '%', v_problema; end if;

  select 'La identificación ' || identificacion || ' está repetida en el archivo.'
  into v_problema
  from _carga group by identificacion having count(*) > 1
  limit 1;
  if v_problema is not null then raise exception '%', v_problema; end if;

  select 'Tipo de personal no válido para ' || identificacion || ': "' || tipo_personal || '".'
  into v_problema
  from _carga
  where tipo_personal is not null and tipo_personal not in ('Asistencial', 'Administrativo')
  limit 1;
  if v_problema is not null then raise exception '%', v_problema; end if;

  select 'Fecha de vinculación no válida para ' || identificacion || ': "' || fecha_texto || '" (use AAAA-MM-DD).'
  into v_problema
  from _carga
  where fecha_texto is not null and fecha_texto !~ '^\d{4}-\d{2}-\d{2}$'
  limit 1;
  if v_problema is not null then raise exception '%', v_problema; end if;

  -- Reemplazo total: borra todo lo anterior
  if p_reemplazar then
    truncate table public.ganadores, public.premios, public.registros restart identity;
    delete from public.nomina;
  end if;

  select count(*) into v_existentes
  from public.nomina n
  where exists (select 1 from _carga c where c.identificacion = n.identificacion);

  insert into public.nomina (identificacion, nombres, apellidos, fecha_vinculacion, cargo, empresa, tipo_personal)
  select identificacion, nombres, apellidos, fecha_texto::date, cargo, empresa, tipo_personal
  from _carga
  on conflict (identificacion) do update
    set nombres           = excluded.nombres,
        apellidos         = excluded.apellidos,
        fecha_vinculacion = excluded.fecha_vinculacion,
        cargo             = excluded.cargo,
        empresa           = excluded.empresa,
        tipo_personal     = excluded.tipo_personal;
  get diagnostics v_total = row_count;

  return json_build_object(
    'total',        v_total,
    'nuevos',       v_total - v_existentes,
    'actualizados', v_existentes,
    'reemplazo',    p_reemplazar,
    'en_nomina',    (select count(*) from public.nomina)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Borrar registros, sorteos y ganadores (conserva la nómina)
-- ---------------------------------------------------------------------
create or replace function public.limpiar_registros()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_registros integer;
  v_sorteos   integer;
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;

  select count(*) into v_registros from public.registros;
  select count(*) into v_sorteos   from public.premios;

  truncate table public.ganadores, public.premios, public.registros restart identity;

  return json_build_object('registros_borrados', v_registros, 'sorteos_borrados', v_sorteos);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Permisos: solo usuarios autenticados (y dentro se valida admin)
-- ---------------------------------------------------------------------
revoke execute on function public.cargar_nomina(jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.limpiar_registros()           from public, anon, authenticated;
grant  execute on function public.cargar_nomina(jsonb, boolean) to authenticated;
grant  execute on function public.limpiar_registros()           to authenticated;
