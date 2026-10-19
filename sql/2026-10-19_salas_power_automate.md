# Salas de juntas · Flujo de Power Automate (invitaciones de Outlook)

Cada vez que alguien **reserva, modifica o cancela** una sala en la Plataforma HT, Supabase manda un aviso a este flujo. El flujo crea, actualiza o borra el evento en Outlook y Outlook se encarga de mandar la **invitación (o la cancelación) a todos los participantes**, que les queda en su calendario.

Las invitaciones salen desde la cuenta con la que se cree el flujo (la tuya, juan.morejon@htrent.mx). Si más adelante Sistemas da una cuenta tipo `salas@htrent.mx`, basta con cambiar la conexión de Outlook del flujo a esa cuenta.

---

## 1. Crear el flujo

Power Automate → **Crear** → **Flujo de nube instantáneo** → nombre: `Salas de juntas HT` → desencadenador **"Cuando se recibe una solicitud HTTP"** (When an HTTP request is received).

- **Quién puede desencadenar el flujo:** Cualquiera
- **Esquema JSON del cuerpo de la solicitud** (pegar tal cual):

```json
{
  "type": "object",
  "properties": {
    "accion": { "type": "string" },
    "reserva_id": { "type": "string" },
    "outlook_evento_id": { "type": "string" },
    "sala": { "type": "string" },
    "titulo": { "type": "string" },
    "asunto": { "type": "string" },
    "inicio": { "type": "string" },
    "fin": { "type": "string" },
    "fecha_texto": { "type": "string" },
    "organizador_nombre": { "type": "string" },
    "organizador_correo": { "type": "string" },
    "asistentes": { "type": "string" },
    "motivo": { "type": "string" },
    "cuerpo_html": { "type": "string" },
    "secreto": { "type": "string" }
  }
}
```

## 2. Agregar un **Switch** (Modificador)

- **En:** `triggerBody()?['accion']`
- Tres casos: `crear`, `modificar`, `cancelar`.

### Caso `crear`

**a) Office 365 Outlook → "Crear evento (V4)"** (Create event V4)

| Campo | Valor |
|---|---|
| Id. del calendario | Calendario |
| Asunto | `asunto` (contenido dinámico) |
| Hora de inicio | `inicio` |
| Hora de finalización | `fin` |
| Zona horaria | (UTC-06:00) Guadalajara, Ciudad de México, Monterrey |
| Asistentes requeridos | `asistentes` |
| Cuerpo | `cuerpo_html` |
| Ubicación | `Sala ` + `sala` |
| Mostrar como | busy |
| Recordatorio | 15 |

**b) HTTP** (devuelve a la plataforma el id del evento, para poder modificarlo o cancelarlo después)

- **Método:** POST
- **URI:** `https://ahfjstuwekcuxshclprl.supabase.co/rest/v1/rpc/salas_registrar_evento`
- **Encabezados:**

| Clave | Valor |
|---|---|
| apikey | *(la llave anónima, la misma que está en index.html: `SUPABASE_ANON`)* |
| Authorization | `Bearer ` + la misma llave anónima |
| Content-Type | application/json |
| Content-Profile | core |

- **Cuerpo:**

```json
{
  "p_id": "@{triggerBody()?['reserva_id']}",
  "p_evento": "@{outputs('Crear_evento_(V4)')?['body/id']}",
  "p_secreto": "@{triggerBody()?['secreto']}"
}
```

> Si tu acción se llama distinto (por ejemplo `Create_event_(V4)`), usa ese nombre en la expresión, o elige **Id** del contenido dinámico de la acción de crear evento.

### Caso `modificar`

**Condición:** `triggerBody()?['outlook_evento_id']` **es igual a** *(vacío)*

- **Si sí** (el evento aún no existía en Outlook): repetir las dos acciones del caso `crear` (Crear evento V4 + HTTP).
- **Si no:** **Office 365 Outlook → "Actualizar evento (V4)"** (Update event V4):
  - Id. del calendario: Calendario
  - Id.: `outlook_evento_id`
  - Asunto, Hora de inicio, Hora de finalización, Zona horaria, Asistentes requeridos, Cuerpo y Ubicación: igual que en *crear*.

Outlook avisa del cambio a los participantes.

### Caso `cancelar`

**Condición:** `triggerBody()?['outlook_evento_id']` **no es igual a** *(vacío)*

- **Si sí:** **Office 365 Outlook → "Eliminar evento (V2)"** (Delete event V2) con Id. = `outlook_evento_id`. Al borrarlo, Outlook manda la cancelación a todos y la reunión desaparece de sus calendarios.
- **Si no:** **Office 365 Outlook → "Enviar un correo electrónico (V2)"**: Para = `asistentes`, Asunto = `asunto`, Cuerpo = `cuerpo_html` (el cuerpo ya incluye el aviso de cancelación y el motivo).

## 3. Guardar y conectar con la plataforma

1. Guarda el flujo y copia la **URL de HTTP POST** que aparece en el desencadenador.
2. En Supabase → SQL Editor, corre (con tu URL):

```sql
update core.salas_config set valor = 'PEGA_AQUI_LA_URL_DEL_FLUJO' where clave = 'flujo_url';
```

## 4. Prueba

1. En la plataforma, aparta una sala para dentro de una hora e invítate a ti y a alguien de tu equipo.
2. Debe llegar la invitación de Outlook en uno o dos minutos.
3. Si no llega, revisa en Supabase:

```sql
-- ¿se mandó el aviso?
select * from core.sala_notificaciones order by id desc limit 10;
-- ¿qué contestó Power Automate? (status 202 = recibido)
select id, status_code, content from net._http_response order by id desc limit 10;
```

…y en Power Automate, el **historial de ejecuciones** del flujo.

---

### Notas

- **Sin flujo configurado la app funciona igual**: aparta y bloquea salas; solo no salen las invitaciones (se registra `sin_flujo` en la bitácora).
- **Si el correo falla, la reserva no se pierde**: el aviso nunca detiene la reserva.
- **No apartar salas desde Outlook directamente**: el bloqueo solo existe en la plataforma. Conviene avisar al equipo que, desde ahora, la sala se aparta ahí y Outlook solo recibe la invitación.
