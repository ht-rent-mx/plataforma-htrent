-- ENSAYO v2 (no guarda nada): pega TODO en el SQL Editor de Supabase y ejecuta.
-- Termina con un error 'ENSAYO_OK {...}' a propósito: así Postgres deshace todo. Copia ese texto y pásaselo a Claude.
begin;
-- ---------------------------------------------------------------- corrección de seguridad
-- core.puede_escribir() devolvía NULL (no false) a quien no tiene el rol, y en
-- funciones con "if not core.puede_escribir(...) then raise" un NULL NO rechaza.
-- Afectaba a crear_orden, cambiar_estatus, agregar_cotizacion, comentar,
-- enviar_factura, borrar_pruebas y core.completar_movimiento. En políticas RLS
-- NULL y false se comportan igual, así que el cambio solo cierra el hueco.
create or replace function core.puede_escribir(p_modulo text) returns boolean
language sql stable as $$ select coalesce(core.nivel_modulo(p_modulo) in ('escritura','admin'), false); $$;

-- ---------------------------------------------------------------- módulo y rol
insert into core.modulos(clave, nombre, orden) values ('taller', 'Taller · avance de unidades', 4)
on conflict (clave) do nothing;
insert into core.roles(clave, nombre) values ('mecanico', 'Mecánico / personal de taller')
on conflict (clave) do nothing;
insert into core.rol_modulos(rol, modulo, nivel) values
  ('mecanico','taller','escritura'),
  ('taller','taller','escritura'),
  ('operaciones','taller','escritura'),
  ('admin','taller','admin'),
  ('operaciones_consulta','taller','lectura'),
  ('consulta_general','taller','lectura'),
  ('servicio_clientes','taller','lectura'),
  ('mecanico','salas','escritura')
on conflict (rol, modulo) do nothing;

