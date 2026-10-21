-- =====================================================================
-- Plataforma HT · Operaciones en patio (campo.html) · 2026-10-21
-- Seguimiento de tareas de los asistentes de Operaciones
--
-- 1) operaciones.asignaciones: tareas que la jefatura (Ilse, Francisco,
--    Rogelio) le asigna a un asistente, con fecha compromiso y prioridad.
-- 2) operaciones.asignacion_avances: bitácora de avance de cada tarea.
-- 3) Cada asistente ve solo sus tareas; la jefatura ve las de todos.
--    Todo cambio pasa por funciones (no se escribe directo en las tablas).
-- 4) operaciones.mi_alcance(): dice si soy jefatura y qué patios me tocan,
--    para repartir las tareas de proceso (unidades por inspeccionar).
-- Es aditivo: no cambia ni borra nada existente.
-- =====================================================================

create or replace function operaciones.es_jefe()
returns boolean language sql stable security definer
set search_path to 'operaciones','core','public'
as $$ select core.es_admin() or operaciones.mi_nivel_autorizacion() is not null $$;

create table if not exists operaciones.asignaciones (
  id               uuid primary key default gen_random_uuid(),
  titulo           text not null check (length(trim(titulo)) > 0),
  detalle          text,
  responsable_id   uuid not null references core.perfiles(id),
  asignada_por     uuid not null references core.perfiles(id),
  fecha_compromiso date,
  prioridad        text not null default 'normal' check (prioridad in ('normal','alta')),
  equipo_id        uuid references core.equipos(id),
  orden_id         uuid references operaciones.ordenes(id),
  estatus          text not null default 'pendiente' check (estatus in ('pendiente','en_curso','hecha','cancelada')),
  creado_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now(),
  terminada_en     timestamptz,
  es_prueba        boolean not null default false
);
create index if not exists asignaciones_resp_idx on operaciones.asignaciones (responsable_id, estatus);

create table if not exists operaciones.asignacion_avances (
  id            bigint generated always as identity primary key,
  asignacion_id uuid not null references operaciones.asignaciones(id) on delete cascade,
  texto         text,
  estatus       text,
  por           uuid not null references core.perfiles(id),
  en            timestamptz not null default now()
);
create index if not exists asignacion_avances_idx on operaciones.asignacion_avances (asignacion_id, en);

alter table operaciones.asignaciones enable row level security;
alter table operaciones.asignacion_avances enable row level security;

drop policy if exists leer on operaciones.asignaciones;
create policy leer on operaciones.asignaciones for select to authenticated
  using (core.puede_leer('operaciones') and (responsable_id = auth.uid() or asignada_por = auth.uid() or operaciones.es_jefe()));

drop policy if exists leer on operaciones.asignacion_avances;
create policy leer on operaciones.asignacion_avances for select to authenticated
  using (exists (select 1 from operaciones.asignaciones a where a.id = asignacion_id));

revoke all on operaciones.asignaciones, operaciones.asignacion_avances from anon;
grant select on operaciones.asignaciones, operaciones.asignacion_avances to authenticated;

create or replace view operaciones.v_asignaciones with (security_invoker = true) as
select a.*, r.nombre as responsable, p.nombre as asignada_por_nombre, e.niv, e.placa, o.folio as orden_folio,
       (a.estatus in ('pendiente','en_curso') and a.fecha_compromiso < (now() at time zone 'America/Monterrey')::date) as vencida,
       (select max(v.en) from operaciones.asignacion_avances v where v.asignacion_id = a.id) as ultimo_avance
from operaciones.asignaciones a
join core.perfiles r on r.id = a.responsable_id
join core.perfiles p on p.id = a.asignada_por
left join core.equipos e on e.id = a.equipo_id
left join operaciones.ordenes o on o.id = a.orden_id;
grant select on operaciones.v_asignaciones to authenticated;

create or replace view operaciones.v_asignacion_avances with (security_invoker = true) as
select v.*, p.nombre as por_nombre from operaciones.asignacion_avances v join core.perfiles p on p.id = v.por;
grant select on operaciones.v_asignacion_avances to authenticated;

