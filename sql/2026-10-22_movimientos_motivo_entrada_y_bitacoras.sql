-- =====================================================================
-- Entradas y Salidas  →  Inventario (pestañas INV, Entregas y Devoluciones)
-- 22-oct-2026
--
-- 1. core.movimientos gana el MOTIVO de la entrada y, para devoluciones,
--    quién avisó y el motivo de la devolución (mismos catálogos que usa
--    la pestaña Devoluciones de Inventario).
-- 2. core.catalogos_entrada(): lista de "quién avisó" y motivos para la app.
-- 3. core.fn_movimiento_a_inventario() reescrita:
--    · Salida a cliente de un equipo ASIGNADO  → se registra en Entregas
--      (movimientos.tbl_entregas) y su disparador lo deja ENTREGADO.
--      Pierde la marca de "Entrega inmediata".
--    · Entrada por DEVOLUCIÓN de un equipo ENTREGADO → se registra en
--      Devoluciones (movimientos.tbl_devoluciones) y su disparador lo deja
--      LIBRE / PENDIENTE (NUEVO → RECUPERADO) en el patio que lo recibe.
--    · Entrada por traspaso, taller, fabricante, servicio u otro → solo
--      cambia la ubicación (y si venía EN TRÁNSITO recupera su estatus).
--    · Traspaso o salida a otro patio / taller → EN TRÁNSITO.
--    Si el equipo no está en el estatus que pide la bitácora, se aplica el
--    cambio directo y queda una alerta en el historial del equipo.
-- =====================================================================

alter table core.movimientos
  add column if not exists motivo_entrada       text,
  add column if not exists motivo_devolucion_id uuid references catalogos.tbl_motivos_devolucion(id),
  add column if not exists quien_informa_id     uuid references catalogos.tbl_asesores(id);

alter table core.movimientos drop constraint if exists movimientos_motivo_entrada_check;
alter table core.movimientos add constraint movimientos_motivo_entrada_check
  check (motivo_entrada is null or motivo_entrada in ('DEVOLUCION','TRASPASO','NUEVO','TALLER','SERVICIO','OTRO'));

comment on column core.movimientos.motivo_entrada is
  'Razón de la entrada: DEVOLUCION (cliente regresa el equipo), TRASPASO (llega de otro patio), NUEVO (de fabricante), TALLER (regresa de reparación), SERVICIO (equipo de cliente que entra a revisión y sigue con él), OTRO';

-- ---------------------------------------------------------------------
create or replace function core.catalogos_entrada()
returns jsonb
language sql stable security definer
set search_path to 'catalogos', 'public'
as $$
  select jsonb_build_object(
    'quien_informa', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'nombre', a.nombre::text) order by a.nombre::text)
                                 from catalogos.tbl_asesores a
                                where coalesce(a.activo, true) and a.nombre::text <> 'PENDIENTE'), '[]'::jsonb),
    'motivos_devolucion', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'nombre', m.nombre::text) order by m.nombre::text)
                                      from catalogos.tbl_motivos_devolucion m), '[]'::jsonb)
  );
$$;
revoke all on function core.catalogos_entrada() from public, anon;
grant execute on function core.catalogos_entrada() to authenticated;

-- ---------------------------------------------------------------------
create or replace function core.fn_movimiento_a_inventario()
returns trigger
language plpgsql
security definer
set search_path to 'core', 'inventario', 'catalogos', 'public'
as $function$
declare
  t            inventario.tbl_equipos%rowtype;
  v_niv        text;
  v_asig       text;
  v_ent        text;
  v_cond       text;
  v_ubic       uuid;
  v_motivo     text;
  v_ent_nuevo  text;
  v_asig_nuevo text;
  v_cond_nueva text;
  v_dev        boolean := false;   -- devolución aplicada de forma directa
  v_bitacora   text;               -- 'ENTREGAS' / 'DEVOLUCIONES' si se registró en la pestaña
  v_previa     text;
  v_alerta     text;
  v_ent_id     uuid;
  v_asig_id    uuid;
  v_cond_id    uuid;
  v_tv_pend    uuid;
  v_ac_pend    uuid;
  v_antes      jsonb;
  v_despues    jsonb;
  v_hay        boolean;
  v_fecha      date;