-- ---------------------------------------------------------------- tareas
create table if not exists operaciones.orden_tareas(
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references operaciones.ordenes(id) on delete cascade,
  posicion smallint not null default 1,
  descripcion text not null check (length(trim(descripcion)) > 0),
  mecanico_id uuid references core.perfiles(id),
  horas_estimadas numeric(5,1),
  estatus text not null default 'pendiente' check (estatus in ('pendiente','en_curso','hecha','detenida')),
  nota text,
  iniciada_en timestamptz,
  terminada_en timestamptz,
  terminada_por uuid references core.perfiles(id),
  creado_por uuid not null default auth.uid() references core.perfiles(id),
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index if not exists orden_tareas_orden on operaciones.orden_tareas(orden_id, posicion);
create index if not exists orden_tareas_mecanico on operaciones.orden_tareas(mecanico_id) where estatus <> 'hecha';

alter table operaciones.orden_tareas enable row level security;
drop policy if exists leer on operaciones.orden_tareas;
create policy leer on operaciones.orden_tareas for select to authenticated using (core.puede_leer('operaciones'));
-- escritura solo por funciones

create or replace view operaciones.v_tareas with (security_invoker = true) as
select t.*, core.nombre_perfil(t.mecanico_id) as mecanico, core.nombre_perfil(t.terminada_por) as terminada_por_nombre,
       o.estatus as estatus_orden, o.es_prueba
from operaciones.orden_tareas t
join operaciones.ordenes o on o.id = t.orden_id;
grant select on operaciones.v_tareas to authenticated;

-- ---------------------------------------------------------------- permisos
create or replace function operaciones.puede_ver_taller() returns boolean
language sql stable security definer set search_path to 'operaciones','core','public' as $$
  select core.puede_leer('taller') or core.puede_leer('operaciones')
$$;

create or replace function operaciones.es_encargado_taller() returns boolean
language sql stable security definer set search_path to 'operaciones','core','public' as $$
  select coalesce(core.puede_escribir('operaciones'), false)
$$;

-- personal: ahora también lista a los mecánicos (para asignarles tareas)
create or replace function operaciones.personal()
returns table(id uuid, nombre text, puesto text, roles text[], nivel_autorizacion text, autorizador_activo boolean)
language sql stable security definer set search_path to 'operaciones','core','public' as $$
  select p.id, p.nombre, p.puesto,
         array_agg(distinct pr.rol) filter (where pr.rol is not null),
         a.nivel, a.activo
  from core.perfiles p
  left join core.perfil_roles pr on pr.perfil_id = p.id
  left join operaciones.autorizadores a on a.perfil_id = p.id
  where core.puede_leer('operaciones') and p.activo
    and (a.perfil_id is not null or pr.rol in ('operaciones','taller','admin','mecanico'))
  group by p.id, p.nombre, p.puesto, a.nivel, a.activo
  order by p.nombre
$$;

-- ---------------------------------------------------------------- gestión (encargado)
create or replace function operaciones.tarea_guardar(
  p_id uuid, p_orden uuid, p_descripcion text, p_mecanico uuid default null, p_horas numeric default null
) returns uuid
language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare o operaciones.ordenes; v_id uuid; v_pos smallint; v_ant operaciones.orden_tareas;
begin
  if not operaciones.es_encargado_taller() then raise exception 'Solo el encargado del taller u Operaciones arma las tareas'; end if;
  if coalesce(trim(p_descripcion),'') = '' then raise exception 'Escribe la tarea'; end if;
  if p_mecanico is not null and not exists (select 1 from core.perfiles where id = p_mecanico and activo) then
    raise exception 'La persona asignada no existe o está inactiva';
  end if;

  if p_id is null then
    select * into o from operaciones.ordenes where id = p_orden;
    if o.id is null then raise exception 'La orden no existe'; end if;
    if o.estatus in ('entregada','cancelada') then raise exception 'La orden ya está %', o.estatus; end if;
    select coalesce(max(posicion), 0) + 1 into v_pos from operaciones.orden_tareas where orden_id = p_orden;
    insert into operaciones.orden_tareas(orden_id, posicion, descripcion, mecanico_id, horas_estimadas)
    values (p_orden, v_pos, trim(p_descripcion), p_mecanico, p_horas) returning id into v_id;
    insert into operaciones.bitacora(orden_id, tipo, texto)
    values (p_orden, 'tarea', 'Tarea agregada: ' || trim(p_descripcion)
            || coalesce(' · ' || core.nombre_perfil(p_mecanico), ''));
    return v_id;
  end if;

  select * into v_ant from operaciones.orden_tareas where id = p_id for update;
  if v_ant.id is null then raise exception 'La tarea no existe'; end if;
  update operaciones.orden_tareas set descripcion = trim(p_descripcion), mecanico_id = p_mecanico,
         horas_estimadas = p_horas, actualizado_en = now()
   where id = p_id;
  if v_ant.mecanico_id is distinct from p_mecanico then
    insert into operaciones.bitacora(orden_id, tipo, texto)
    values (v_ant.orden_id, 'tarea', 'Tarea "' || trim(p_descripcion) || '" asignada a '
            || coalesce(core.nombre_perfil(p_mecanico), 'nadie'));
  end if;
  return p_id;
end $$;

create or replace function operaciones.tarea_borrar(p_id uuid)
returns void language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare t operaciones.orden_tareas;
begin
  if not operaciones.es_encargado_taller() then raise exception 'Solo el encargado del taller u Operaciones quita tareas'; end if;
  delete from operaciones.orden_tareas where id = p_id returning * into t;
  if t.id is null then return; end if;
  -- recorre posiciones
  update operaciones.orden_tareas set posicion = posicion - 1 where orden_id = t.orden_id and posicion > t.posicion;
  insert into operaciones.bitacora(orden_id, tipo, texto) values (t.orden_id, 'tarea', 'Tarea quitada: ' || t.descripcion);
end $$;

create or replace function operaciones.tarea_mover(p_id uuid, p_delta int)
returns void language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare t operaciones.orden_tareas; o operaciones.orden_tareas;
begin
  if not operaciones.es_encargado_taller() then raise exception 'Solo el encargado del taller u Operaciones ordena las tareas'; end if;
  select * into t from operaciones.orden_tareas where id = p_id for update;
  if t.id is null then raise exception 'La tarea no existe'; end if;
  select * into o from operaciones.orden_tareas
   where orden_id = t.orden_id and posicion = t.posicion + sign(p_delta)::int for update;
  if o.id is null then return; end if;
  update operaciones.orden_tareas set posicion = o.posicion, actualizado_en = now() where id = t.id;
  update operaciones.orden_tareas set posicion = t.posicion, actualizado_en = now() where id = o.id;
end $$;

-- ---------------------------------------------------------------- avance (mecánico o encargado)
create or replace function operaciones.tarea_avance(p_id uuid, p_estatus text, p_nota text default null)
returns void language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare t operaciones.orden_tareas; o operaciones.ordenes; v_enc boolean; v_folio text; v_pend int; v_quien text;
begin
  if p_estatus not in ('pendiente','en_curso','hecha','detenida') then raise exception 'Estatus no válido'; end if;
  v_enc := coalesce(operaciones.es_encargado_taller(), false);
  if not (v_enc or coalesce(core.puede_escribir('taller'), false)) then raise exception 'No tienes permiso para registrar avance'; end if;

  select * into t from operaciones.orden_tareas where id = p_id for update;
  if t.id is null then raise exception 'La tarea no existe'; end if;
  select * into o from operaciones.ordenes where id = t.orden_id;
  if o.estatus in ('entregada','cancelada') then raise exception 'La orden ya está %', o.estatus; end if;

  if not v_enc then
    if t.mecanico_id is not null and t.mecanico_id <> auth.uid() then
      raise exception 'Esta tarea está asignada a %', core.nombre_perfil(t.mecanico_id);
    end if;
    if o.estatus <> 'en_proceso' then
      raise exception 'La unidad todavía no entra a trabajo; espera a que el encargado la pase a línea';
    end if;
  end if;
  if p_estatus = 'detenida' and coalesce(trim(p_nota),'') = '' then
    raise exception 'Escribe por qué se detiene (refacción que falta, hallazgo, etc.)';
  end if;

  update operaciones.orden_tareas set
    estatus = p_estatus,
    -- quien la toma sin asignar se la queda
    mecanico_id = case when mecanico_id is null and not v_enc then auth.uid() else mecanico_id end,
    -- la nota describe el estado actual: al reanudar o terminar se limpia el motivo del paro
    nota = case when p_estatus = 'detenida' then trim(p_nota) else nullif(trim(p_nota),'') end,
    iniciada_en = case when p_estatus in ('en_curso','hecha') then coalesce(iniciada_en, now()) else iniciada_en end,
    terminada_en = case when p_estatus = 'hecha' then now() else null end,
    terminada_por = case when p_estatus = 'hecha' then auth.uid() else null end,
    actualizado_en = now()
  where id = p_id;

  v_folio := case when o.es_prueba then 'PRUEBA-' else 'OT-' end || lpad(o.folio::text, 4, '0');
  v_quien := core.nombre_perfil(auth.uid());

  if p_estatus = 'detenida' then
    perform operaciones.registrar(o.id, 'tarea', 'Tarea detenida: ' || t.descripcion || ' · ' || trim(p_nota));
    perform operaciones.avisar('taller', o.id, 'tarea_detenida', v_folio || ' · ' || t.descripcion || ' detenida: ' || trim(p_nota));
    perform operaciones.avisar('jefatura', o.id, 'tarea_detenida', v_folio || ' · ' || t.descripcion || ' detenida: ' || trim(p_nota));
  elsif p_estatus = 'hecha' then
    perform operaciones.registrar(o.id, 'tarea', 'Tarea hecha: ' || t.descripcion
      || coalesce(' · ' || nullif(trim(p_nota),''), ''));
    select count(*) into v_pend from operaciones.orden_tareas where orden_id = o.id and estatus <> 'hecha';
    if v_pend = 0 then
      perform operaciones.avisar('taller', o.id, 'tareas_completas',
        v_folio || ' · ' || (select niv from core.equipos where id = o.equipo_id) || ': todas las tareas hechas, lista para revisar y terminar');
    end if;
  elsif p_estatus = 'en_curso' then
    insert into operaciones.bitacora(orden_id, tipo, texto)
    values (o.id, 'tarea', case when t.estatus = 'detenida' then 'Tarea reanudada: ' else 'Tarea iniciada: ' end || t.descripcion);
  else
    insert into operaciones.bitacora(orden_id, tipo, texto) values (o.id, 'tarea', 'Tarea regresada a pendiente: ' || t.descripcion);
  end if;
end $$;

-- ---------------------------------------------------------------- lectura sin montos
-- Una orden como la ve el taller: sin montos, sin cotizaciones, sin cliente.
create or replace function operaciones.orden_para_taller(p_orden uuid) returns jsonb
language sql stable security definer set search_path to 'operaciones','core','public' as $$
  select jsonb_build_object(
    'id', o.id,
    'folio', case when o.es_prueba then 'PRUEBA-' else 'OT-' end || lpad(o.folio::text, 4, '0'),
    'es_prueba', o.es_prueba,
    'niv', e.niv, 'placa', e.placa, 'tipo_equipo', te.nombre, 'marca', m.nombre, 'anio', e.anio,
    'tipo', o.tipo, 'prioridad', o.prioridad, 'estatus', o.estatus,
    'descripcion', o.descripcion,
    'trabajos', coalesce((select jsonb_agg(coalesce(tt.nombre, x) order by tt.orden) from unnest(o.trabajos) x
                           left join operaciones.tipos_trabajo tt on tt.clave = x), '[]'::jsonb),
    'fecha_compromiso', o.fecha_compromiso, 'fecha_requerida', o.fecha_requerida,
    'fecha_inicio', o.fecha_inicio, 'fecha_termino', o.fecha_termino,
    'atrasada', (o.fecha_compromiso is not null and o.fecha_compromiso < current_date
                 and o.estatus not in ('terminada','entregada','cancelada')),
    'linea_id', o.linea_id, 'linea', l.nombre, 'linea_numero', l.numero,
    'taller', t.nombre, 'patio', pa.nombre, 'patio_id', o.patio_id,
    'responsable', coalesce(core.nombre_perfil(o.responsable_id), o.responsable_texto),
    'fotos', (select count(*) from operaciones.orden_fotos f where f.orden_id = o.id)
           + (select count(*) from operaciones.fotos_prueba f where f.orden_id = o.id),
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', ta.id, 'posicion', ta.posicion, 'descripcion', ta.descripcion,
                 'estatus', ta.estatus, 'nota', ta.nota, 'horas', ta.horas_estimadas,
                 'mecanico_id', ta.mecanico_id, 'mecanico', core.nombre_perfil(ta.mecanico_id),
                 'iniciada_en', ta.iniciada_en, 'terminada_en', ta.terminada_en) order by ta.posicion)
               from operaciones.orden_tareas ta where ta.orden_id = o.id), '[]'::jsonb)
  )
  from operaciones.ordenes o
  join core.equipos e on e.id = o.equipo_id
  left join core.tipos_equipo te on te.id = e.tipo_id
  left join core.marcas m on m.id = e.marca_id
  left join operaciones.lineas l on l.id = o.linea_id
  left join operaciones.talleres t on t.id = o.taller_id
  left join core.patios pa on pa.id = o.patio_id
  where o.id = p_orden