-- Personas a las que se les puede asignar (captura en Operaciones)
create or replace function operaciones.personas_asignables()
returns table(id uuid, nombre text, puesto text, jefe boolean)
language sql stable security definer
set search_path to 'operaciones','core','public'
as $$
  select p.id, p.nombre, p.puesto, exists (select 1 from operaciones.autorizadores a where a.perfil_id = p.id and a.activo)
  from core.perfiles p
  where p.activo and core.puede_leer('operaciones')
    and exists (select 1 from core.perfil_roles pr join core.rol_modulos rm on rm.rol = pr.rol
                where pr.perfil_id = p.id and rm.modulo = 'operaciones' and rm.nivel in ('escritura','admin'))
  order by 4, 2
$$;

-- Qué me toca: si soy jefatura, mis patios y los patios que nadie tiene asignados
create or replace function operaciones.mi_alcance()
returns json language sql stable security definer
set search_path to 'operaciones','core','public'
as $$
  select json_build_object(
    'jefe', operaciones.es_jefe(),
    'mis_patios', coalesce((select json_agg(patio_id) from core.perfil_patios where perfil_id = auth.uid()), '[]'::json),
    'patios_con_responsable', coalesce((select json_agg(distinct pp.patio_id) from core.perfil_patios pp
        join core.perfil_roles pr on pr.perfil_id = pp.perfil_id
        join core.rol_modulos rm on rm.rol = pr.rol and rm.modulo = 'operaciones' and rm.nivel = 'escritura'
        join core.perfiles p on p.id = pp.perfil_id and p.activo), '[]'::json))
  where core.puede_leer('operaciones')
$$;

-- Asignar una tarea (solo jefatura)
create or replace function operaciones.asignar_tarea(p_titulo text, p_responsable uuid, p_detalle text default null,
  p_fecha date default null, p_prioridad text default 'normal', p_equipo uuid default null, p_orden uuid default null)
returns uuid language plpgsql security definer
set search_path to 'operaciones','core','public'
as $$
declare v_id uuid := gen_random_uuid(); v_prueba boolean := operaciones.en_prueba(); v_txt text;
begin
  if not operaciones.es_jefe() then raise exception 'Solo la jefatura de Operaciones puede asignar tareas'; end if;
  if coalesce(trim(p_titulo),'') = '' then raise exception 'Escribe qué hay que hacer'; end if;
  if not exists (select 1 from operaciones.personas_asignables() x where x.id = p_responsable) then
    raise exception 'Esa persona no tiene captura en Operaciones';
  end if;
  insert into operaciones.asignaciones (id, titulo, detalle, responsable_id, asignada_por, fecha_compromiso, prioridad, equipo_id, orden_id, es_prueba)
  values (v_id, left(trim(p_titulo), 200), nullif(trim(p_detalle), ''), p_responsable, auth.uid(), p_fecha,
          case when p_prioridad = 'alta' then 'alta' else 'normal' end, p_equipo, p_orden, v_prueba);
  insert into operaciones.asignacion_avances (asignacion_id, texto, estatus, por) values (v_id, 'Tarea asignada', 'pendiente', auth.uid());
  v_txt := 'Nueva tarea: ' || left(trim(p_titulo), 150) || coalesce(' · compromiso ' || to_char(p_fecha, 'DD/MM'), '');
  insert into operaciones.avisos (audiencia, perfil_id, orden_id, tipo, texto, es_prueba)
  select 'perfil', p_responsable, p_orden, 'tarea', case when v_prueba then 'PRUEBA · ' || v_txt else v_txt end, v_prueba
  where p_responsable <> auth.uid();
  return v_id;
end $$;

-- Editar / reasignar / cambiar fecha (solo jefatura)
create or replace function operaciones.editar_tarea(p_id uuid, p_titulo text, p_responsable uuid, p_detalle text default null,
  p_fecha date default null, p_prioridad text default 'normal')
