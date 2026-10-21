-- 21-oct-2026 · Entradas y salidas: GPS como adicional
-- Ya aplicado en producción. El número de serie viaja en core.movimientos.adicionales
-- (campo "serie" del elemento GPS) y la foto en core.fotos con angulo = 'GPS'.
insert into core.catalogo_adicionales (nombre, se_cuenta, activo)
select 'GPS', false, true
where not exists (select 1 from core.catalogo_adicionales where upper(nombre) = 'GPS');