$$;
revoke execute on function operaciones.orden_para_taller(uuid) from public, anon, authenticated;

-- Tablero del taller: líneas, cola, talleres externos y cifras.
create or replace function operaciones.taller_tablero(p_patio smallint default null) returns jsonb
language plpgsql stable security definer set search_path to 'operaciones','core','public' as $$
declare v_patio smallint; v_prueba boolean;
begin
  if not operaciones.puede_ver_taller() then raise exception 'No tienes acceso al taller'; end if;
  v_prueba := operaciones.en_prueba();
  v_patio := coalesce(p_patio, (select patio_id from operaciones.lineas where activo order by patio_id limit 1));

  return jsonb_build_object(
    'patio_id', v_patio,
    'patio', (select nombre from core.patios where id = v_patio),
    'patios', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre) order by p.nombre)
                        from core.patios p where p.id in (select patio_id from operaciones.lineas where activo)), '[]'::jsonb),
    'prueba', v_prueba,
    'ahora', now(),
    'lineas', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', l.id, 'numero', l.numero, 'nombre', l.nombre, 'uso', l.uso,
                 'orden', (select operaciones.orden_para_taller(o.id) from operaciones.ordenes o
                            where o.linea_id = l.id and o.estatus = 'en_proceso' and o.es_prueba = v_prueba limit 1))
               order by l.numero)
               from operaciones.lineas l where l.activo and l.patio_id = v_patio), '[]'::jsonb),
    'cola', coalesce((select jsonb_agg(operaciones.orden_para_taller(o.id)
                 order by (o.prioridad = 'ticket') desc, o.fecha_compromiso nulls last, o.fecha_requerida nulls last, o.creado_en)
               from operaciones.ordenes o
               where o.estatus = 'autorizada' and o.es_prueba = v_prueba
                 and (o.patio_id = v_patio or o.patio_id is null)), '[]'::jsonb),
    'externos', coalesce((select jsonb_agg(operaciones.orden_para_taller(o.id) order by o.fecha_compromiso nulls last)
               from operaciones.ordenes o
               where o.estatus = 'en_proceso' and o.linea_id is null and o.es_prueba = v_prueba
                 and (o.patio_id = v_patio or o.patio_id is null)), '[]'::jsonb),
    'por_autorizar', (select count(*) from operaciones.ordenes o
               where o.estatus in ('abierta','cotizacion','por_autorizar') and o.es_prueba = v_prueba
                 and (o.patio_id = v_patio or o.patio_id is null)),
    'terminadas_hoy', (select count(*) from operaciones.ordenes o
               where o.fecha_termino >= date_trunc('day', now() at time zone 'America/Monterrey') at time zone 'America/Monterrey'
                 and o.es_prueba = v_prueba and (o.patio_id = v_patio or o.patio_id is null))
  );