returns void language plpgsql security definer
set search_path to 'operaciones','core','public'
as $$
declare a operaciones.asignaciones; v_cambios text := '';
begin
  if not operaciones.es_jefe() then raise exception 'Solo la jefatura de Operaciones puede editar tareas'; end if;
  select * into a from operaciones.asignaciones where id = p_id for update;
  if a.id is null then raise exception 'La tarea no existe'; end if;
  if coalesce(trim(p_titulo),'') = '' then raise exception 'Escribe qué hay que hacer'; end if;
  if not exists (select 1 from operaciones.personas_asignables() x where x.id = p_responsable) then
    raise exception 'Esa persona no tiene captura en Operaciones';
  end if;
  if a.responsable_id <> p_responsable then v_cambios := v_cambios || 'Reasignada a ' || (select nombre from core.perfiles where id = p_responsable) || '. '; end if;
  if a.fecha_compromiso is distinct from p_fecha then v_cambios := v_cambios || 'Compromiso: ' || coalesce(to_char(p_fecha, 'DD/MM/YYYY'), 'sin fecha') || '. '; end if;
  update operaciones.asignaciones set titulo = left(trim(p_titulo), 200), detalle = nullif(trim(p_detalle), ''),
    responsable_id = p_responsable, fecha_compromiso = p_fecha, prioridad = case when p_prioridad = 'alta' then 'alta' else 'normal' end,
    actualizado_en = now() where id = p_id;
  if v_cambios <> '' then
    insert into operaciones.asignacion_avances (asignacion_id, texto, por) values (p_id, trim(v_cambios), auth.uid());
  end if;
  if a.responsable_id <> p_responsable and p_responsable <> auth.uid() then
    insert into operaciones.avisos (audiencia, perfil_id, orden_id, tipo, texto, es_prueba)
    values ('perfil', p_responsable, a.orden_id, 'tarea',
      case when a.es_prueba then 'PRUEBA · ' else '' end || 'Te asignaron la tarea: ' || left(trim(p_titulo), 150), a.es_prueba);
  end if;
end $$;

-- Reportar avance o cambiar estatus (responsable o jefatura; cancelar solo jefatura)
create or replace function operaciones.avance_tarea(p_id uuid, p_texto text default null, p_estatus text default null)
returns void language plpgsql security definer
set search_path to 'operaciones','core','public'
as $$
declare a operaciones.asignaciones; v_jefe boolean := operaciones.es_jefe(); v_txt text;
begin
  select * into a from operaciones.asignaciones where id = p_id for update;
  if a.id is null then raise exception 'La tarea no existe'; end if;
  if a.responsable_id <> auth.uid() and not v_jefe then raise exception 'Esta tarea no es tuya'; end if;
  if p_estatus is not null and p_estatus not in ('pendiente','en_curso','hecha','cancelada') then raise exception 'Estatus no válido'; end if;
  if p_estatus = 'cancelada' and not v_jefe then raise exception 'Solo la jefatura puede cancelar una tarea'; end if;
  if a.estatus = 'cancelada' and not v_jefe then raise exception 'La tarea está cancelada'; end if;
  if coalesce(trim(p_texto),'') = '' and (p_estatus is null or p_estatus = a.estatus) then raise exception 'Escribe el avance'; end if;
  if p_estatus = 'cancelada' and coalesce(trim(p_texto),'') = '' then raise exception 'Escribe por qué se cancela'; end if;

  insert into operaciones.asignacion_avances (asignacion_id, texto, estatus, por)
  values (p_id, nullif(left(trim(p_texto), 1000), ''), case when p_estatus is distinct from a.estatus then p_estatus end, auth.uid());
  update operaciones.asignaciones set
    estatus = coalesce(p_estatus, case when estatus = 'pendiente' then 'en_curso' else estatus end),
    terminada_en = case when coalesce(p_estatus, estatus) = 'hecha' then coalesce(terminada_en, now()) else null end,
    actualizado_en = now()
  where id = p_id;

  -- avisa a quien la asignó cuando el asistente la termina
  if p_estatus = 'hecha' and a.estatus <> 'hecha' and a.asignada_por <> auth.uid() then
    v_txt := (select nombre from core.perfiles where id = auth.uid()) || ' terminó: ' || left(a.titulo, 150);
    insert into operaciones.avisos (audiencia, perfil_id, orden_id, tipo, texto, es_prueba)
    values ('perfil', a.asignada_por, a.orden_id, 'tarea', case when a.es_prueba then 'PRUEBA · ' || v_txt else v_txt end, a.es_prueba);
  end if;
end $$;

revoke all on function operaciones.es_jefe(), operaciones.personas_asignables(), operaciones.mi_alcance(),
  operaciones.asignar_tarea(text, uuid, text, date, text, uuid, uuid),
  operaciones.editar_tarea(uuid, text, uuid, text, date, text),
  operaciones.avance_tarea(uuid, text, text) from public, anon;
grant execute on function operaciones.es_jefe(), operaciones.personas_asignables(), operaciones.mi_alcance(),
  operaciones.asignar_tarea(text, uuid, text, date, text, uuid, uuid),
  operaciones.editar_tarea(uuid, text, uuid, text, date, text),
  operaciones.avance_tarea(uuid, text, text) to authenticated;
