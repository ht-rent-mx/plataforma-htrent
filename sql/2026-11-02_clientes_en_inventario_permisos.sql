-- =====================================================================
-- 2026-11-02 · Seguimiento a Clientes dentro de Inventario (pedido de Rogelio)
-- ---------------------------------------------------------------------
-- Regla de acceso al módulo 'clientes':
--   * Editan: admin (Rogelio) y servicio_clientes (ejecutivos de SC).
--   * Legal conserva su permiso acotado: solo ve y dictamina tarjetas
--     "En Dictamen" (lo controla public.sc_es_legal(), no cambia).
--   * Todos los demás usuarios de Inventario: solo lectura.
-- Antes, documentos y operaciones también editaban.
-- =====================================================================

update core.rol_modulos set nivel = 'lectura'
where modulo = 'clientes' and rol in ('documentos', 'operaciones');

insert into core.rol_modulos (rol, modulo, nivel)
select r, 'clientes', 'lectura'
from unnest(array['inventario_admin','inventario_editor','inventario_lectura',
                  'inventario_solicitante','operaciones_consulta','movimientos_editor','uno_a_uno']) r
where not exists (select 1 from core.rol_modulos rm where rm.rol = r and rm.modulo = 'clientes');
