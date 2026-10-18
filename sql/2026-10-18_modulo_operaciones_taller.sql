-- =====================================================================
-- Plataforma HT · Módulo Operaciones y taller (2026-10-18)
--
-- Revisión fisicomecánica de llegada, órdenes de trabajo (reparación y
-- adecuación), cotizaciones con autorización, 4 líneas del taller,
-- fotos por etapa, bitácora y avisos.
--
-- Regla de autorización (definida por Rogelio Morejón):
--   * El tope se mide ANTES de IVA y sobre la SUMA de cotizaciones vivas
--     del mismo equipo (pendientes + autorizadas de sus órdenes abiertas
--     o creadas dentro de la ventana de días configurada).
--   * Suma <= tope (15,000): autoriza Ilse Cortés o Rogelio Morejón,
--     con justificación obligatoria.
--   * Suma  > tope: autoriza Francisco Mendoza. La jefatura solo puede
--     darle visto bueno.
--   * Tope y ventana son parámetros (operaciones.parametros).
-- =====================================================================

create schema if not exists operaciones;
grant usage on schema operaciones to authenticated;

-- ---------------------------------------------------------------- catálogos
create table if not exists operaciones.parametros(
  clave text primary key,
  valor numeric not null,
  descripcion text,
  actualizado_por uuid references core.perfiles(id),
  actualizado_en timestamptz not null default now()
);
insert into operaciones.parametros(clave, valor, descripcion) values
  ('limite_autorizacion', 15000, 'Tope antes de IVA. Si la suma de cotizaciones del equipo lo supera, autoriza la gerencia.'),
  ('ventana_acumulado_dias', 90, 'Días hacia atrás en que se suman cotizaciones del mismo equipo de órdenes ya cerradas.'),
  ('iva', 0.16, 'Tasa de IVA para mostrar el total con impuesto.')
on conflict (clave) do nothing;

create table if not exists operaciones.autorizadores(
  perfil_id uuid primary key references core.perfiles(id),
  nivel text not null check (nivel in ('jefatura','gerencia')),
  activo boolean not null default true
);
insert into operaciones.autorizadores(perfil_id, nivel)
select p.id, v.nivel
from (values ('francisco.mendoza@htrent.mx','gerencia'),
             ('ilse.cortes@htrent.mx','jefatura'),
             ('juan.morejon@htrent.mx','jefatura')) v(correo, nivel)
join core.perfiles p on lower(p.correo) = v.correo
on conflict (perfil_id) do nothing;

create table if not exists operaciones.talleres(
  id smallint generated always as identity primary key,
  nombre text not null unique,
  tipo text not null default 'externo' check (tipo in ('interno','externo')),
  patio_id smallint references core.patios(id),
  contacto text, telefono text, correo text,
  activo boolean not null default true
);
insert into operaciones.talleres(nombre, tipo, patio_id)
select 'Taller HT Monterrey', 'interno', id from core.patios where nombre = 'MONTERREY - HT'
on conflict (nombre) do nothing;

create table if not exists operaciones.tipos_trabajo(
  clave text primary key,
  nombre text not null,
  categoria text not null check (categoria in ('reparacion','adecuacion')),
  orden smallint not null default 50,
  activo boolean not null default true
);
insert into operaciones.tipos_trabajo(clave, nombre, categoria, orden) values
  ('mecanica','Mecánica','reparacion',10),
  ('electrica','Eléctrica','reparacion',20),
  ('estructural','Estructural','reparacion',30),
  ('frenos','Frenos','reparacion',40),
  ('suspension','Suspensión','reparacion',50),
  ('llantas','Llantas','reparacion',60),
  ('piso','Piso','reparacion',70),
  ('puertas','Puertas y herrajes','reparacion',80),
  ('lamina','Lámina y pintura','reparacion',90),
  ('adecuacion_cliente','Adecuación para cliente','adecuacion',110),
  ('rotulado','Rotulado / retiro de rotulado','adecuacion',120),
  ('gps','Instalación de GPS','adecuacion',130),
  ('lavado','Lavado y limpieza','adecuacion',140)
on conflict (clave) do nothing;

create table if not exists operaciones.lineas(
  id smallint generated always as identity primary key,
  patio_id smallint not null references core.patios(id),
  numero smallint not null,
  nombre text not null,
  uso text not null check (uso in ('prioritaria','general')),
  activo boolean not null default true,
  unique (patio_id, numero)
);
insert into operaciones.lineas(patio_id, numero, nombre, uso)
select p.id, v.n, v.nom, v.uso
from core.patios p,
     (values (1,'Línea 1','prioritaria'),(2,'Línea 2','prioritaria'),
             (3,'Línea 3','prioritaria'),(4,'Línea 4','general')) v(n, nom, uso)
where p.nombre = 'MONTERREY - HT'
on conflict (patio_id, numero) do nothing;

-- ---------------------------------------------------------------- revisiones
create table if not exists operaciones.revisiones(
  id uuid primary key default gen_random_uuid(),
  equipo_id uuid not null references core.equipos(id),
  patio_id smallint references core.patios(id),
  motivo text not null default 'llegada' check (motivo in ('llegada','periodica','pre_entrega','otra')),
  procedencia text,
  puntos jsonb not null default '{}'::jsonb,
  condicion text check (condicion in ('buena','regular','mala')),
  resultado text not null check (resultado in ('listo','reparacion','adecuacion','baja')),
  observaciones text,
  gps_lat double precision, gps_lng double precision,
  creado_por uuid not null default auth.uid() references core.perfiles(id),
  creado_en timestamptz not null default now()
);
create index if not exists revisiones_equipo on operaciones.revisiones(equipo_id, creado_en desc);

