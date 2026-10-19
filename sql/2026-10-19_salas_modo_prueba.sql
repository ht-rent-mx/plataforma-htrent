-- =====================================================================
-- Plataforma HT · Salas de juntas · MODO PRUEBA (2026-10-19)
--
-- Mientras core.salas_config.modo_prueba = 'si':
--   * cada reserva nueva se marca como prueba (es_prueba = true);
--   * bloquea la sala igual que una real, para poder probar el candado;
--   * la invitación de Outlook SOLO le llega a quien reservó, con
--     "[PRUEBA]" en el asunto y la lista de a quiénes se habría invitado.
--
-- Para salir del modo prueba (cuando todo esté verificado):
--   select core.salas_borrar_pruebas();   -- cancela y borra las de prueba
--   update core.salas_config set valor = 'no' where clave = 'modo_prueba';
--
-- Correr después de 2026-10-19_modulo_salas.sql. Se puede correr de nuevo.
-- =====================================================================

alter table core.sala_reservas add column if not exists es_prueba boolean not null default false;

insert into core.salas_config (clave, valor) values ('modo_prueba', 'si')
on conflict (clave) do nothing;

-- ¿Está activo el modo prueba? (la página lo usa para mostrar el aviso)
create or replace function core.salas_en_prueba()
returns boolean language sql stable security definer
set search_path to 'core','public'
as $$ select coalesce((select valor from core.salas_config where clave = 'modo_prueba'), 'no') = 'si' $$;

revoke all on function core.salas_en_prueba() from public, anon;
grant execute on function core.salas_en_prueba() to authenticated;

-- Toda reserva nueva hereda el modo vigente
create or replace function core._salas_marcar_prueba()
returns trigger language plpgsql security definer
set search_path to 'core','public'
as $$
begin
  new.es_prueba := core.salas_en_prueba();
  return new;
end $$;

drop trigger if exists sala_reservas_marcar_prueba on core.sala_reservas;
create trigger sala_reservas_marcar_prueba
  before insert on core.sala_reservas
  for each row execute function core._salas_marcar_prueba();