end $$;

-- Mis trabajos: órdenes donde tengo tareas, más las que tienen tareas sin dueño en trabajo.
create or replace function operaciones.mis_trabajos() returns jsonb
language plpgsql stable security definer set search_path to 'operaciones','core','public' as $$
declare v_prueba boolean;
begin
  if not operaciones.puede_ver_taller() then raise exception 'No tienes acceso al taller'; end if;
  v_prueba := operaciones.en_prueba();
  return jsonb_build_object(
    'yo', auth.uid(),
    'nombre', core.nombre_perfil(auth.uid()),
    'prueba', v_prueba,
    'ordenes', coalesce((
      select jsonb_agg(operaciones.orden_para_taller(o.id)
               order by (o.estatus = 'en_proceso') desc, o.fecha_compromiso nulls last, o.creado_en)
      from operaciones.ordenes o
      where o.es_prueba = v_prueba
        and o.estatus in ('autorizada','en_proceso','terminada')
        and exists (select 1 from operaciones.orden_tareas ta where ta.orden_id = o.id
                     and (ta.mecanico_id = auth.uid()
                          or (ta.mecanico_id is null and ta.estatus <> 'hecha' and o.estatus = 'en_proceso')))
        and (o.estatus <> 'terminada' or o.fecha_termino > now() - interval '2 days')
    ), '[]'::jsonb),
    'hechas_hoy', (select count(*) from operaciones.orden_tareas
                    where terminada_por = auth.uid()
                      and terminada_en >= date_trunc('day', now() at time zone 'America/Monterrey') at time zone 'America/Monterrey')
  );
