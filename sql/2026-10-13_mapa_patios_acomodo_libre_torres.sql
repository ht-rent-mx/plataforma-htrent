-- =====================================================================
-- Mapa de patios · acomodo libre, orientación (H/V) y torres apiladas
-- Proyecto Supabase: plataforma-ht (ahfjstuwekcuxshclprl)
-- Correr UNA vez en SQL Editor ANTES de publicar el nuevo mapa-patios.html
-- =====================================================================
alter table core.equipos
  add column if not exists mapa_x numeric(7,2),
  add column if not exists mapa_y numeric(7,2),
  add column if not exists mapa_orientacion text not null default 'H',
  add column if not exists mapa_pila uuid,
  add column if not exists mapa_nivel smallint;
alter table core.equipos drop constraint if exists equipos_mapa_orientacion_chk;
alter table core.equipos add constraint equipos_mapa_orientacion_chk check (mapa_orientacion in ('H','V'));
create index if not exists equipos_mapa_pila_idx on core.equipos(mapa_pila) where mapa_pila is not null;

comment on column core.equipos.mapa_x is 'Mapa de patios: columna (en celdas) de la esquina superior izquierda; null = sin acomodar';
comment on column core.equipos.mapa_orientacion is 'Mapa de patios: H horizontal (4x2 celdas) o V vertical (2x4)';
comment on column core.equipos.mapa_pila is 'Mapa de patios: torre a la que pertenece (equipos apilados comparten el valor)';
comment on column core.equipos.mapa_nivel is 'Mapa de patios: nivel dentro de la torre (1 = abajo)';

-- Si otra app cambia el patio o el equipo sale de patio, se pierde el acomodo del plano
create or replace function core.fn_mapa_limpiar_acomodo() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('ht.acomodo', true),'') = '1' then return new; end if;
  if new.patio_id is distinct from old.patio_id
     or (new.estatus_operativo in ('ENTREGADO','RESIDUAL_PAGADO') and old.estatus_operativo is distinct from new.estatus_operativo) then
    new.mapa_x := null; new.mapa_y := null; new.mapa_pila := null; new.mapa_nivel := null;
  end if;
  return new;
end $$;
drop trigger if exists trg_mapa_limpiar_acomodo on core.equipos;
create trigger trg_mapa_limpiar_acomodo before update of patio_id, estatus_operativo on core.equipos
  for each row execute function core.fn_mapa_limpiar_acomodo();

-- Zona donde cae el centro de un equipo (huella H = 4x2 celdas, V = 2x4)
create or replace function core.mapa_zona_en(p_patio smallint, p_x numeric, p_y numeric, p_or text)
returns smallint language sql stable set search_path to 'core','public' as $$
  select z.id from core.zonas z
  where z.patio_id = p_patio and z.activo and p_x is not null
    and p_x + (case when p_or='V' then 1 else 2 end) >= z.x and p_x + (case when p_or='V' then 1 else 2 end) < z.x + z.ancho
    and p_y + (case when p_or='V' then 2 else 1 end) >= z.y and p_y + (case when p_or='V' then 2 else 1 end) < z.y + z.alto
  order by z.orden desc, z.id desc limit 1;
$$;

-- Coloca un equipo (o su torre completa) en el plano, o lo apila sobre otro
create or replace function core.acomodar_equipo(
  p_niv text, p_patio_id smallint, p_x numeric, p_y numeric,
  p_orientacion text default null, p_sobre_niv text default null, p_mover_pila boolean default true)
returns jsonb language plpgsql security definer set search_path to 'core','public' as $$
declare
  v core.equipos%rowtype; t core.equipos%rowtype;
  v_ids uuid[]; v_pila uuid; v_base smallint; v_or text; v_zona smallint; r record; i int := 0;
