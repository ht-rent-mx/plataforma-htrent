-- =====================================================================
-- Plataforma HT · Interacciones 1 a 1 · Equipos de los coordinadores
-- (2026-11-03)
--
-- Qué hace:
--   Los coordinadores (Jésica en SC y César en Documentos) llevan, además
--   de su propio seguimiento con Roger, la gestión 1 a 1 de SUS ejecutivos:
--   sesiones, rutina, KPIs, acuerdos, plan de desarrollo y perfil.
--
--   - Estos datos viven en la base de la plataforma (no en la hoja
--     1a1_HTRENT). Cada coordinador solo ve y edita su propio equipo.
--   - Roger (admin) puede consultar los equipos de todos, en solo lectura.
--   - Si el ejecutivo tiene usuario en la plataforma, el coordinador lo
--     vincula con su correo y el ejecutivo ve su ficha en solo lectura.
--
-- Cómo correrlo: Supabase > SQL Editor > pegar todo > Run.
-- Se puede correr más de una vez sin dañar nada.
-- =====================================================================

-- 1. Quién coordina qué área ------------------------------------------
alter table core.uno_a_uno_accesos
  add column if not exists coordina text check (coordina in ('SC','DOC'));

update core.uno_a_uno_accesos set coordina = 'SC'  where colaborador_id = 'C1';  -- Jésica
update core.uno_a_uno_accesos set coordina = 'DOC' where colaborador_id = 'C3';  -- César (Noé)

