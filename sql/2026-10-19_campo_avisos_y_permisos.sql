-- =====================================================================
-- Plataforma HT · App "Operaciones en patio" (campo.html) · 2026-10-19
--
-- 1) Aviso a la jefatura cuando un asistente cierra una inspección con
--    daños o propuesta de baja, sin abrir la función interna avisar().
-- 2) Corrección de seguridad: operaciones.avisar() y operaciones.registrar()
--    son funciones internas pero cualquiera con la llave pública (incluso sin
--    iniciar sesión) podía llamarlas y meter avisos o renglones de historial
--    falsos. Se cierran; las funciones que las usan por dentro siguen igual.
-- =====================================================================

create or replace function operaciones.avisar_revision(p_revision uuid, p_orden uuid, p_texto text)
returns void language plpgsql security definer set search_path to 'operaciones','core','public' as $$
declare r operaciones.revisiones;
begin
  if not coalesce(core.puede_escribir('operaciones'), false) then raise exception 'No tienes permiso para avisar'; end if;
  select * into r from operaciones.revisiones where id = p_revision;
  if r.id is null then raise exception 'La revisión no existe'; end if;
  if r.creado_por <> auth.uid() then raise exception 'Solo quien hizo la revisión puede avisar'; end if;
  if p_orden is not null and not exists (select 1 from operaciones.ordenes where id = p_orden and equipo_id = r.equipo_id) then
    raise exception 'La orden no corresponde al equipo revisado';
  end if;
  if coalesce(trim(p_texto),'') = '' then return; end if;
  perform operaciones.avisar('jefatura', p_orden, 'revision', left(trim(p_texto), 300));
end $$;
revoke execute on function operaciones.avisar_revision(uuid, uuid, text) from public, anon;
grant execute on function operaciones.avisar_revision(uuid, uuid, text) to authenticated;

revoke execute on function operaciones.avisar(text, uuid, text, text, uuid) from public, anon, authenticated;
revoke execute on function operaciones.registrar(uuid, text, text, jsonb) from public, anon, authenticated;