end $$;

-- ---------------------------------------------------------------- fotos desde el taller
-- La foto ya se subió al bucket fotos-equipos; aquí se registra.
create or replace function operaciones.taller_foto(
  p_orden uuid, p_foto uuid, p_ruta text, p_etapa text,
  p_ancho int default null, p_alto int default null, p_bytes int default null,
  p_tomada timestamptz default null, p_nota text default null
) returns void
language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare o operaciones.ordenes;
begin
  if p_etapa not in ('avance','terminado') then raise exception 'Etapa de foto no válida'; end if;
  select * into o from operaciones.ordenes where id = p_orden;
  if o.id is null then raise exception 'La orden no existe'; end if;
  if not (operaciones.es_encargado_taller()
          or (coalesce(core.puede_escribir('taller'), false) and exists (
                select 1 from operaciones.orden_tareas where orden_id = p_orden
                 and (mecanico_id = auth.uid() or mecanico_id is null)))) then
    raise exception 'Solo quien trabaja la unidad puede subir fotos';
  end if;
  if o.es_prueba then
    insert into operaciones.fotos_prueba(id, orden_id, etapa, ruta, subida_por, tomada_en)
    values (p_foto, p_orden, p_etapa, p_ruta, auth.uid(), coalesce(p_tomada, now()));
    return;
  end if;
  insert into core.fotos(id, equipo_id, patio_id, modulo_origen, etapa, ruta_storage, ancho, alto, bytes, publica, subida_por, tomada_en)
  values (p_foto, o.equipo_id, o.patio_id, 'operaciones', p_etapa, p_ruta, p_ancho, p_alto, p_bytes, false, auth.uid(), coalesce(p_tomada, now()));
  insert into operaciones.orden_fotos(foto_id, orden_id, etapa, nota) values (p_foto, p_orden, p_etapa, nullif(trim(p_nota),''));