-- Aviso a Power Automate, ahora con el caso de prueba
create or replace function core._salas_notificar()
returns trigger
language plpgsql security definer
set search_path to 'core','public','extensions'
as $$
declare
  v_url text; v_app text; v_secreto text; v_accion text; v_sala text;
  v_asist text; v_lista text; v_cuerpo text; v_req bigint;
  v_meses text[] := array['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
  v_dias  text[] := array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'];
  v_loc timestamp := new.inicio at time zone 'America/Mexico_City';
  v_fecha text;
  v_lista_real text;
begin
  v_accion := case
    when tg_op = 'INSERT' then 'crear'
    when new.estado = 'cancelada' and old.estado = 'activa' then 'cancelar'
    else 'modificar' end;

  select max(valor) filter (where clave='flujo_url'),
         max(valor) filter (where clave='app_url'),
         max(valor) filter (where clave='secreto_flujo')
    into v_url, v_app, v_secreto
  from core.salas_config;

  if coalesce(v_url,'') = '' then
    insert into core.sala_notificaciones (reserva_id, accion, estado, detalle)
    values (new.id, v_accion, 'sin_flujo', 'Aún no hay URL de Power Automate en core.salas_config');
    return new;
  end if;

  select nombre into v_sala from core.salas where id = new.sala_id;

  select string_agg(c, ';'), string_agg('<li>' || core._salas_html(coalesce(n, c)) || '</li>', '')
    into v_asist, v_lista
  from (
    select distinct on (c) c, n from (
      select lower(new.organizador_correo) c, new.organizador_nombre n, 0 o
      union all
      select lower(x->>'correo'), x->>'nombre', 1 from jsonb_array_elements(new.participantes) x
    ) s where coalesce(c,'') <> '' order by c, o
  ) t;

  -- MODO PRUEBA: la invitación solo le llega a quien reservó
  if new.es_prueba then
    v_lista_real := v_lista;
    v_asist := lower(new.organizador_correo);
  end if;

  v_fecha := v_dias[extract(dow from v_loc)::int + 1] || ' ' || extract(day from v_loc)::int || ' de '
             || v_meses[extract(month from v_loc)::int] || ' de ' || extract(year from v_loc)::int;

  v_cuerpo :=
    '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#15203B">'
    || '<div style="background:#0B3D66;color:#fff;padding:14px 18px;border-bottom:5px solid #3CE81E">'
    || '<b style="font-size:18px">Sala ' || core._salas_html(v_sala) || '</b><br>'
    || '<span style="color:#B9C8DC">Reserva de sala de juntas · HT Rent</span></div>'
    || '<div style="padding:14px 18px;border:1px solid #D5DBE5;border-top:0">'
    || case when new.es_prueba
            then '<p style="background:#FDF1D6;border-left:5px solid #F2B233;padding:8px 10px;color:#5A3D00">'
                 || '<b>RESERVA DE PRUEBA.</b> Esta invitación solo te llegó a ti. En operación normal '
                 || 'también la habrían recibido:</p><ul>' || coalesce(v_lista_real,'') || '</ul>'
            else '' end
    || case when v_accion = 'cancelar'
            then '<p style="color:#C63A2F;font-weight:bold">Esta reunión fue CANCELADA.'
                 || coalesce(' Motivo: ' || core._salas_html(new.motivo_cancelacion), '') || '</p>'
            else '' end
    || '<p><b>' || core._salas_html(new.titulo) || '</b></p>'
    || '<p>' || v_fecha || '<br>' || core._salas_hora(new.inicio) || ' a ' || core._salas_hora(new.fin) || ' h</p>'
    || '<p>Reservó: ' || core._salas_html(coalesce(new.organizador_nombre, new.organizador_correo)) || '</p>'
    || coalesce('<p>' || replace(core._salas_html(new.descripcion), E'\n', '<br>') || '</p>', '')
    || '<p style="margin-bottom:4px">Participantes:</p><ul style="margin-top:0">' || coalesce(v_lista,'') || '</ul>'
    || '<p style="font-size:12px;color:#5A6680">Las salas se apartan en la Plataforma HT: '
    || '<a href="' || coalesce(v_app,'') || '">' || coalesce(v_app,'') || '</a></p>'
    || '</div></div>';

  v_req := net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type','application/json'),
    body    := jsonb_build_object(
      'accion',             v_accion,
      'reserva_id',         new.id,
      'outlook_evento_id',  coalesce(new.outlook_evento_id, ''),
      'sala',               v_sala,
      'titulo',             new.titulo,
      'asunto',             case when new.es_prueba then '[PRUEBA] ' else '' end
                            || case when v_accion = 'cancelar' then 'Cancelada: ' else '' end
                            || new.titulo || ' · Sala ' || v_sala,
      'inicio',             to_char(new.inicio at time zone 'America/Mexico_City', 'YYYY-MM-DD"T"HH24:MI:SS'),
      'fin',                to_char(new.fin    at time zone 'America/Mexico_City', 'YYYY-MM-DD"T"HH24:MI:SS'),
      'fecha_texto',        v_fecha || ', ' || core._salas_hora(new.inicio) || ' a ' || core._salas_hora(new.fin) || ' h',
      'organizador_nombre', coalesce(new.organizador_nombre, ''),
      'organizador_correo', coalesce(new.organizador_correo, ''),
      'asistentes',         coalesce(v_asist, ''),
      'motivo',             coalesce(new.motivo_cancelacion, ''),
      'cuerpo_html',        v_cuerpo,
      'secreto',            v_secreto
    )
  );

  insert into core.sala_notificaciones (reserva_id, accion, estado, solicitud)
  values (new.id, v_accion, 'enviado', v_req);
  return new;

exception when others then
  -- un problema con el correo nunca debe impedir la reserva
  insert into core.sala_notificaciones (reserva_id, accion, estado, detalle)
  values (new.id, v_accion, 'error', sqlerrm);
  return new;
end $$;


-- Borra las reservas de prueba (solo administrador). Las que aún no pasan
-- se cancelan primero, para que Outlook quite el evento de tu calendario.
create or replace function core.salas_borrar_pruebas()
returns int
language plpgsql security definer
set search_path to 'core','public'
as $$
declare n int;
begin
  if not core.es_admin() then
    raise exception 'Solo un administrador puede borrar las reservas de prueba';
  end if;
  update core.sala_reservas
     set estado = 'cancelada', motivo_cancelacion = 'Fin de las pruebas', cancelada_por = auth.uid(),
         cancelada_en = now(), actualizado_en = now()
   where es_prueba and estado = 'activa' and fin > now();
  delete from core.sala_reservas where es_prueba;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function core.salas_borrar_pruebas() from public, anon;
grant execute on function core.salas_borrar_pruebas() to authenticated;
