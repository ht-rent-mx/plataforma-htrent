-- =====================================================================
-- Plataforma HT · Módulo Interacciones 1 a 1 (2026-10-20)
--
-- Qué hace:
--   1. Da de alta el módulo "uno_a_uno" y el rol "uno_a_uno" (colaborador).
--   2. Solo entran: Rogelio Morejón (admin) y los 4 colaboradores
--      Brayan López, Jésica Gutiérrez, César (Noé) Cruz y Norma Martínez.
--   3. La app sigue usando su hoja de Google (1a1_HTRENT) como base de datos.
--      La plataforma guarda, en una tabla que nadie puede leer directamente,
--      qué colaborador (C1..C4 / ADMIN) es cada usuario y su clave interna.
--      Al entrar con el correo y contraseña de la plataforma, la función
--      core.uno_a_uno_mi_acceso() le entrega esa clave SOLO a su dueño.
--   4. Doble candado: aunque alguien le diera el módulo a otro rol desde
--      Administración, sin renglón en core.uno_a_uno_accesos no entra.
--
-- Cómo correrlo: Supabase > SQL Editor > pegar todo > Run.
-- Se puede correr más de una vez sin dañar nada.
-- =====================================================================

-- 1. Módulo y rol ------------------------------------------------------
insert into core.modulos (clave, nombre, orden)
values ('uno_a_uno', 'Interacciones 1 a 1', 100)
on conflict (clave) do update set nombre = excluded.nombre;

insert into core.roles (clave, nombre)
values ('uno_a_uno', 'Interacciones 1 a 1 · Colaborador')
on conflict (clave) do update set nombre = excluded.nombre;

delete from core.rol_modulos where modulo = 'uno_a_uno';
insert into core.rol_modulos (rol, modulo, nivel) values
  ('admin',     'uno_a_uno', 'admin'),
  ('uno_a_uno', 'uno_a_uno', 'lectura');

-- 2. Vínculo usuario de plataforma -> colaborador de la hoja -----------
create table if not exists core.uno_a_uno_accesos (
  perfil_id      uuid primary key references core.perfiles(id) on delete cascade,
  colaborador_id text not null unique,     -- C1..C4 o ADMIN (columna "id" de la hoja)
  clave          text not null,            -- columna "clave" de la hoja
  actualizado    timestamptz not null default now()
);
alter table core.uno_a_uno_accesos enable row level security;
revoke all on core.uno_a_uno_accesos from public, anon, authenticated;

-- (los valores de clave se cargan aparte, ver bloque 4)

-- 3. Funciones ---------------------------------------------------------
-- Entrega al usuario conectado su id de colaborador y su clave interna
create or replace function core.uno_a_uno_mi_acceso()
returns json
language plpgsql stable security definer
set search_path to 'core','public'
as $$
declare r core.uno_a_uno_accesos;
begin
  if auth.uid() is null or core.nivel_modulo('uno_a_uno') is null then
    raise exception 'No tienes acceso a Interacciones 1 a 1';
  end if;
  select * into r from core.uno_a_uno_accesos where perfil_id = auth.uid();
  if not found then
    raise exception 'Tu usuario no está vinculado a Interacciones 1 a 1. Pídele a Roger que te dé de alta.';
  end if;
  return json_build_object('colaboradorId', r.colaborador_id, 'clave', r.clave);
end $$;

-- Cuando el administrador cambia una clave en la app, se actualiza aquí
create or replace function core.uno_a_uno_guardar_clave(p_colaborador text, p_clave text)
returns void
language plpgsql security definer
set search_path to 'core','public'
as $$
begin
  if not core.es_admin() then
    raise exception 'Solo un administrador puede cambiar claves';
  end if;
  if coalesce(trim(p_clave),'') = '' then return; end if;
  update core.uno_a_uno_accesos
     set clave = trim(p_clave), actualizado = now()
   where colaborador_id = p_colaborador;
end $$;

revoke all on function core.uno_a_uno_mi_acceso() from public, anon;
revoke all on function core.uno_a_uno_guardar_clave(text,text) from public, anon;
grant execute on function core.uno_a_uno_mi_acceso() to authenticated;
grant execute on function core.uno_a_uno_guardar_clave(text,text) to authenticated;

-- 4. Alta de las 5 personas -------------------------------------------
-- Las claves se cargaron directamente en la base (no se guardan en este
-- archivo porque el repositorio es público). Para volver a cargarlas:
--   insert into core.uno_a_uno_accesos (perfil_id, colaborador_id, clave)
--   select id, 'C1', '<clave de la hoja>' from core.perfiles where correo = 'jesica.gutierrez@htrent.mx'
--   on conflict (perfil_id) do update set colaborador_id = excluded.colaborador_id, clave = excluded.clave;

insert into core.perfil_roles (perfil_id, rol)
select id, 'uno_a_uno' from core.perfiles
where correo in ('brayan.lopez@htrent.mx','jesica.gutierrez@htrent.mx',
                 'noe.cruz@htrent.mx','norma.martinez@htrent.mx')
on conflict do nothing;