end $$;

-- ---------------------------------------------------------------- permisos de ejecución
grant execute on function operaciones.puede_ver_taller(), operaciones.es_encargado_taller(),
  operaciones.tarea_guardar(uuid, uuid, text, uuid, numeric), operaciones.tarea_borrar(uuid),
  operaciones.tarea_mover(uuid, int), operaciones.tarea_avance(uuid, text, text),
  operaciones.taller_tablero(smallint), operaciones.mis_trabajos(),
  operaciones.taller_foto(uuid, uuid, text, text, int, int, int, timestamptz, text)
to authenticated;
grant select on operaciones.orden_tareas to authenticated;

-- ============================ ENSAYO ============================
do $ensayo$
declare
  v_ilse uuid := '2f7b70c1-ae63-4c6a-a7f3-e28d4d303c77';
  v_mec  uuid := '27b99016-efd9-4f49-957a-8878e1778f40';
  v_mec2 uuid := 'f9957873-a495-42a8-960c-a666056b6bd2';
  v_eq   uuid := '1dbd33f4-0e39-4f28-a82e-7534fcc3431e';
  v_lin  smallint; v_patio smallint; v_ord uuid; v_ord2 uuid;
  t1 uuid; t2 uuid; t3 uuid; tc uuid;
  r jsonb := '{}'; j jsonb; n int;
