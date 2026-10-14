-- Entradas y Salidas · 14-oct-2026
-- 1) No se aceptan movimientos a medio capturar (borradores), aunque un celular traiga la versión vieja.
-- 2) La entrada fija la ubicación que leen Inventario y el Mapa; el traspaso deja el equipo en tránsito.
--    Un movimiento que llega tarde (capturado sin señal) no pisa a otro más reciente.
-- 3) Si el Mapa o Inventario mueven el equipo, el patio físico de Entradas y Salidas lo sigue.
-- 4) completar_movimiento(): rellena los movimientos que llegaron vacíos con los datos reales del dispositivo.

alter table core.movimientos drop constraint if exists movimientos_completo;
alter table core.movimientos add constraint movimientos_completo check (
  tipo_mov not in ('entrada','salida','traspaso')
  or (tipo_mov = 'entrada'  and origen_tipo is not null)
  or (tipo_mov = 'salida'   and nullif(btrim(destino_nombre),'') is not null)
  or (tipo_mov = 'traspaso' and patio_destino_id is not null and patio_destino_id is distinct from patio_id)
) not valid;

create or replace function core.aplicar_movimiento()
 returns trigger language plpgsql security definer
as $function$
declare
  v_estatus text; v_contra text; v_patio smallint; a jsonb; v_tarde boolean;
begin
  v_contra := coalesce(case when new.tipo_mov = 'entrada' then new.origen_tipo else new.destino_tipo end, '*');
  select estatus_resultante into v_estatus from core.movimiento_estatus
   where tipo_mov = new.tipo_mov and contraparte_tipo = v_contra;
  if not found then
    select estatus_resultante into v_estatus from core.movimiento_estatus
     where tipo_mov = new.tipo_mov and contraparte_tipo = '*';
  end if;

  v_tarde := exists (select 1 from core.movimientos m
                     where m.equipo_id = new.equipo_id and m.id <> new.id
                       and m.tipo_mov in ('entrada','salida','traspaso') and m.fecha > new.fecha);

  v_patio := case when new.tipo_mov in ('salida','traspaso') then null else new.patio_id end;

  if not v_tarde then
    update core.equipos e set
      patio_fisico_id = case when new.tipo_mov = 'correccion' then e.patio_fisico_id else v_patio end,
      patio_id = case when new.tipo_mov in ('entrada','levantamiento') and new.patio_id is not null
                      then new.patio_id else e.patio_id end,
      estatus_operativo = coalesce(v_estatus, e.estatus_operativo),
      cliente_actual = case
          when new.tipo_mov = 'salida' and new.destino_tipo = 'Cliente' then new.destino_nombre
          when new.tipo_mov in ('entrada','levantamiento') then null
          else e.cliente_actual end,
      zona_id = coalesce(new.zona_id, e.zona_id),
      actualizado_en = now()
    where e.id = new.equipo_id;
  end if;

  insert into core.eventos_equipo (equipo_id, modulo, tipo, descripcion, datos, patio_id, registrado_por, ocurrido_en)
  values (new.equipo_id, 'movimientos', new.tipo_mov,
          concat_ws(' · ', initcap(new.tipo_mov),
                    (select nombre from core.patios where id = coalesce(new.patio_destino_id, new.patio_id)),
                    coalesce(new.origen_nombre, new.destino_nombre)),
          jsonb_build_object('movimiento_id', new.id, 'operador', new.operador,
                             'carta_porte', new.carta_porte, 'condicion', new.condicion,
                             'estatus_aplicado', case when v_tarde then null else v_estatus end,
                             'omitido_por_posterior', v_tarde),
          coalesce(new.patio_destino_id, new.patio_id), new.registrado_por, new.fecha);

  if not v_tarde and jsonb_array_length(coalesce(new.adicionales,'[]'::jsonb)) > 0 then
    delete from core.equipo_adicionales where equipo_id = new.equipo_id;
    for a in select * from jsonb_array_elements(new.adicionales) loop
      insert into core.equipo_adicionales (equipo_id, adicional_id, cantidad, actualizado_en)
      select new.equipo_id, c.id, coalesce((a->>'cantidad')::smallint, 1), new.fecha
      from core.catalogo_adicionales c
      where c.id = nullif(a->>'adicional_id','')::smallint or upper(c.nombre) = upper(a->>'nombre')
      limit 1 on conflict do nothing;
    end loop;
  end if;
  return new;
end $function$;

create or replace function core.fn_sync_patio_fisico()
 returns trigger language plpgsql
as $function$
begin
  if new.patio_id is distinct from old.patio_id
     and new.patio_fisico_id is not distinct from old.patio_fisico_id
     and old.patio_fisico_id is not null and new.patio_id is not null then
    new.patio_fisico_id := new.patio_id;
  end if;
  return new;
end $function$;
drop trigger if exists trg_sync_patio_fisico on core.equipos;
create trigger trg_sync_patio_fisico before update of patio_id on core.equipos
  for each row execute function core.fn_sync_patio_fisico();

create or replace function core.completar_movimiento(p jsonb)
 returns text language plpgsql security definer
 set search_path to 'core','public'
as $function$
declare v core.movimientos; r core.movimientos;
begin
  if not core.puede_escribir('movimientos') then raise exception 'Sin permiso de escritura en movimientos'; end if;
  v := jsonb_populate_record(null::core.movimientos, p);
  if v.id is null or v.equipo_id is null then raise exception 'Movimiento sin id o sin equipo'; end if;
  select * into r from core.movimientos where id = v.id;
  if found then
    if r.registrado_por is distinct from auth.uid() then return 'ajeno'; end if;
    if (r.tipo_mov = 'entrada'  and r.origen_tipo is not null)
    or (r.tipo_mov = 'salida'   and nullif(btrim(r.destino_nombre),'') is not null)
    or (r.tipo_mov = 'traspaso' and r.patio_destino_id is not null) then
      return 'ya_completo';
    end if;
    delete from core.movimientos where id = v.id;   -- se vuelve a registrar para recalcular Inventario y Mapa
    v.registrado_por := r.registrado_por;
  else
    v.registrado_por := auth.uid();
  end if;
  v.creado_en := coalesce(r.creado_en, now());
  v.adicionales := coalesce(v.adicionales, '[]'::jsonb);
  insert into core.movimientos select v.*;
  return case when r.id is null then 'insertado' else 'completado' end;
end $function$;
revoke all on function core.completar_movimiento(jsonb) from public, anon;
grant execute on function core.completar_movimiento(jsonb) to authenticated;
