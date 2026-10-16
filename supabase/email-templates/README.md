# Plantillas de correo de Supabase Auth

Copia de las plantillas pegadas en Supabase → Authentication → Emails → Templates
(2026-09-24). Se envían por SMTP propio desde `inmobiliaria@bastet.uno` (Hostinger).
Si se cambian en el Dashboard, actualizar también estos archivos.

| Plantilla en Supabase | Archivo | Subject |
|---|---|---|
| Reset password | `reset-password.html` | Crea una nueva contraseña para tu cuenta Bastet |

`{{ .ConfirmationURL }}` y `{{ .Email }}` son variables de Supabase: no tocarlas.

## Correos de marketing

Hoy Bastet **no envía correos de marketing**: los de arriba son transaccionales (invitación y restablecer contraseña), que no requieren enlace de baja y ya llevan la dirección postal. Si algún día se envían promociones o boletines, cada correo debe terminar con `marketing-footer.html` (dirección postal + enlace de baja) y solo se debe escribir a quien dio su consentimiento.

La plantilla de invitación (`invite.html`) y la función `invite-admin` se eliminaron: ya no se invita por correo, los agentes entran con Google y su cuenta se crea sola.
