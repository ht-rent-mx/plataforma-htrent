-- =====================================================================
-- Plataforma HT · Módulo de Administración (2026-10-18)
-- Funciones que usa admin.html. Todas validan core.es_admin():
-- quien no tenga el rol admin activo recibe un error y no ve nada.
-- =====================================================================

-- Lista de usuarios con su último acceso, roles y patios
create or replace function core.admin_usuarios()
returns table (
  id uuid, nombre text, puesto text, correo text, activo boolean,
  creado_en timestamptz, ultimo_acceso timestamptz,
  roles text[], patios smallint[]
)
language plpgsql stable security definer
set search_path to 'core','public'
as $$
begin
  if not core.es_admin() then
    raise exception 'Solo un administrador puede ver esta información';
  end if;
  return query
  select p.id, p.nombre, p.puesto, p.correo, p.activo,
         coalesce(u.created_at, p.creado_en), u.last_sign_in_at,
         coalesce((select array_agg(pr.rol order by pr.rol) from core.perfil_roles pr where pr.perfil_id = p.id), '{}'),
         coalesce((select array_agg(pp.patio_id order by pp.patio_id) from core.perfil_patios pp where pp.perfil_id = p.id), '{}')
  from core.perfiles p
  left join auth.users u on u.id = p.id
  order by p.activo desc, p.nombre;
end $$;

-- Guarda datos, roles y patios de un usuario en un solo paso
create or replace function core.admin_guardar_usuario(
  p_id uuid, p_nombre text, p_puesto text, p_activo boolean,
  p_roles text[], p_patios smallint[]
) returns void
language plpgsql security definer
set search_path to 'core','public'
as $$
declare n_inv int;
begin
  if not core.es_admin() then
    raise exception 'Solo un administrador puede hacer cambios';
  end if;
  if not exists (select 1 from core.perfiles where id = p_id) then
    raise exception 'El usuario no existe';
  end if;
  if p_id = auth.uid() and (not p_activo or not ('admin' = any(coalesce(p_roles,'{}')))) then
    raise exception 'No puedes quitarte el rol de administrador ni desactivarte a ti mismo';
  end if;
  select count(*) into n_inv from unnest(coalesce(p_roles,'{}')) r where r like 'inventario\_%';
  if n_inv > 1 then
    raise exception 'Solo se permite un rol de Inventario por usuario';
  end if;

  update core.perfiles
     set nombre = nullif(trim(p_nombre),''), puesto = nullif(trim(p_puesto),''), activo = p_activo
   where id = p_id;

  delete from core.perfil_roles where perfil_id = p_id;
  insert into core.perfil_roles (perfil_id, rol)
  select p_id, r from unnest(coalesce(p_roles,'{}')) r
  where r in (select clave from core.roles)
  on conflict do nothing;

  delete from core.perfil_patios where perfil_id = p_id;
  insert into core.perfil_patios (perfil_id, patio_id)
  select p_id, x from unnest(coalesce(p_patios,'{}')) x
  where x in (select id from core.patios)
  on conflict do nothing;
end $$;

-- Cambia el nivel de un módulo para un rol ('lectura','escritura','admin' o null para quitarlo)
create or replace function core.admin_nivel_rol(p_rol text, p_modulo text, p_nivel text)
returns void
language plpgsql security definer
set search_path to 'core','public'
as $$
begin
  if not core.es_admin() then
    raise exception 'Solo un administrador puede hacer cambios';
  end if;
  if p_rol = 'admin' and p_modulo = 'admin' then
    raise exception 'El acceso del rol Administrador a este módulo no se puede cambiar';
  end if;
  if p_nivel is not null and p_nivel not in ('lectura','escritura','admin') then
    raise exception 'Nivel no válido';
  end if;
  delete from core.rol_modulos where rol = p_rol and modulo = p_modulo;
  if p_nivel is not null then
    insert into core.rol_modulos (rol, modulo, nivel) values (p_rol, p_modulo, p_nivel);
  end if;
end $$;

revoke all on function core.admin_usuarios() from public, anon;
revoke all on function core.admin_guardar_usuario(uuid,text,text,boolean,text[],smallint[]) from public, anon;
revoke all on function core.admin_nivel_rol(text,text,text) from public, anon;
grant execute on function core.admin_usuarios() to authenticated;
grant execute on function core.admin_guardar_usuario(uuid,text,text,boolean,text[],smallint[]) to authenticated;
grant execute on function core.admin_nivel_rol(text,text,text) to authenticated;