begin
  if new.tipo_mov not in ('entrada','salida','traspaso') then
    return new;
  end if;

  begin
    v_fecha := (new.fecha at time zone 'America/Mexico_City')::date;
    select upper(niv) into v_niv from core.equipos where id = new.equipo_id;
    select * into t from inventario.tbl_equipos where upper(niv::text) = v_niv limit 1;

    if t.id is null then
      insert into core.eventos_equipo(equipo_id, modulo, tipo, descripcion, datos, patio_id, registrado_por, ocurrido_en)
      values (new.equipo_id, 'movimientos', 'INVENTARIO_SIN_EQUIPO', 'El NIV no existe en Inventario; no se actualizó',
              jsonb_build_object('movimiento_id', new.id),
              coalesce(new.patio_destino_id, new.patio_id), new.registrado_por, new.fecha);
      return new;
    end if;

    -- Un movimiento con fecha anterior a otro ya registrado no pisa el estado actual
    if exists (select 1 from core.movimientos m
               where m.equipo_id = new.equipo_id and m.id <> new.id
                 and m.tipo_mov in ('entrada','salida','traspaso') and m.fecha > new.fecha) then
      insert into core.eventos_equipo(equipo_id, modulo, tipo, descripcion, datos, patio_id, registrado_por, ocurrido_en)
      values (new.equipo_id, 'movimientos', 'INVENTARIO_OMITIDO',
              'Movimiento con fecha anterior a otro ya registrado; Inventario no se modificó',
              jsonb_build_object('movimiento_id', new.id, 'tipo_mov', new.tipo_mov),
              coalesce(new.patio_destino_id, new.patio_id), new.registrado_por, new.fecha);
      return new;
    end if;

    select ea.nombre::text into v_asig from catalogos.tbl_estatus_asignacion ea where ea.id = t.estatus_asignacion_id;
    select ee.nombre::text into v_ent  from catalogos.tbl_estatus_entrega    ee where ee.id = t.estatus_entrega_id;
    select co.nombre::text into v_cond from catalogos.tbl_condiciones        co where co.id = t.condicion_id;

    v_antes := jsonb_build_object(
      'ubicacion', (select u.nombre::text from catalogos.tbl_ubicaciones u where u.id = t.ubicacion_id),
      'estatus_asignacion', v_asig, 'estatus_entrega', v_ent, 'condicion', v_cond,
      'cliente', t.cliente_asignado);

    -- =========================== ENTRADA ===========================
    if new.tipo_mov = 'entrada' then
      select u.id into v_ubic from catalogos.tbl_ubicaciones u
       where core.patio_id(u.nombre::text) = new.patio_id order by u.activo desc limit 1;
      if v_ubic is null then v_alerta := 'El patio no tiene ubicación equivalente en Inventario'; end if;

      -- Motivo capturado; las versiones anteriores de la app no lo mandan
      v_motivo := coalesce(new.motivo_entrada,
                    case when v_asig ilike 'ASIGNADO%' and v_ent = 'ENTREGADO'
                              and coalesce(new.origen_tipo,'Sin especificar') in ('Cliente','Sin especificar')
                         then 'DEVOLUCION'
                         when new.origen_tipo = 'Otro patio' then 'TRASPASO'
                         when new.origen_tipo = 'Taller'     then 'TALLER'
                         when new.origen_tipo = 'Fabricante' then 'NUEVO'
                         else 'OTRO' end);

      if v_motivo = 'DEVOLUCION' then
        if v_ent = 'ENTREGADO' then
          -- Se registra en la pestaña Devoluciones; su disparador libera el equipo
          begin
            insert into movimientos.tbl_devoluciones
              (equipo_id, fecha, cliente_asignado, folio_venta, motivo_id, patio_id, created_by, quien_informa_id)
            values
              (t.id, v_fecha, coalesce(t.cliente_asignado, nullif(btrim(new.origen_nombre),'')), t.folio_venta,
               coalesce(new.motivo_devolucion_id,
                        (select id from catalogos.tbl_motivos_devolucion where nombre::text = 'DEVOLUCION')),
               coalesce(v_ubic, t.ubicacion_id), new.registrado_por, new.quien_informa_id);
            v_bitacora := 'DEVOLUCIONES';
          exception when others then
            v_alerta := 'No se pudo registrar en Devoluciones (' || sqlerrm || '); se liberó directo';
            v_dev := true;
          end;
        elsif v_asig ilike 'ASIGNADO%' then
          v_dev := true;
          v_alerta := 'Devolución de un equipo que en Inventario no estaba ENTREGADO (' || coalesce(v_ent,'sin estatus')
                      || '); se liberó pero no se agregó a Devoluciones';
        else
          v_alerta := 'Se recibió como devolución, pero en Inventario ya estaba ' || coalesce(v_asig,'sin estatus')
                      || '; solo se actualizó la ubicación';
        end if;

        if v_dev then
          v_asig_nuevo := 'LIBRE';
          v_ent_nuevo  := 'PENDIENTE';
          if v_cond = 'NUEVO' then v_cond_nueva := 'RECUPERADO'; end if;
        end if;

      elsif v_ent = 'EN TRANSITO' then
        -- Llega un equipo que venía en tránsito: recupera el estatus de entrega previo al traslado
        select datos->>'entrega_previa' into v_previa from core.eventos_equipo
         where equipo_id = new.equipo_id and modulo = 'movimientos' and tipo = 'INVENTARIO_ACTUALIZADO'
           and datos->>'entrega_nueva' = 'EN TRANSITO'
           and datos->>'entrega_previa' is distinct from 'EN TRANSITO'
         order by ocurrido_en desc, id desc limit 1;
        v_ent_nuevo := case when v_previa is null or v_previa = 'EN TRANSITO' then 'PENDIENTE' else v_previa end;
      end if;

    -- =========================== TRASPASO ==========================
    elsif new.tipo_mov = 'traspaso' then
      if v_ent is distinct from 'EN TRANSITO' then v_ent_nuevo := 'EN TRANSITO'; end if;

    -- ============================ SALIDA ===========================
    else
      v_ent_nuevo := case coalesce(new.destino_tipo, 'Sin especificar')
                       when 'Cliente'         then 'ENTREGADO'
                       when 'Sin especificar' then 'ENTREGADO'
                       when 'Otro patio'      then 'EN TRANSITO'
                       when 'Taller'          then 'EN TRANSITO'
                       when 'Subasta'         then 'SUBASTA RB'
                       else null end;

      if v_ent_nuevo = 'ENTREGADO' then
        if v_ent = 'ENTREGADO' then
          v_ent_nuevo := null;                  -- ya estaba entregado: no se duplica en Entregas
        elsif v_asig ilike 'ASIGNADO%' then
          -- Se registra en la pestaña Entregas; su disparador lo deja ENTREGADO
          begin
            insert into movimientos.tbl_entregas
              (equipo_id, fecha, cliente_asignado, folio_venta, area_comercial_id, asesor_id, patio_id, created_by)
            values
              (t.id, v_fecha, coalesce(t.cliente_asignado, nullif(btrim(new.destino_nombre),'')), t.folio_venta,
               t.area_comercial_id, t.asesor_id, t.ubicacion_id, new.registrado_por);
            v_bitacora  := 'ENTREGAS';
            v_ent_nuevo := null;
          exception when others then
            v_alerta := 'No se pudo registrar en Entregas (' || sqlerrm || '); se marcó ENTREGADO directo';
          end;
        else
          v_alerta := 'Salida a cliente de un equipo que en Inventario no está ASIGNADO (' || coalesce(v_asig,'sin estatus')
                      || '); se marcó ENTREGADO pero no se agregó a Entregas';
        end if;
      elsif v_ent_nuevo is not distinct from v_ent then
        v_ent_nuevo := null;
      end if;
    end if;

    -- ===================== aplicar lo que falte =====================
    if v_ent_nuevo  is not null then select id into v_ent_id  from catalogos.tbl_estatus_entrega    where nombre::text = v_ent_nuevo;  end if;
    if v_asig_nuevo is not null then select id into v_asig_id from catalogos.tbl_estatus_asignacion where nombre::text = v_asig_nuevo; end if;
    if v_cond_nueva is not null then select id into v_cond_id from catalogos.tbl_condiciones        where nombre::text = v_cond_nueva; end if;
    if v_dev then
      select id into v_tv_pend from catalogos.tbl_tipos_venta       where nombre::text = 'PENDIENTE';
      select id into v_ac_pend from catalogos.tbl_areas_comerciales where nombre::text = 'PENDIENTE';
    end if;

    -- relee el equipo por si la bitácora ya lo cambió
    select * into t from inventario.tbl_equipos where id = t.id;

    v_hay := v_bitacora is not null or v_dev
          or (v_ubic is not null and new.tipo_mov = 'entrada' and v_ubic is distinct from t.ubicacion_id)
          or (v_ent_id  is not null and v_ent_id  is distinct from t.estatus_entrega_id)
          or (v_asig_id is not null and v_asig_id is distinct from t.estatus_asignacion_id)
          or (v_cond_id is not null and v_cond_id is distinct from t.condicion_id);

    if not v_hay then
      if v_alerta is not null then
        insert into core.eventos_equipo(equipo_id, modulo, tipo, descripcion, datos, patio_id, registrado_por, ocurrido_en)
        values (new.equipo_id, 'movimientos', 'INVENTARIO_ALERTA', v_alerta,
                jsonb_build_object('movimiento_id', new.id, 'tipo_mov', new.tipo_mov, 'motivo', v_motivo),
                coalesce(new.patio_destino_id, new.patio_id), new.registrado_por, new.fecha);
      end if;
      return new;
    end if;

    update inventario.tbl_equipos set
      ubicacion_id          = case when new.tipo_mov = 'entrada' then coalesce(v_ubic, ubicacion_id) else ubicacion_id end,
      estatus_asignacion_id = coalesce(v_asig_id, estatus_asignacion_id),
      estatus_entrega_id    = coalesce(v_ent_id, estatus_entrega_id),
      condicion_id          = coalesce(v_cond_id, condicion_id),
      cliente_asignado      = case when v_dev then null else cliente_asignado end,
      folio_venta           = case when v_dev then null else folio_venta end,
      fecha_venta           = case when v_dev then null else fecha_venta end,
      tipo_venta_id         = case when v_dev then coalesce(v_tv_pend, tipo_venta_id) else tipo_venta_id end,
      area_comercial_id     = case when v_dev then coalesce(v_ac_pend, area_comercial_id) else area_comercial_id end,
      asesor_id             = case when v_dev then null else asesor_id end,
      entrega_inmediata     = case when v_bitacora = 'ENTREGAS' or v_ent_nuevo = 'ENTREGADO' then false else entrega_inmediata end
    where id = t.id;

    select jsonb_build_object('ubicacion', u.nombre::text, 'estatus_asignacion', ea.nombre::text,
                              'estatus_entrega', ee.nombre::text, 'condicion', co.nombre::text, 'cliente', x.cliente_asignado)
      into v_despues
    from inventario.tbl_equipos x
    left join catalogos.tbl_ubicaciones        u  on u.id  = x.ubicacion_id
    left join catalogos.tbl_estatus_asignacion ea on ea.id = x.estatus_asignacion_id
    left join catalogos.tbl_estatus_entrega    ee on ee.id = x.estatus_entrega_id
    left join catalogos.tbl_condiciones        co on co.id = x.condicion_id
    where x.id = t.id;

    insert into core.eventos_equipo(equipo_id, modulo, tipo, descripcion, datos, patio_id, registrado_por, ocurrido_en)
    values (new.equipo_id, 'movimientos', 'INVENTARIO_ACTUALIZADO',
            case when v_bitacora = 'DEVOLUCIONES' then 'Devolución recibida en patio: registrada en Devoluciones y equipo liberado'
                 when v_bitacora = 'ENTREGAS'     then 'Salida a cliente: registrada en Entregas y equipo ENTREGADO'
                 when v_dev then 'Devolución recibida en patio: equipo liberado en Inventario'
                 else initcap(new.tipo_mov) || ' registrada: Inventario actualizado' end,
            jsonb_build_object('movimiento_id', new.id, 'tipo_mov', new.tipo_mov, 'motivo', v_motivo,
                               'antes', v_antes, 'despues', v_despues, 'bitacora', v_bitacora,
                               'entrega_previa', v_antes->>'estatus_entrega', 'entrega_nueva', v_despues->>'estatus_entrega',
                               'devolucion', (v_dev or v_bitacora = 'DEVOLUCIONES'), 'alerta', v_alerta),
            coalesce(new.patio_destino_id, new.patio_id), new.registrado_por, new.fecha);

  exception when others then
    -- Un fallo aquí nunca debe impedir que se guarde el movimiento en patio
    insert into core.eventos_equipo(equipo_id, modulo, tipo, descripcion, datos, patio_id, registrado_por, ocurrido_en)
    values (new.equipo_id, 'movimientos', 'INVENTARIO_ERROR', 'No se pudo actualizar Inventario: ' || sqlerrm,
            jsonb_build_object('movimiento_id', new.id, 'sqlstate', sqlstate),
            coalesce(new.patio_destino_id, new.patio_id), new.registrado_por, new.fecha);
  end;

  return new;
end
$function$;