begin
  insert into core.perfil_roles(perfil_id, rol) values (v_mec, 'mecanico'), (v_mec2, 'mecanico');
  select id, patio_id into v_lin, v_patio from operaciones.lineas where activo and numero = 1 order by patio_id limit 1;
  insert into operaciones.ordenes(equipo_id, patio_id, tipo, trabajos, prioridad, descripcion, cliente, estatus,
      requiere_cotizacion, linea_id, fecha_compromiso, fecha_inicio, creado_por)
  values (v_eq, v_patio, 'reparacion', array['frenos','luces'], 'ticket', 'Ensayo taller', 'CLIENTE SECRETO SA', 'en_proceso',
      true, v_lin, current_date, now(), v_ilse) returning id into v_ord;
  insert into operaciones.cotizaciones(orden_id, equipo_id, concepto, monto_sin_iva, estatus, nivel_requerido, creado_por)
  values (v_ord, v_eq, 'Balatas', 12345.67, 'autorizada', 'jefatura', v_ilse);
  insert into operaciones.ordenes(equipo_id, patio_id, tipo, prioridad, descripcion, estatus, requiere_cotizacion, creado_por)
  select e.id, v_patio, 'adecuacion', 'sin_asignar', 'Ensayo cola', 'autorizada', false, v_ilse
  from core.equipos e where e.activo and e.id <> v_eq limit 1 returning id into v_ord2;

  perform set_config('request.jwt.claims', json_build_object('sub', v_ilse, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_ilse::text, true);
  execute 'set local role authenticated';
  t1 := operaciones.tarea_guardar(null, v_ord, 'Cambiar balatas', v_mec, 2);
  t2 := operaciones.tarea_guardar(null, v_ord, 'Revisar luces', v_mec2, 1);
  t3 := operaciones.tarea_guardar(null, v_ord, 'Lavado final', null, null);
  perform operaciones.tarea_mover(t3, -1);
  r := r || jsonb_build_object('01_orden_tareas_tras_mover',
        (select string_agg(descripcion, ' > ' order by posicion) from operaciones.orden_tareas where orden_id = v_ord));
  r := r || jsonb_build_object('02_personal_mecanicos', (select count(*) from operaciones.personal() where 'mecanico' = any(roles)));
  r := r || jsonb_build_object('03_encargado_lee_v_tareas', (select count(*) from operaciones.v_tareas where orden_id = v_ord));
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_mec, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_mec::text, true);
  execute 'set local role authenticated';
  r := r || jsonb_build_object('04_mec_nivel_operaciones', coalesce(core.nivel_modulo('operaciones'), 'ninguno'),
                               '05_mec_nivel_taller', core.nivel_modulo('taller'),
                               '06_mec_modulos', (select string_agg(clave, ',') from core.v_mis_modulos));
  select count(*) into n from operaciones.ordenes; r := r || jsonb_build_object('07_mec_ve_ordenes_directo', n);
  select count(*) into n from operaciones.cotizaciones; r := r || jsonb_build_object('08_mec_ve_cotizaciones_directo', n);
  select count(*) into n from operaciones.orden_tareas; r := r || jsonb_build_object('09_mec_ve_tareas_directo', n);
  j := operaciones.mis_trabajos();
  r := r || jsonb_build_object('10_mis_trabajos_ordenes', jsonb_array_length(j->'ordenes'),
         '11_mis_trabajos_tiene_monto', (j::text like '%12345%'), '12_mis_trabajos_tiene_cliente', (j::text ilike '%SECRETO%'));
  j := operaciones.taller_tablero(null);
  r := r || jsonb_build_object('13_tablero_patio', j->>'patio',
         '14_tablero_linea1', j->'lineas'->0->'orden'->>'folio',
         '15_tablero_cola', jsonb_array_length(j->'cola'),
         '16_tablero_tiene_monto', (j::text like '%12345%'), '17_tablero_tiene_cliente', (j::text ilike '%SECRETO%'),
         '18_tablero_siguiente', (select x->>'descripcion' from jsonb_array_elements(j->'lineas'->0->'orden'->'tareas') x where x->>'estatus' <> 'hecha' order by (x->>'posicion')::int limit 1));
  begin perform operaciones.orden_para_taller(v_ord); r := r || '{"19_mec_llama_orden_para_taller":"PERMITIDO (mal)"}';
  exception when others then r := r || jsonb_build_object('19_mec_llama_orden_para_taller', 'bloqueado: ' || sqlerrm); end;
  begin perform operaciones.tarea_guardar(null, v_ord, 'Tarea pirata', null, null); r := r || '{"20_mec_crea_tarea":"PERMITIDO (mal)"}';
  exception when others then r := r || jsonb_build_object('20_mec_crea_tarea', 'bloqueado: ' || sqlerrm); end;
  perform operaciones.tarea_avance(t1, 'en_curso');
  begin perform operaciones.tarea_avance(t2, 'en_curso'); r := r || '{"21_mec_toca_tarea_ajena":"PERMITIDO (mal)"}';
  exception when others then r := r || jsonb_build_object('21_mec_toca_tarea_ajena', 'bloqueado: ' || sqlerrm); end;
  begin perform operaciones.tarea_avance(t1, 'detenida', null); r := r || '{"22_detener_sin_motivo":"PERMITIDO (mal)"}';
  exception when others then r := r || jsonb_build_object('22_detener_sin_motivo', 'bloqueado: ' || sqlerrm); end;
  perform operaciones.tarea_avance(t1, 'detenida', 'Falta manguera de aire');
  perform operaciones.tarea_avance(t1, 'en_curso');
  perform operaciones.tarea_avance(t1, 'hecha');
  perform operaciones.tarea_avance(t3, 'hecha');
  perform operaciones.taller_foto(v_ord, gen_random_uuid(), 'ENSAYO/operaciones/x.jpg', 'avance', 100, 100, 1000, now(), 'ensayo');
  r := r || jsonb_build_object('23_mec_hechas_hoy', (operaciones.mis_trabajos()->>'hechas_hoy')::int);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_ilse, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_ilse::text, true);
  execute 'set local role authenticated';
  tc := operaciones.tarea_guardar(null, v_ord2, 'Adecuar puertas', v_mec, null);
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_mec, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_mec::text, true);
  execute 'set local role authenticated';
  begin perform operaciones.tarea_avance(tc, 'en_curso'); r := r || '{"24_avance_en_orden_en_cola":"PERMITIDO (mal)"}';
  exception when others then r := r || jsonb_build_object('24_avance_en_orden_en_cola', 'bloqueado: ' || sqlerrm); end;
  r := r || jsonb_build_object('25_mis_trabajos_con_cola', jsonb_array_length(operaciones.mis_trabajos()->'ordenes'));
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_mec2, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_mec2::text, true);
  execute 'set local role authenticated';
  perform operaciones.tarea_avance(t2, 'hecha');
  execute 'reset role';

  r := r || jsonb_build_object(
    '26_tareas', (select jsonb_agg(jsonb_build_object('t', descripcion, 'est', estatus, 'quien', core.nombre_perfil(mecanico_id), 'nota', nota) order by posicion) from operaciones.orden_tareas where orden_id = v_ord),
    '27_avisos', (select jsonb_agg(audiencia || ':' || tipo || ' · ' || texto order by id) from operaciones.avisos where orden_id = v_ord),
    '28_bitacora_tareas', (select count(*) from operaciones.bitacora where orden_id = v_ord and tipo = 'tarea'),
    '29_fotos_registradas', (select count(*) from operaciones.orden_fotos where orden_id = v_ord));

  perform set_config('request.jwt.claims', json_build_object('sub', v_ilse, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_ilse::text, true);
  execute 'set local role authenticated';
  r := r || jsonb_build_object('30_avisos_que_ve_ilse', (select count(*) from operaciones.mis_avisos(40) where orden_id = v_ord));
  execute 'reset role';

  -- el mecánico no puede usar funciones de Operaciones (hueco corregido)
  perform set_config('request.jwt.claims', json_build_object('sub', v_mec, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_mec::text, true);
  execute 'set local role authenticated';
  begin perform operaciones.cambiar_estatus(v_ord, 'terminada', 'pirata', null, false); r := r || '{"31_mec_cambia_estatus_orden":"PERMITIDO (mal)"}';
  exception when others then r := r || jsonb_build_object('31_mec_cambia_estatus_orden', 'bloqueado: ' || sqlerrm); end;
  begin perform operaciones.comentar(v_ord, 'pirata'); r := r || '{"32_mec_comenta_en_operaciones":"PERMITIDO (mal)"}';
  exception when others then r := r || jsonb_build_object('32_mec_comenta_en_operaciones', 'bloqueado: ' || sqlerrm); end;
  execute 'reset role';

  raise exception 'ENSAYO_OK %', r::text;
end $ensayo$;

rollback;