begin
  if not (core.es_admin() or core.puede_escribir('mapa_patios')) then
    raise exception 'No tienes permiso para acomodar equipos en el mapa';
  end if;
  select * into v from core.equipos where niv = p_niv;
  if v.id is null then raise exception 'NIV % no existe', p_niv; end if;
  if p_orientacion is not null and p_orientacion not in ('H','V') then raise exception 'Orientación no válida'; end if;

  if p_mover_pila and v.mapa_pila is not null then
    select array_agg(id order by mapa_nivel nulls last, niv) into v_ids from core.equipos where mapa_pila = v.mapa_pila;
  else
    v_ids := array[v.id];
  end if;

  perform set_config('ht.acomodo','1', true);

  -- apilar sobre otro equipo
  if p_sobre_niv is not null then
    select * into t from core.equipos where niv = p_sobre_niv;
    if t.id is null then raise exception 'NIV % no existe', p_sobre_niv; end if;
    if t.id = any(v_ids) then raise exception 'No se puede apilar un equipo sobre sí mismo'; end if;
    -- si una sola unidad sale de su torre para subirse a otra, renumera la que deja
    if not p_mover_pila and v.mapa_pila is not null then
      update core.equipos set mapa_pila = null, mapa_nivel = null where id = v.id;
      with q as (select id, row_number() over (order by mapa_nivel, niv) n, count(*) over () c from core.equipos where mapa_pila = v.mapa_pila)
      update core.equipos e set mapa_nivel = case when q.c = 1 then null else q.n end,
                                mapa_pila  = case when q.c = 1 then null else e.mapa_pila end
      from q where e.id = q.id;
    end if;
    v_pila := coalesce(t.mapa_pila, gen_random_uuid());
    if t.mapa_pila is null then update core.equipos set mapa_pila = v_pila, mapa_nivel = 1 where id = t.id; end if;
    select coalesce(max(mapa_nivel),1) into v_base from core.equipos where mapa_pila = v_pila;
    for r in select e.* from unnest(v_ids) with ordinality u(id, o) join core.equipos e on e.id = u.id order by u.o loop
      i := i + 1;
      if r.patio_id is distinct from t.patio_id or r.zona_id is distinct from t.zona_id then
        perform core.mover_equipo(r.niv, t.patio_id, t.zona_id);
      end if;
      update core.equipos set mapa_x = t.mapa_x, mapa_y = t.mapa_y, mapa_orientacion = t.mapa_orientacion,
        mapa_pila = v_pila, mapa_nivel = v_base + i where id = r.id;
      insert into core.eventos_equipo (equipo_id, modulo, tipo, descripcion, datos, patio_id, registrado_por)
      values (r.id, 'mapa_patios', 'apilado', 'Apilado sobre ' || t.niv || ' (nivel ' || (v_base + i) || ')',
              jsonb_build_object('pila', v_pila, 'sobre', t.niv, 'nivel', v_base + i), t.patio_id, auth.uid());
    end loop;
    return jsonb_build_object('pila', v_pila, 'patio', t.patio_id, 'zona', t.zona_id);
  end if;

  -- colocación libre
  v_or := coalesce(p_orientacion, v.mapa_orientacion, 'H');
  v_zona := core.mapa_zona_en(p_patio_id, p_x, p_y, v_or);
  if not p_mover_pila and v.mapa_pila is not null then
    update core.equipos set mapa_pila = null, mapa_nivel = null where id = v.id;
    insert into core.eventos_equipo (equipo_id, modulo, tipo, descripcion, datos, patio_id, registrado_por)
    values (v.id, 'mapa_patios', 'desapilado', 'Bajado de la torre', jsonb_build_object('pila', v.mapa_pila), v.patio_id, auth.uid());
    with q as (select id, row_number() over (order by mapa_nivel, niv) n, count(*) over () c from core.equipos where mapa_pila = v.mapa_pila)
    update core.equipos e set mapa_nivel = case when q.c = 1 then null else q.n end,
                              mapa_pila  = case when q.c = 1 then null else e.mapa_pila end
    from q where e.id = q.id;
  end if;
  for r in select e.* from core.equipos e where e.id = any(v_ids) loop
    if r.patio_id is distinct from p_patio_id or r.zona_id is distinct from v_zona then
      perform core.mover_equipo(r.niv, p_patio_id, v_zona);
    end if;
    update core.equipos set mapa_x = p_x, mapa_y = p_y, mapa_orientacion = v_or where id = r.id;
  end loop;
  return jsonb_build_object('patio', p_patio_id, 'zona', v_zona, 'pila', case when p_mover_pila then v.mapa_pila end);
end $$;

-- Reordena los niveles de una torre (el primero del arreglo queda abajo)
create or replace function core.ordenar_pila(p_pila uuid, p_nivs text[])
returns void language plpgsql security definer set search_path to 'core','public' as $$
begin
  if not (core.es_admin() or core.puede_escribir('mapa_patios')) then
    raise exception 'No tienes permiso para acomodar equipos en el mapa';
  end if;
  update core.equipos e set mapa_nivel = u.o
  from unnest(p_nivs) with ordinality u(niv, o)
  where e.niv = u.niv and e.mapa_pila = p_pila;
end $$;

-- Tras mover o redimensionar zonas, recalcula la zona de los equipos ya acomodados
create or replace function core.mapa_recalcular_zonas(p_patio_id smallint)
returns integer language plpgsql security definer set search_path to 'core','public' as $$
declare n integer;
begin
  if not (core.es_admin() or core.puede_escribir('mapa_patios')) then
    raise exception 'No tienes permiso para modificar el plano';
  end if;
  update core.equipos e set zona_id = core.mapa_zona_en(p_patio_id, e.mapa_x, e.mapa_y, e.mapa_orientacion)
  where e.patio_id = p_patio_id and e.mapa_x is not null
    and e.zona_id is distinct from core.mapa_zona_en(p_patio_id, e.mapa_x, e.mapa_y, e.mapa_orientacion);
  get diagnostics n = row_count; return n;
end $$;

revoke execute on function core.acomodar_equipo(text, smallint, numeric, numeric, text, text, boolean) from public, anon;
revoke execute on function core.ordenar_pila(uuid, text[]) from public, anon;
revoke execute on function core.mapa_recalcular_zonas(smallint) from public, anon;
grant execute on function core.acomodar_equipo(text, smallint, numeric, numeric, text, text, boolean) to authenticated;
grant execute on function core.ordenar_pila(uuid, text[]) to authenticated;
grant execute on function core.mapa_recalcular_zonas(smallint) to authenticated;
grant execute on function core.mapa_zona_en(smallint, numeric, numeric, text) to authenticated;