-- ---------------------------------------------------------------- órdenes
create table if not exists operaciones.ordenes(
  id uuid primary key default gen_random_uuid(),
  folio integer generated always as identity unique,
  equipo_id uuid not null references core.equipos(id),
  patio_id smallint references core.patios(id),
  revision_id uuid references operaciones.revisiones(id),
  tipo text not null default 'reparacion' check (tipo in ('reparacion','adecuacion')),
  trabajos text[] not null default '{}',
  prioridad text not null default 'sin_asignar' check (prioridad in ('ticket','sin_asignar')),
  descripcion text not null,
  cliente text,
  fecha_requerida date,
  estatus text not null default 'abierta' check (estatus in
    ('abierta','cotizacion','por_autorizar','autorizada','en_proceso','terminada','entregada','cancelada')),
  requiere_cotizacion boolean not null default true,
  taller_id smallint references operaciones.talleres(id),
  linea_id smallint references operaciones.lineas(id),
  responsable_id uuid references core.perfiles(id),
  responsable_texto text,
  fecha_compromiso date,
  fecha_inicio timestamptz, fecha_termino timestamptz, fecha_entrega timestamptz,
  motivo_cancelacion text,
  creado_por uuid not null default auth.uid() references core.perfiles(id),
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index if not exists ordenes_equipo on operaciones.ordenes(equipo_id);
create index if not exists ordenes_estatus on operaciones.ordenes(estatus);
-- una línea solo tiene un equipo trabajando a la vez
create unique index if not exists ordenes_linea_ocupada on operaciones.ordenes(linea_id)
  where estatus = 'en_proceso' and linea_id is not null;
-- un equipo solo tiene una orden abierta del mismo tipo
create unique index if not exists ordenes_equipo_abierta on operaciones.ordenes(equipo_id, tipo)
  where estatus not in ('entregada','cancelada');

create table if not exists operaciones.cotizaciones(
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references operaciones.ordenes(id) on delete cascade,
  equipo_id uuid not null references core.equipos(id),
  concepto text not null,
  proveedor text,
  taller_id smallint references operaciones.talleres(id),
  monto_sin_iva numeric(12,2) not null check (monto_sin_iva > 0),
  iva_tasa numeric(5,4) not null default 0.16,
  total numeric(12,2) generated always as (round(monto_sin_iva * (1 + iva_tasa), 2)) stored,
  archivo_ruta text,
  estatus text not null default 'pendiente' check (estatus in ('pendiente','autorizada','rechazada','cancelada')),
  nivel_requerido text not null check (nivel_requerido in ('jefatura','gerencia')),
  acumulado_equipo numeric(12,2) not null default 0,
  vobo_por uuid references core.perfiles(id), vobo_en timestamptz, vobo_nota text,
  resuelto_por uuid references core.perfiles(id), resuelto_en timestamptz,
  justificacion text,
  creado_por uuid not null default auth.uid() references core.perfiles(id),
  creado_en timestamptz not null default now()
);
create index if not exists cotizaciones_orden on operaciones.cotizaciones(orden_id);
create index if not exists cotizaciones_equipo on operaciones.cotizaciones(equipo_id, estatus);

create table if not exists operaciones.orden_fotos(
  foto_id uuid primary key references core.fotos(id) on delete cascade,
  orden_id uuid references operaciones.ordenes(id) on delete cascade,
  revision_id uuid references operaciones.revisiones(id) on delete cascade,
  etapa text not null check (etapa in ('condicion','avance','terminado','entrega')),
  nota text,
  check (orden_id is not null or revision_id is not null)
);
create index if not exists orden_fotos_orden on operaciones.orden_fotos(orden_id);

create table if not exists operaciones.bitacora(
  id bigint generated always as identity primary key,
  orden_id uuid not null references operaciones.ordenes(id) on delete cascade,
  tipo text not null,
  texto text,
  datos jsonb,
  por uuid default auth.uid() references core.perfiles(id),
  en timestamptz not null default now()
);
create index if not exists bitacora_orden on operaciones.bitacora(orden_id, en);

create table if not exists operaciones.avisos(
  id bigint generated always as identity primary key,
  audiencia text not null check (audiencia in ('jefatura','gerencia','taller','perfil')),
  perfil_id uuid references core.perfiles(id),
  orden_id uuid references operaciones.ordenes(id) on delete cascade,
  tipo text not null,
  texto text not null,
  creado_en timestamptz not null default now()
);
create index if not exists avisos_fecha on operaciones.avisos(creado_en desc);
create table if not exists operaciones.avisos_leidos(
  aviso_id bigint references operaciones.avisos(id) on delete cascade,
  perfil_id uuid references core.perfiles(id),
  leido_en timestamptz not null default now(),
  primary key (aviso_id, perfil_id)
);

-- rol para encargados de taller
insert into core.roles(clave, nombre) values ('taller','Encargado de taller') on conflict (clave) do nothing;
insert into core.rol_modulos(rol, modulo, nivel)
select 'taller','operaciones','escritura'
where not exists (select 1 from core.rol_modulos where rol='taller' and modulo='operaciones');

-- ---------------------------------------------------------------- utilidades
create or replace function operaciones.param(p text) returns numeric
language sql stable security definer set search_path to 'operaciones','public' as $$
  select valor from operaciones.parametros where clave = p
$$;

create or replace function operaciones.mi_nivel_autorizacion() returns text
language sql stable security definer set search_path to 'operaciones','core','public' as $$
  select a.nivel from operaciones.autorizadores a
  join core.perfiles p on p.id = a.perfil_id
  where a.perfil_id = auth.uid() and a.activo and p.activo
$$;

create or replace function operaciones.puede_configurar() returns boolean
language sql stable security definer set search_path to 'operaciones','core','public' as $$
  select core.es_admin() or core.nivel_modulo('operaciones') = 'admin'
      or operaciones.mi_nivel_autorizacion() is not null
$$;

create or replace function operaciones.es_taller() returns boolean
language sql stable security definer set search_path to 'operaciones','core','public' as $$
  select exists (select 1 from core.perfil_roles where perfil_id = auth.uid() and rol = 'taller')
$$;

-- suma viva de cotizaciones del equipo (antes de IVA), sin contar p_excluir
create or replace function operaciones.acumulado_equipo(p_equipo uuid, p_excluir uuid default null)
returns numeric
language sql stable security definer set search_path to 'operaciones','public' as $$
  select coalesce(sum(c.monto_sin_iva), 0)
  from operaciones.cotizaciones c
  join operaciones.ordenes o on o.id = c.orden_id
  where c.equipo_id = p_equipo
    and c.estatus in ('pendiente','autorizada')
    and (p_excluir is null or c.id <> p_excluir)
    and ( o.estatus not in ('entregada','cancelada')
       or c.creado_en >= now() - make_interval(days => operaciones.param('ventana_acumulado_dias')::int) )
$$;

create or replace function operaciones.registrar(p_orden uuid, p_tipo text, p_texto text, p_datos jsonb default null)
returns void language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare v_eq uuid; v_patio smallint;
begin
  insert into operaciones.bitacora(orden_id, tipo, texto, datos) values (p_orden, p_tipo, p_texto, p_datos);
  select equipo_id, patio_id into v_eq, v_patio from operaciones.ordenes where id = p_orden;
  insert into core.eventos_equipo(equipo_id, modulo, tipo, descripcion, datos, patio_id, registrado_por)
  values (v_eq, 'operaciones', p_tipo, p_texto, coalesce(p_datos,'{}'::jsonb) || jsonb_build_object('orden_id', p_orden), v_patio, auth.uid());
end $$;

create or replace function operaciones.avisar(p_aud text, p_orden uuid, p_tipo text, p_texto text, p_perfil uuid default null)
returns void language sql security definer set search_path to 'operaciones','public' as $$
  insert into operaciones.avisos(audiencia, perfil_id, orden_id, tipo, texto)
  select p_aud, p_perfil, p_orden, p_tipo, p_texto
  where p_aud <> 'perfil' or (p_perfil is not null and p_perfil is distinct from auth.uid());
$$;

-- recalcula el estatus de la orden según sus cotizaciones (solo antes de iniciar el trabajo)
create or replace function operaciones.recalcular_orden(p_orden uuid)
returns text language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare o operaciones.ordenes; n_pend int; n_aut int; n_tot int; nuevo text;
begin
  select * into o from operaciones.ordenes where id = p_orden for update;
  if o.estatus not in ('abierta','cotizacion','por_autorizar','autorizada') then return o.estatus; end if;
  select count(*) filter (where estatus='pendiente'),
         count(*) filter (where estatus='autorizada'),
         count(*) filter (where estatus in ('pendiente','autorizada','rechazada'))
    into n_pend, n_aut, n_tot
  from operaciones.cotizaciones where orden_id = p_orden;

  nuevo := case
    when n_pend > 0 then 'por_autorizar'
    when n_aut  > 0 then 'autorizada'
    when not o.requiere_cotizacion then 'autorizada'
    when n_tot  > 0 then 'cotizacion'
    when o.estatus in ('por_autorizar','autorizada') then 'cotizacion'
    else o.estatus end;

  if nuevo is distinct from o.estatus then
    update operaciones.ordenes set estatus = nuevo, actualizado_en = now() where id = p_orden;
    perform operaciones.registrar(p_orden, 'estatus', 'Estatus: ' || nuevo, jsonb_build_object('de', o.estatus, 'a', nuevo));
    if nuevo = 'autorizada' then
      perform operaciones.avisar('taller', p_orden, 'pasar_a_linea',
        'OT-' || lpad(o.folio::text, 4, '0') || ' autorizada: lista para pasar a línea');
    end if;
  end if;
  return nuevo;
end $$;

-- ---------------------------------------------------------------- acciones
create or replace function operaciones.crear_orden(
  p_equipo uuid, p_tipo text, p_trabajos text[], p_prioridad text, p_descripcion text,
  p_patio smallint default null, p_revision uuid default null, p_cliente text default null,
  p_fecha_requerida date default null, p_requiere_cotizacion boolean default true,
  p_taller smallint default null, p_responsable uuid default null, p_responsable_texto text default null,
  p_fecha_compromiso date default null
) returns uuid
language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare v_id uuid; v_folio int; v_patio smallint; v_niv text;
begin
  if not core.puede_escribir('operaciones') then raise exception 'No tienes permiso para crear órdenes'; end if;
  if coalesce(trim(p_descripcion),'') = '' then raise exception 'Describe el trabajo a realizar'; end if;
  select coalesce(p_patio, patio_fisico_id, patio_id), niv into v_patio, v_niv from core.equipos where id = p_equipo;
  if v_niv is null then raise exception 'El equipo no existe'; end if;
  if exists (select 1 from operaciones.ordenes where equipo_id = p_equipo and tipo = p_tipo
             and estatus not in ('entregada','cancelada')) then
    raise exception 'El equipo % ya tiene una orden de % abierta', v_niv, p_tipo;
  end if;

  insert into operaciones.ordenes(equipo_id, patio_id, revision_id, tipo, trabajos, prioridad, descripcion,
    cliente, fecha_requerida, requiere_cotizacion, taller_id, responsable_id, responsable_texto, fecha_compromiso,
    estatus)
  values (p_equipo, v_patio, p_revision, p_tipo, coalesce(p_trabajos,'{}'), p_prioridad, trim(p_descripcion),
    nullif(trim(p_cliente),''), p_fecha_requerida, p_requiere_cotizacion, p_taller, p_responsable,
    nullif(trim(p_responsable_texto),''), p_fecha_compromiso,
    case when p_requiere_cotizacion then 'abierta' else 'autorizada' end)
  returning id, folio into v_id, v_folio;

  perform operaciones.registrar(v_id, 'alta', 'Orden creada: ' || trim(p_descripcion),
    jsonb_build_object('tipo', p_tipo, 'prioridad', p_prioridad, 'trabajos', p_trabajos));
  if p_prioridad = 'ticket' then
    perform operaciones.avisar('taller', v_id, 'ticket',
      'Ticket OT-' || lpad(v_folio::text,4,'0') || ' · ' || v_niv || ': ' || left(trim(p_descripcion), 80));
    perform operaciones.avisar('jefatura', v_id, 'ticket',
      'Ticket OT-' || lpad(v_folio::text,4,'0') || ' · ' || v_niv || ': ' || left(trim(p_descripcion), 80));
  end if;
  if not p_requiere_cotizacion then
    perform operaciones.avisar('taller', v_id, 'pasar_a_linea',
      'OT-' || lpad(v_folio::text,4,'0') || ' sin costo: lista para pasar a línea');
  end if;
  return v_id;
end $$;

create or replace function operaciones.agregar_cotizacion(
  p_orden uuid, p_concepto text, p_monto_sin_iva numeric, p_proveedor text default null,
  p_taller smallint default null, p_archivo text default null
) returns operaciones.cotizaciones
language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare o operaciones.ordenes; c operaciones.cotizaciones; v_acum numeric; v_nivel text; v_lim numeric; v_niv text;
begin
  if not core.puede_escribir('operaciones') then raise exception 'No tienes permiso para registrar cotizaciones'; end if;
  select * into o from operaciones.ordenes where id = p_orden for update;
  if o.id is null then raise exception 'La orden no existe'; end if;
  if o.estatus in ('terminada','entregada','cancelada') then
    raise exception 'La orden ya está %; no admite cotizaciones nuevas', o.estatus;
  end if;
  if coalesce(p_monto_sin_iva,0) <= 0 then raise exception 'El monto antes de IVA debe ser mayor a cero'; end if;
  if coalesce(trim(p_concepto),'') = '' then raise exception 'Escribe el concepto de la cotización'; end if;

  -- bloquea las cotizaciones del equipo para que dos altas simultáneas no se brinquen el tope
  perform 1 from operaciones.cotizaciones where equipo_id = o.equipo_id for update;
  v_lim  := operaciones.param('limite_autorizacion');
  v_acum := operaciones.acumulado_equipo(o.equipo_id) + round(p_monto_sin_iva, 2);
  v_nivel := case when v_acum > v_lim then 'gerencia' else 'jefatura' end;

  insert into operaciones.cotizaciones(orden_id, equipo_id, concepto, proveedor, taller_id, monto_sin_iva,
    iva_tasa, archivo_ruta, nivel_requerido, acumulado_equipo)
  values (p_orden, o.equipo_id, trim(p_concepto), nullif(trim(p_proveedor),''), p_taller, round(p_monto_sin_iva,2),
    operaciones.param('iva'), p_archivo, v_nivel, v_acum)
  returning * into c;

  select niv into v_niv from core.equipos where id = o.equipo_id;
  perform operaciones.registrar(p_orden, 'cotizacion',
    'Cotización por $' || to_char(c.monto_sin_iva, 'FM999,999,990.00') || ' antes de IVA (' || c.concepto || '). '
    || 'Acumulado del equipo: $' || to_char(v_acum, 'FM999,999,990.00') || '. Autoriza: ' ||
    case v_nivel when 'gerencia' then 'gerencia' else 'jefatura' end,
    jsonb_build_object('cotizacion_id', c.id, 'monto', c.monto_sin_iva, 'acumulado', v_acum, 'nivel', v_nivel));

  if o.estatus = 'abierta' then
    update operaciones.ordenes set estatus = 'cotizacion' where id = p_orden;
  end if;
  perform operaciones.recalcular_orden(p_orden);

  perform operaciones.avisar(v_nivel, p_orden, 'por_autorizar',
    'OT-' || lpad(o.folio::text,4,'0') || ' · ' || v_niv || ': cotización de $' ||
    to_char(c.monto_sin_iva,'FM999,999,990.00') || ' por autorizar' ||
    case when v_nivel='gerencia' then ' (acumulado $' || to_char(v_acum,'FM999,999,990.00') || ')' else '' end);
  if v_nivel = 'gerencia' then
    perform operaciones.avisar('jefatura', p_orden, 'por_autorizar',
      'OT-' || lpad(o.folio::text,4,'0') || ' · ' || v_niv || ': cotización para gerencia, puedes dar visto bueno');
  end if;
  return c;
end $$;

create or replace function operaciones.resolver_cotizacion(p_id uuid, p_autorizar boolean, p_texto text)
returns operaciones.cotizaciones
language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare c operaciones.cotizaciones; o operaciones.ordenes; v_mi text; v_acum numeric; v_req text; v_lim numeric;
begin
  v_mi := operaciones.mi_nivel_autorizacion();
  if v_mi is null then raise exception 'No estás registrado como autorizador de cotizaciones'; end if;

  select * into c from operaciones.cotizaciones where id = p_id;
  if c.id is null then raise exception 'La cotización no existe'; end if;
  perform 1 from operaciones.cotizaciones where equipo_id = c.equipo_id for update;
  select * into c from operaciones.cotizaciones where id = p_id;
  if c.estatus <> 'pendiente' then raise exception 'La cotización ya está %', c.estatus; end if;
  select * into o from operaciones.ordenes where id = c.orden_id;

  -- el nivel se vuelve a calcular con la situación actual del equipo
  v_lim  := operaciones.param('limite_autorizacion');
  v_acum := operaciones.acumulado_para_resolver(c.id);
  v_req  := case when v_acum > v_lim then 'gerencia' else 'jefatura' end;

  if p_autorizar then
    if v_req = 'gerencia' and v_mi <> 'gerencia' then
      raise exception 'El acumulado del equipo es $% antes de IVA y supera el tope de $%: la autoriza la gerencia',
        to_char(v_acum,'FM999,999,990.00'), to_char(v_lim,'FM999,999,990');
    end if;
    if v_mi = 'jefatura' and coalesce(trim(p_texto),'') = '' then
      raise exception 'Escribe la justificación de la autorización';
    end if;
  else
    if coalesce(trim(p_texto),'') = '' then raise exception 'Escribe el motivo del rechazo'; end if;
  end if;

  update operaciones.cotizaciones
     set estatus = case when p_autorizar then 'autorizada' else 'rechazada' end,
         nivel_requerido = v_req, acumulado_equipo = v_acum,
         resuelto_por = auth.uid(), resuelto_en = now(), justificacion = nullif(trim(p_texto),'')
   where id = p_id
  returning * into c;

  perform operaciones.registrar(c.orden_id, case when p_autorizar then 'autorizacion' else 'rechazo' end,
    case when p_autorizar then 'Cotización autorizada' else 'Cotización rechazada' end
    || ' ($' || to_char(c.monto_sin_iva,'FM999,999,990.00') || ' antes de IVA, ' || c.concepto || ')'
    || coalesce(': ' || c.justificacion, ''),
    jsonb_build_object('cotizacion_id', c.id, 'nivel', v_mi, 'acumulado', v_acum));
  perform operaciones.avisar('perfil', c.orden_id, case when p_autorizar then 'autorizada' else 'rechazada' end,
    'OT-' || lpad(o.folio::text,4,'0') || ': cotización de $' || to_char(c.monto_sin_iva,'FM999,999,990.00')
    || case when p_autorizar then ' autorizada' else ' rechazada' end, c.creado_por);
  perform operaciones.recalcular_orden(c.orden_id);
  return c;
end $$;

create or replace function operaciones.visto_bueno(p_id uuid, p_nota text)
returns void language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare c operaciones.cotizaciones;
begin
  if operaciones.mi_nivel_autorizacion() is null then raise exception 'No estás registrado como autorizador'; end if;
  select * into c from operaciones.cotizaciones where id = p_id;
  if c.estatus <> 'pendiente' then raise exception 'La cotización ya está %', c.estatus; end if;
  update operaciones.cotizaciones set vobo_por = auth.uid(), vobo_en = now(), vobo_nota = nullif(trim(p_nota),'')
   where id = p_id;
  perform operaciones.registrar(c.orden_id, 'visto_bueno',
    'Visto bueno a cotización de $' || to_char(c.monto_sin_iva,'FM999,999,990.00') || coalesce(': ' || nullif(trim(p_nota),''), ''));
  perform operaciones.avisar('gerencia', c.orden_id, 'visto_bueno',
    'Visto bueno de jefatura a cotización de $' || to_char(c.monto_sin_iva,'FM999,999,990.00'));
end $$;

create or replace function operaciones.cancelar_cotizacion(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare c operaciones.cotizaciones;
begin
  select * into c from operaciones.cotizaciones where id = p_id;
  if c.id is null then raise exception 'La cotización no existe'; end if;
  if c.creado_por <> auth.uid() and operaciones.mi_nivel_autorizacion() is null then
    raise exception 'Solo quien la registró o un autorizador puede cancelarla';
  end if;
  if c.estatus <> 'pendiente' then raise exception 'Solo se cancelan cotizaciones pendientes'; end if;
  update operaciones.cotizaciones set estatus = 'cancelada', resuelto_por = auth.uid(), resuelto_en = now(),
         justificacion = nullif(trim(p_motivo),'') where id = p_id;
  perform operaciones.registrar(c.orden_id, 'cotizacion_cancelada',
    'Cotización cancelada ($' || to_char(c.monto_sin_iva,'FM999,999,990.00') || ')' || coalesce(': ' || nullif(trim(p_motivo),''), ''));
  perform operaciones.recalcular_orden(c.orden_id);
end $$;

-- cambios de estatus del trabajo: iniciar en línea / taller externo, terminar, entregar, cancelar
create or replace function operaciones.cambiar_estatus(
  p_orden uuid, p_estatus text, p_nota text default null,
  p_linea smallint default null, p_forzar boolean default false
) returns void
language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare o operaciones.ordenes; l operaciones.lineas; n_pend int; n_aut int; v_ocupa int; v_txt text;
begin
  if not core.puede_escribir('operaciones') then raise exception 'No tienes permiso para mover órdenes'; end if;
  select * into o from operaciones.ordenes where id = p_orden for update;
  if o.id is null then raise exception 'La orden no existe'; end if;

  if p_estatus = 'en_proceso' then
    if o.estatus not in ('autorizada','en_proceso') then
      select count(*) filter (where estatus='pendiente'), count(*) filter (where estatus='autorizada')
        into n_pend, n_aut from operaciones.cotizaciones where orden_id = p_orden;
      if n_pend > 0 then raise exception 'Hay cotizaciones pendientes de autorizar; no puede iniciar el trabajo'; end if;
      if o.requiere_cotizacion and n_aut = 0 then
        raise exception 'La orden no tiene cotización autorizada; no puede iniciar el trabajo';
      end if;
    end if;
    if p_linea is not null then
      select * into l from operaciones.lineas where id = p_linea and activo;
      if l.id is null then raise exception 'La línea no existe'; end if;
      select count(*) into v_ocupa from operaciones.ordenes
       where linea_id = p_linea and estatus = 'en_proceso' and id <> p_orden;
      if v_ocupa > 0 then raise exception '% está ocupada', l.nombre; end if;
      if l.uso = 'prioritaria' and o.prioridad <> 'ticket' and not p_forzar then
        raise exception '% es para equipos con ticket; la línea general es para recuperados sin asignar', l.nombre;
      end if;
      if l.uso = 'general' and o.prioridad = 'ticket' and not p_forzar then
        raise exception '% es para recuperados sin asignar; usa una línea prioritaria', l.nombre;
      end if;
      if p_forzar and coalesce(trim(p_nota),'') = '' then
        raise exception 'Escribe por qué se usa esta línea fuera de su regla';
      end if;
    end if;
    update operaciones.ordenes set estatus = 'en_proceso', linea_id = p_linea,
           fecha_inicio = coalesce(fecha_inicio, now()), actualizado_en = now() where id = p_orden;
    v_txt := case when p_linea is null then 'Trabajo iniciado' else 'Pasa a ' || l.nombre end;

  elsif p_estatus = 'terminada' then
    if o.estatus <> 'en_proceso' then raise exception 'Solo se termina una orden en proceso'; end if;
    update operaciones.ordenes set estatus = 'terminada', fecha_termino = now(), actualizado_en = now() where id = p_orden;
    v_txt := 'Trabajo terminado';
    perform operaciones.avisar('jefatura', p_orden, 'terminada', 'OT-' || lpad(o.folio::text,4,'0') || ' terminada');
    perform operaciones.avisar('perfil', p_orden, 'terminada', 'OT-' || lpad(o.folio::text,4,'0') || ' terminada', o.creado_por);

  elsif p_estatus = 'entregada' then
    if o.estatus <> 'terminada' then raise exception 'Primero marca la orden como terminada'; end if;
    update operaciones.ordenes set estatus = 'entregada', fecha_entrega = now(), actualizado_en = now() where id = p_orden;
    v_txt := 'Equipo entregado / liberado';

  elsif p_estatus = 'cancelada' then
    if o.estatus in ('entregada','cancelada') then raise exception 'La orden ya está %', o.estatus; end if;
    if coalesce(trim(p_nota),'') = '' then raise exception 'Escribe el motivo de la cancelación'; end if;
    update operaciones.ordenes set estatus = 'cancelada', motivo_cancelacion = trim(p_nota), actualizado_en = now() where id = p_orden;
    update operaciones.cotizaciones set estatus = 'cancelada', resuelto_por = auth.uid(), resuelto_en = now()
     where orden_id = p_orden and estatus = 'pendiente';
    v_txt := 'Orden cancelada';

  elsif p_estatus = 'liberar_linea' then
    if o.estatus <> 'en_proceso' then raise exception 'La orden no está en proceso'; end if;
    update operaciones.ordenes set estatus = 'autorizada', linea_id = null, actualizado_en = now() where id = p_orden;
    v_txt := 'Sale de la línea y regresa a la cola';
  else
    raise exception 'Estatus no válido: %', p_estatus;
  end if;

  perform operaciones.registrar(p_orden, 'estatus', v_txt || coalesce(': ' || nullif(trim(p_nota),''), ''),
    jsonb_build_object('de', o.estatus, 'a', p_estatus, 'linea', p_linea, 'forzado', p_forzar));
end $$;

create or replace function operaciones.comentar(p_orden uuid, p_texto text)
returns void language plpgsql security definer set search_path to 'operaciones','core','public' as $$
begin
  if not core.puede_escribir('operaciones') then raise exception 'No tienes permiso para comentar'; end if;
  if coalesce(trim(p_texto),'') = '' then return; end if;
  insert into operaciones.bitacora(orden_id, tipo, texto) values (p_orden, 'comentario', trim(p_texto));
end $$;

create or replace function operaciones.marcar_avisos_leidos(p_ids bigint[])
returns void language sql security definer set search_path to 'operaciones','public' as $$
  insert into operaciones.avisos_leidos(aviso_id, perfil_id)
  select x, auth.uid() from unnest(p_ids) x on conflict do nothing;
$$;

-- ---------------------------------------------------------------- vistas
create or replace view operaciones.v_ordenes with (security_invoker = true) as
select o.*,
  'OT-' || lpad(o.folio::text, 4, '0') as folio_txt,
  e.niv, e.placa, e.anio, te.nombre as tipo_equipo, m.nombre as marca,
  e.estatus_asignacion, e.estatus_operativo, e.cliente_actual,
  pa.nombre as patio, t.nombre as taller, t.tipo as taller_tipo,
  l.nombre as linea, l.numero as linea_numero, l.uso as linea_uso,
  coalesce(core.nombre_perfil(o.responsable_id), o.responsable_texto) as responsable,
  core.nombre_perfil(o.creado_por) as creado_por_nombre,
  coalesce(c.cotizado, 0) as cotizado_sin_iva,
  coalesce(c.autorizado, 0) as autorizado_sin_iva,
  coalesce(c.pendientes, 0) as cotizaciones_pendientes,
  c.nivel_pendiente,
  coalesce(f.fotos, 0) as fotos,
  (o.fecha_compromiso is not null and o.fecha_compromiso < current_date
     and o.estatus not in ('terminada','entregada','cancelada')) as atrasada
from operaciones.ordenes o
join core.equipos e on e.id = o.equipo_id
left join core.tipos_equipo te on te.id = e.tipo_id
left join core.marcas m on m.id = e.marca_id
left join core.patios pa on pa.id = o.patio_id
left join operaciones.talleres t on t.id = o.taller_id
left join operaciones.lineas l on l.id = o.linea_id
left join lateral (
  select sum(monto_sin_iva) filter (where estatus in ('pendiente','autorizada')) cotizado,
         sum(monto_sin_iva) filter (where estatus = 'autorizada') autorizado,
         count(*) filter (where estatus = 'pendiente') pendientes,
         case when bool_or(nivel_requerido = 'gerencia') filter (where estatus = 'pendiente') then 'gerencia'
              when count(*) filter (where estatus = 'pendiente') > 0 then 'jefatura' end nivel_pendiente
  from operaciones.cotizaciones where orden_id = o.id) c on true
left join lateral (select count(*) fotos from operaciones.orden_fotos where orden_id = o.id) f on true;

create or replace view operaciones.v_cotizaciones with (security_invoker = true) as
select c.*, o.folio, 'OT-' || lpad(o.folio::text, 4, '0') as folio_txt, o.estatus as estatus_orden,
  o.descripcion as orden_descripcion, o.prioridad, e.niv, e.placa, pa.nombre as patio,
  core.nombre_perfil(c.creado_por) as creado_por_nombre, core.nombre_perfil(c.resuelto_por) as resuelto_por_nombre,
  core.nombre_perfil(c.vobo_por) as vobo_por_nombre,
  t.nombre as taller
from operaciones.cotizaciones c
join operaciones.ordenes o on o.id = c.orden_id
join core.equipos e on e.id = c.equipo_id
left join core.patios pa on pa.id = o.patio_id
left join operaciones.talleres t on t.id = c.taller_id;

create or replace view operaciones.v_revisiones with (security_invoker = true) as
select r.*, e.niv, e.placa, pa.nombre as patio, core.nombre_perfil(r.creado_por) as creado_por_nombre,
  (select count(*) from operaciones.orden_fotos f where f.revision_id = r.id) as fotos,
  (select o.id from operaciones.ordenes o where o.revision_id = r.id limit 1) as orden_id
from operaciones.revisiones r
join core.equipos e on e.id = r.equipo_id
left join core.patios pa on pa.id = r.patio_id;

create or replace view operaciones.v_bitacora with (security_invoker = true) as
select b.*, core.nombre_perfil(b.por) as por_nombre from operaciones.bitacora b;

create or replace view operaciones.v_fotos with (security_invoker = true) as
select f.foto_id, f.orden_id, f.revision_id, f.etapa, f.nota, cf.ruta_storage, cf.tomada_en, cf.subida_por,
  core.nombre_perfil(cf.subida_por) as subida_por_nombre
from operaciones.orden_fotos f
join core.fotos cf on cf.id = f.foto_id;

-- avisos que le tocan a quien consulta
create or replace function operaciones.mis_avisos(p_limite int default 40)
returns table(id bigint, orden_id uuid, tipo text, texto text, creado_en timestamptz, leido boolean)
language sql stable security definer set search_path to 'operaciones','core','public' as $$
  select a.id, a.orden_id, a.tipo, a.texto, a.creado_en,
         exists (select 1 from operaciones.avisos_leidos l where l.aviso_id = a.id and l.perfil_id = auth.uid())
  from operaciones.avisos a
  where core.puede_leer('operaciones')
    and ( (a.audiencia = 'perfil'   and a.perfil_id = auth.uid())
       or (a.audiencia = 'gerencia' and operaciones.mi_nivel_autorizacion() = 'gerencia')
       or (a.audiencia = 'jefatura' and operaciones.mi_nivel_autorizacion() = 'jefatura')
       or (a.audiencia = 'taller'   and (operaciones.es_taller() or operaciones.mi_nivel_autorizacion() = 'jefatura' or core.es_admin())) )
    and a.creado_en > now() - interval '30 days'
  order by a.creado_en desc
  limit p_limite
$$;

-- ---------------------------------------------------------------- seguridad
alter table operaciones.parametros    enable row level security;
alter table operaciones.autorizadores enable row level security;
alter table operaciones.talleres      enable row level security;
alter table operaciones.tipos_trabajo enable row level security;
alter table operaciones.lineas        enable row level security;
alter table operaciones.revisiones    enable row level security;
alter table operaciones.ordenes       enable row level security;
alter table operaciones.cotizaciones  enable row level security;
alter table operaciones.orden_fotos   enable row level security;
alter table operaciones.bitacora      enable row level security;
alter table operaciones.avisos        enable row level security;
alter table operaciones.avisos_leidos enable row level security;

do $$
declare t text;
begin
  foreach t in array array['parametros','autorizadores','talleres','tipos_trabajo','lineas','revisiones',
                           'ordenes','cotizaciones','orden_fotos','bitacora'] loop
    execute format('drop policy if exists leer on operaciones.%I', t);
    execute format('create policy leer on operaciones.%I for select to authenticated using (core.puede_leer(''operaciones''))', t);
  end loop;
end $$;

drop policy if exists leer on operaciones.avisos;
create policy leer on operaciones.avisos for select to authenticated using (
  core.puede_leer('operaciones') and (
       (audiencia = 'perfil'   and perfil_id = auth.uid())
    or (audiencia = 'gerencia' and operaciones.mi_nivel_autorizacion() = 'gerencia')
    or (audiencia = 'jefatura' and operaciones.mi_nivel_autorizacion() = 'jefatura')
    or (audiencia = 'taller'   and (operaciones.es_taller() or operaciones.mi_nivel_autorizacion() = 'jefatura' or core.es_admin()))));
drop policy if exists leer on operaciones.avisos_leidos;
create policy leer on operaciones.avisos_leidos for select to authenticated using (perfil_id = auth.uid());

drop policy if exists alta on operaciones.revisiones;
create policy alta on operaciones.revisiones for insert to authenticated
  with check (core.puede_escribir('operaciones') and creado_por = auth.uid());

drop policy if exists editar on operaciones.ordenes;
create policy editar on operaciones.ordenes for update to authenticated
  using (core.puede_escribir('operaciones')) with check (core.puede_escribir('operaciones'));

drop policy if exists alta on operaciones.orden_fotos;
create policy alta on operaciones.orden_fotos for insert to authenticated
  with check (core.puede_escribir('operaciones'));

do $$
declare t text;
begin
  foreach t in array array['talleres','tipos_trabajo','lineas'] loop
    execute format('drop policy if exists configurar on operaciones.%I', t);
    execute format('create policy configurar on operaciones.%I for all to authenticated using (operaciones.puede_configurar()) with check (operaciones.puede_configurar())', t);
  end loop;
end $$;

drop policy if exists configurar on operaciones.parametros;
create policy configurar on operaciones.parametros for update to authenticated
  using (core.es_admin() or operaciones.mi_nivel_autorizacion() = 'gerencia')
  with check (core.es_admin() or operaciones.mi_nivel_autorizacion() = 'gerencia');

drop policy if exists configurar on operaciones.autorizadores;
create policy configurar on operaciones.autorizadores for all to authenticated
  using (core.es_admin() or operaciones.mi_nivel_autorizacion() = 'gerencia')
  with check (core.es_admin() or operaciones.mi_nivel_autorizacion() = 'gerencia');

grant select on all tables in schema operaciones to authenticated;
grant insert on operaciones.revisiones, operaciones.orden_fotos to authenticated;
-- en órdenes solo se editan datos generales; el estatus y la línea van por cambiar_estatus()
grant update (trabajos, prioridad, descripcion, cliente, fecha_requerida, taller_id, responsable_id,
              responsable_texto, fecha_compromiso, actualizado_en) on operaciones.ordenes to authenticated;
grant insert, update, delete on operaciones.talleres, operaciones.tipos_trabajo, operaciones.lineas to authenticated;
grant insert, update, delete on operaciones.autorizadores to authenticated;
grant update (valor, actualizado_por, actualizado_en) on operaciones.parametros to authenticated;
revoke all on all tables in schema operaciones from anon;

revoke execute on all functions in schema operaciones from public, anon;
grant execute on all functions in schema operaciones to authenticated;

-- adjuntos de cotizaciones (PDF o imagen)
insert into storage.buckets(id, name, public, file_size_limit)
values ('operaciones-adjuntos', 'operaciones-adjuntos', false, 15728640)
on conflict (id) do nothing;
drop policy if exists "operaciones adjuntos leer" on storage.objects;
create policy "operaciones adjuntos leer" on storage.objects for select to authenticated
  using (bucket_id = 'operaciones-adjuntos' and core.puede_leer('operaciones'));
drop policy if exists "operaciones adjuntos subir" on storage.objects;
create policy "operaciones adjuntos subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'operaciones-adjuntos' and core.puede_escribir('operaciones'));

-- avisos en tiempo real
do $$ begin
  alter publication supabase_realtime add table operaciones.avisos;
exception when others then null; end $$;

-- exponer el esquema a la API
alter role authenticator set pgrst.db_schemas =
  'public, graphql_public, core, gastos, documentos, inventario, catalogos, movimientos, reporting, operaciones';
notify pgrst, 'reload config';
notify pgrst, 'reload schema';

-- =====================================================================
-- Ajuste tras pruebas: al AUTORIZAR, el acumulado cuenta lo ya autorizado
-- del equipo + lo pendiente enviado ANTES que esta cotización + esta misma.
-- Así, si c1=9,000 (autorizada), c2=6,000 y c3=500 están pendientes,
-- c2 suma 15,000 (jefatura) y c3 suma 15,500 (gerencia).
-- =====================================================================
alter table operaciones.cotizaciones alter column creado_en set default clock_timestamp();

create or replace function operaciones.acumulado_para_resolver(p_cot uuid)
returns numeric
language sql stable security definer set search_path to 'operaciones','public' as $$
  select coalesce(sum(c.monto_sin_iva), 0)
  from operaciones.cotizaciones x
  join operaciones.cotizaciones c on c.equipo_id = x.equipo_id
  join operaciones.ordenes o on o.id = c.orden_id
  where x.id = p_cot
    and ( c.id = x.id
       or c.estatus = 'autorizada'
       or (c.estatus = 'pendiente' and (c.creado_en, c.id) < (x.creado_en, x.id)) )
    and ( c.id = x.id or o.estatus not in ('entregada','cancelada')
       or c.creado_en >= now() - make_interval(days => operaciones.param('ventana_acumulado_dias')::int) )
$$;
grant execute on function operaciones.acumulado_para_resolver(uuid) to authenticated;
-- operaciones.resolver_cotizacion usa: v_acum := operaciones.acumulado_para_resolver(c.id);

-- =====================================================================
-- Ajuste: core.perfiles solo deja ver el perfil propio, así que las vistas
-- toman los nombres con core.nombre_perfil() (security definer).
-- Las vistas v_ordenes, v_cotizaciones, v_revisiones, v_bitacora y v_fotos
-- se redefinieron así en la base (mismas columnas).
-- operaciones.personal(): lista de gente de Operaciones/taller y autorizadores.
-- =====================================================================
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
    and (a.perfil_id is not null or pr.rol in ('operaciones','taller','admin'))
  group by p.id, p.nombre, p.puesto, a.nivel, a.activo
  order by p.nombre
$$;
grant execute on function operaciones.personal() to authenticated;

-- =====================================================================
-- Accesos definidos por Rogelio Morejón (2026-10-18)
--   Solo consulta: Servicio a Clientes (rol servicio_clientes), César Valadez
--     (rol nuevo operaciones_consulta) y José Villarreal (ya por consulta_general).
--   Capturan y llevan el proceso sin autorizar: Aldair Castellanos y Salvador Martínez (rol operaciones).
--   Autorizan: Ilse Cortés y Rogelio Morejón (jefatura), Francisco Mendoza (gerencia).
-- =====================================================================
insert into core.roles(clave, nombre) values ('operaciones_consulta','Operaciones y taller · Solo consulta') on conflict (clave) do nothing;
insert into core.rol_modulos(rol, modulo, nivel)
select 'operaciones_consulta','operaciones','lectura'
where not exists (select 1 from core.rol_modulos where rol='operaciones_consulta' and modulo='operaciones');
insert into core.perfil_roles(perfil_id, rol)
select id, 'operaciones_consulta' from core.perfiles where correo = 'cesar.valadez@htrent.mx'
on conflict do nothing;