-- 2. Ejecutivos de cada coordinador ----------------------------------
create table if not exists core.uno_a_uno_equipo (
  id             uuid primary key default gen_random_uuid(),
  coordinador_id uuid not null references core.perfiles(id) on delete cascade,
  perfil_id      uuid references core.perfiles(id) on delete set null,  -- usuario del ejecutivo (opcional)
  datos          jsonb not null default '{}'::jsonb,                    -- nombre, puesto, área, perfil…
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index if not exists uno_a_uno_equipo_coord_idx  on core.uno_a_uno_equipo(coordinador_id);
create index if not exists uno_a_uno_equipo_perfil_idx on core.uno_a_uno_equipo(perfil_id);

-- 3. Sesiones, rutinas, KPIs, acuerdos y desarrollo del equipo --------
create table if not exists core.uno_a_uno_equipo_registros (
  id             uuid primary key default gen_random_uuid(),
  coordinador_id uuid not null references core.perfiles(id) on delete cascade,
  colaborador_id uuid not null references core.uno_a_uno_equipo(id) on delete cascade,
  hoja           text not null check (hoja in ('Sesiones','Acuerdos','KPIs','Desarrollo','Rutinas','Competencias')),
  datos          jsonb not null default '{}'::jsonb,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index if not exists uno_a_uno_eq_reg_colab_idx on core.uno_a_uno_equipo_registros(colaborador_id);
create index if not exists uno_a_uno_eq_reg_coord_idx on core.uno_a_uno_equipo_registros(coordinador_id);

-- Nadie lee las tablas directo: todo pasa por las funciones de abajo.
alter table core.uno_a_uno_equipo enable row level security;
alter table core.uno_a_uno_equipo_registros enable row level security;
revoke all on core.uno_a_uno_equipo, core.uno_a_uno_equipo_registros from public, anon, authenticated;

-- 4. Contexto de quien entra -----------------------------------------
-- Sustituye a uno_a_uno_mi_acceso() en el arranque de la app: ya no
-- truena si la persona no tiene ficha en la hoja (p. ej. un ejecutivo
-- nuevo que solo tiene seguimiento con su coordinador).
create or replace function core.uno_a_uno_contexto()
returns json
language plpgsql stable security definer
set search_path to 'core','public'
as $$
declare
  r core.uno_a_uno_accesos;
  v_es_ejec boolean;
begin
  if auth.uid() is null or core.nivel_modulo('uno_a_uno') is null then
    raise exception 'No tienes acceso a Interacciones 1 a 1';
  end if;
  select * into r from core.uno_a_uno_accesos where perfil_id = auth.uid();
  select exists(select 1 from core.uno_a_uno_equipo e
                 where e.perfil_id = auth.uid()
                   and coalesce(e.datos->>'activo','SI') <> 'NO') into v_es_ejec;
  if r.perfil_id is null and not v_es_ejec then
    raise exception 'Tu usuario no está vinculado a Interacciones 1 a 1. Pídele a Roger o a tu coordinador que te dé de alta.';
  end if;
  return json_build_object(
    'colaboradorId', r.colaborador_id,
    'clave',         r.clave,
    'coordina',      r.coordina,
    'esAdmin',       core.es_admin(),
    'tieneCoordinador', v_es_ejec,
    'nombre',        (select nombre from core.perfiles where id = auth.uid()),
    'puesto',        (select puesto from core.perfiles where id = auth.uid())
  );
end $$;

-- 5. Leer el equipo ---------------------------------------------------
--   modo 'coord' : el equipo del coordinador que entra (editable)
--   modo 'mio'   : mi propia ficha como ejecutivo (solo lectura)
--   modo 'todos' : todos los equipos (solo admin, solo lectura)
create or replace function core.uno_a_uno_equipo_leer(p_modo text default 'coord')
returns json
language plpgsql stable security definer
set search_path to 'core','public'
as $$
declare v_ids uuid[];
begin
  if auth.uid() is null or core.nivel_modulo('uno_a_uno') is null then
    raise exception 'No tienes acceso a Interacciones 1 a 1';
  end if;

  if p_modo = 'coord' then
    if not exists(select 1 from core.uno_a_uno_accesos where perfil_id = auth.uid() and coordina is not null) then
      raise exception 'Esta sección es solo para coordinadores';
    end if;
    select coalesce(array_agg(id), '{}') into v_ids from core.uno_a_uno_equipo where coordinador_id = auth.uid();
  elsif p_modo = 'mio' then
    select coalesce(array_agg(id), '{}') into v_ids from core.uno_a_uno_equipo where perfil_id = auth.uid();
  elsif p_modo = 'todos' then
    if not core.es_admin() then raise exception 'Solo un administrador puede ver todos los equipos'; end if;
    select coalesce(array_agg(id), '{}') into v_ids from core.uno_a_uno_equipo;
  else
    raise exception 'Modo no válido';
  end if;

  return json_build_object(
    'Colaboradores', coalesce((
      select json_agg(e.datos || jsonb_build_object(
                'id', e.id, 'rol', 'EJEC',
                'coordinadorId', e.coordinador_id,
                'coordinador', c.nombre,
                'correoPlataforma', p.correo)
              order by e.datos->>'nombre')
        from core.uno_a_uno_equipo e
        join core.perfiles c on c.id = e.coordinador_id
        left join core.perfiles p on p.id = e.perfil_id
       where e.id = any(v_ids)), '[]'::json),
    'Sesiones',     coalesce((select json_agg(x.datos || jsonb_build_object('id',x.id,'colaboradorId',x.colaborador_id)) from core.uno_a_uno_equipo_registros x where x.colaborador_id = any(v_ids) and x.hoja='Sesiones'),     '[]'::json),
    'Acuerdos',     coalesce((select json_agg(x.datos || jsonb_build_object('id',x.id,'colaboradorId',x.colaborador_id)) from core.uno_a_uno_equipo_registros x where x.colaborador_id = any(v_ids) and x.hoja='Acuerdos'),     '[]'::json),
    'KPIs',         coalesce((select json_agg(x.datos || jsonb_build_object('id',x.id,'colaboradorId',x.colaborador_id)) from core.uno_a_uno_equipo_registros x where x.colaborador_id = any(v_ids) and x.hoja='KPIs'),         '[]'::json),
    'Desarrollo',   coalesce((select json_agg(x.datos || jsonb_build_object('id',x.id,'colaboradorId',x.colaborador_id)) from core.uno_a_uno_equipo_registros x where x.colaborador_id = any(v_ids) and x.hoja='Desarrollo'),   '[]'::json),
    'Rutinas',      coalesce((select json_agg(x.datos || jsonb_build_object('id',x.id,'colaboradorId',x.colaborador_id)) from core.uno_a_uno_equipo_registros x where x.colaborador_id = any(v_ids) and x.hoja='Rutinas'),      '[]'::json),
    'Competencias', coalesce((select json_agg(x.datos || jsonb_build_object('id',x.id,'colaboradorId',x.colaborador_id)) from core.uno_a_uno_equipo_registros x where x.colaborador_id = any(v_ids) and x.hoja='Competencias'), '[]'::json),
    'PlanGerencial','[]'::json
  );
end $$;

-- 6. Guardar (solo el coordinador, solo su equipo) -------------------
-- Recibe la misma forma que la app manda a la hoja: hoja + lista de
-- registros. Regresa los registros con su id definitivo.
create or replace function core.uno_a_uno_equipo_guardar(p_hoja text, p_registros jsonb)
returns json
language plpgsql security definer
set search_path to 'core','public'
as $$
declare
  reg      jsonb;
  v_id     uuid;
  v_colab  uuid;
  v_datos  jsonb;
  v_perfil uuid;
  v_correo text;
  salida   jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or core.nivel_modulo('uno_a_uno') is null
     or not exists(select 1 from core.uno_a_uno_accesos where perfil_id = auth.uid() and coordina is not null) then
    raise exception 'Solo los coordinadores pueden capturar en su equipo';
  end if;

  for reg in select * from jsonb_array_elements(coalesce(p_registros,'[]'::jsonb)) loop
    v_id := nullif(reg->>'id','')::uuid;

    if p_hoja = 'Colaboradores' then
      -- Vínculo opcional con el usuario de la plataforma del ejecutivo
      v_correo := lower(trim(coalesce(reg->>'correoPlataforma','')));
      v_perfil := null;
      if v_correo <> '' then
        select id into v_perfil from core.perfiles where lower(correo) = v_correo and activo;
        if v_perfil is null then
          raise exception 'No hay un usuario activo de la plataforma con el correo %', v_correo;
        end if;
        if v_perfil = auth.uid() then
          raise exception 'No puedes vincularte a ti mismo como ejecutivo';
        end if;
        -- le da acceso de lectura al módulo para que vea su ficha
        insert into core.perfil_roles (perfil_id, rol) values (v_perfil, 'uno_a_uno') on conflict do nothing;
      end if;

      v_datos := (reg - 'id' - 'rol' - 'coordinadorId' - 'coordinador' - 'correoPlataforma' - 'clave')
                 || jsonb_build_object('rol','EJEC');

      if v_id is null then
        insert into core.uno_a_uno_equipo (coordinador_id, perfil_id, datos)
        values (auth.uid(), v_perfil, v_datos) returning id into v_id;
      else
        update core.uno_a_uno_equipo
           set datos = datos || v_datos,
               perfil_id = case when reg ? 'correoPlataforma' then v_perfil else perfil_id end,
               actualizado_en = now()
         where id = v_id and coordinador_id = auth.uid();
        if not found then raise exception 'Ese colaborador no es de tu equipo'; end if;
      end if;
      salida := salida || jsonb_build_array((v_datos || jsonb_build_object('id', v_id, 'correoPlataforma', nullif(v_correo,''))));

    elsif p_hoja in ('Sesiones','Acuerdos','KPIs','Desarrollo','Rutinas','Competencias') then
      v_colab := nullif(reg->>'colaboradorId','')::uuid;
      if v_colab is null or not exists(select 1 from core.uno_a_uno_equipo
                                        where id = v_colab and coordinador_id = auth.uid()) then
        raise exception 'Ese colaborador no es de tu equipo';
      end if;
      v_datos := reg - 'id';

      if v_id is null then
        insert into core.uno_a_uno_equipo_registros (coordinador_id, colaborador_id, hoja, datos)
        values (auth.uid(), v_colab, p_hoja, v_datos) returning id into v_id;
      else
        update core.uno_a_uno_equipo_registros
           set datos = datos || v_datos, colaborador_id = v_colab, actualizado_en = now()
         where id = v_id and coordinador_id = auth.uid() and hoja = p_hoja;
        if not found then raise exception 'No se encontró el registro en tu equipo'; end if;
      end if;
      salida := salida || jsonb_build_array(v_datos || jsonb_build_object('id', v_id));

    else
      raise exception 'Hoja no válida: %', p_hoja;
    end if;
  end loop;

  return salida::json;
end $$;

revoke all on function core.uno_a_uno_contexto()                 from public, anon;
revoke all on function core.uno_a_uno_equipo_leer(text)           from public, anon;
revoke all on function core.uno_a_uno_equipo_guardar(text, jsonb) from public, anon;
grant execute on function core.uno_a_uno_contexto()                 to authenticated;
grant execute on function core.uno_a_uno_equipo_leer(text)           to authenticated;
grant execute on function core.uno_a_uno_equipo_guardar(text, jsonb) to authenticated;
