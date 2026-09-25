# Plantillas de correo de Supabase Auth

Copia de las plantillas pegadas en Supabase → Authentication → Emails → Templates
(2026-09-24). Se envían por SMTP propio desde `inmobiliaria@bastet.uno` (Hostinger).
Si se cambian en el Dashboard, actualizar también estos archivos.

| Plantilla en Supabase | Archivo | Subject |
|---|---|---|
| Invite user | `invite.html` | Tu invitación para ser agente en Bastet |
| Reset password | `reset-password.html` | Crea una nueva contraseña para tu cuenta Bastet |

`{{ .ConfirmationURL }}` y `{{ .Email }}` son variables de Supabase: no tocarlas.
