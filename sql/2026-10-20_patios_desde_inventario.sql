-- 2026-10-20 · Patios de Entradas y Salidas = patios del Inventario
-- Entradas y Salidas (y Mapa, Taller, etc.) leen core.patios; el Inventario usa catalogos.tbl_ubicaciones.
-- Faltaban en core.patios: MONTERREY - BROKER HS, GALLEGOS, IRON LITE y VENTURA.
-- 1) Se dan de alta.  2) Se corrige el patio en core de los equipos que el Inventario tiene ahí.
-- 3) Trigger: toda ubicación nueva o reactivada en Inventario crea/activa su patio en core.patios.

-- 1) Alta de los patios faltantes (se enlazan por nombre vía core.patio_id)
insert into core.patios (clave, nombre, ciudad, estado, es_local, activo)
select v.clave, v.nombre, 'MONTERREY', 'NUEVO LEON', true, true
from (values ('MTY-BROKER-HS','MONTERREY - BROKER HS'),
             ('MTY-GALLEGOS','MONTERREY - GALLEGOS'),
             ('MTY-IRON-LITE','MONTERREY - IRON LITE'),
             ('MTY-VENTURA','MONTERREY - VENTURA')) v(clave, nombre)
where core.patio_id(v.nombre) is null;

-- 2) Equipos cuyo patio registrado en core no coincide con su ubicación de Inventario (solo estos patios nuevos)
update core.equipos c
   set patio_id = core.patio_id(u.nombre::text), actualizado_en = now()
  from inventario.tbl_equipos t
  join catalogos.tbl_ubicaciones u on u.id = t.ubicacion_id
 where upper(c.niv) = upper(t.niv::text)
   and u.nombre::text in ('MONTERREY - BROKER HS','MONTERREY - GALLEGOS','MONTERREY - IRON LITE','MONTERREY - VENTURA')
   and c.patio_id is distinct from core.patio_id(u.nombre::text);

-- 3) Enlace automático Inventario → core.patios
create or replace function catalogos.fn_ubicacion_a_patio()
returns trigger language plpgsql security definer
set search_path to 'core','catalogos','public' as $$
declare v_id smallint; v_clave text;
begin
  v_id := core.patio_id(new.nombre::text);
  if v_id is null then
    v_clave := left(regexp_replace(upper(core.normaliza_texto(new.nombre::text)), '[^A-Z0-9]+', '-', 'g'), 40);
    v_clave := trim(both '-' from v_clave);
    if exists (select 1 from core.patios where upper(clave) = v_clave) then
      v_clave := v_clave || '-' || substr(new.id::text, 1, 4);
    end if;
    insert into core.patios (clave, nombre, ciudad, es_local, activo)
    values (v_clave, upper(new.nombre::text),
            nullif(split_part(upper(new.nombre::text), ' - ', 1), ''), false, coalesce(new.activo, true));
  elsif coalesce(new.activo, true) then
    update core.patios set activo = true where id = v_id and not activo;
  end if;
  return new;
end $$;

drop trigger if exists zz_ubicacion_a_patio on catalogos.tbl_ubicaciones;
create trigger zz_ubicacion_a_patio
after insert or update of nombre, activo on catalogos.tbl_ubicaciones
for each row execute function catalogos.fn_ubicacion_a_patio();
