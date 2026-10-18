-- =====================================================================
-- Operaciones y taller · Modo prueba: parte que se pega en el SQL Editor
-- de Supabase (proyecto plataforma-ht). Lo demás del modo prueba ya está
-- aplicado. Este bloque:
--   1) quita los dos índices viejos (ya existen los nuevos que separan
--      pruebas de lo real), para que una orden de prueba nunca choque con
--      una real en la misma línea o el mismo equipo;
--   2) crea la función que borra los datos de prueba de quien la ejecuta.
-- =====================================================================
drop index if exists operaciones.ordenes_linea_ocupada;
drop index if exists operaciones.ordenes_equipo_abierta;

create or replace function operaciones.borrar_pruebas(p_todas boolean default false)
returns table(ordenes int, revisiones int, rutas text[])
language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare v_o uuid[]; v_r uuid[]; v_rutas text[];
begin
  if not core.puede_escribir('operaciones') and operaciones.mi_nivel_autorizacion() is null then raise exception 'Sin permiso'; end if;
  if p_todas and not core.es_admin() then raise exception 'Solo un administrador borra las pruebas de todos'; end if;
  select coalesce(array_agg(id), '{}') into v_o from operaciones.ordenes where es_prueba and (p_todas or creado_por = auth.uid());
  select coalesce(array_agg(id), '{}') into v_r from operaciones.revisiones where es_prueba and (p_todas or creado_por = auth.uid());
  select coalesce(array_agg(ruta), '{}') into v_rutas from (
    select ruta from operaciones.fotos_prueba where orden_id = any(v_o) or revision_id = any(v_r)
    union all
    select archivo_ruta from operaciones.cotizaciones where orden_id = any(v_o) and archivo_ruta like 'prueba/%') x;
  delete from operaciones.avisos where orden_id = any(v_o);
  delete from operaciones.fotos_prueba where orden_id = any(v_o) or revision_id = any(v_r);
  delete from operaciones.cotizaciones where orden_id = any(v_o);
  delete from operaciones.bitacora where orden_id = any(v_o);
  delete from operaciones.ordenes where id = any(v_o);
  update operaciones.ordenes set revision_id = null where revision_id = any(v_r);
  delete from operaciones.revisiones where id = any(v_r);
  return query select coalesce(array_length(v_o,1),0), coalesce(array_length(v_r,1),0), v_rutas;
end $$;
grant execute on function operaciones.borrar_pruebas(boolean) to authenticated;
notify pgrst, 'reload schema';
