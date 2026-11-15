# Estrategia de autoridad digital y medición de Bastet

> Esto son **acciones fuera del código**: requieren cuentas, decisiones y tiempo de la dueña o del equipo comercial. Nada de lo de aquí está hecho todavía. Principio: autoridad legítima, información verificable, **sin reseñas falsas, sin cifras de inventario inventadas y sin backlinks artificiales** (compra de enlaces, granjas de enlaces, intercambios masivos).

## 1. Perfiles y datos consistentes (semanas 1–2) — impacto alto, esfuerzo bajo
Usar **exactamente** los mismos datos en todos los sitios (coinciden con `/sobre-bastet/` y con los datos estructurados del Inicio):

| Dato | Valor publicado |
|---|---|
| Nombre comercial | Bastet |
| Razón social | Bastet Real State S.R.L. |
| Dirección | Calle Yanacocha, Edif. Cristal, Piso 7, Of. 706, La Paz, Bolivia |
| Correo | inmobiliaria@bastet.uno |
| Teléfono | +591 77666205 |
| Sitio | https://bastet.uno |

1. **Google Business Profile**: crear/reclamar el perfil con la dirección de oficina (la verificación es por postal, llamada o video según Google). Categoría principal «Agencia inmobiliaria». Subir logo y fotos reales, horario, enlace al sitio. Responder las reseñas reales que lleguen; **no** pedir reseñas a cambio de nada ni escribirlas.
2. **Bing Places**: importar el perfil desde Google Business Profile.
3. **Bing Webmaster Tools**: importar el sitio desde Search Console (un clic) y reenviar el sitemap. Bing alimenta a varios asistentes de IA.
4. **Redes**: Facebook, Instagram, TikTok y LinkedIn con el mismo nombre, logo, descripción y enlace a bastet.uno. Mismo texto de «Sobre Bastet».
5. Registro en **Fundempresa** y otros directorios oficiales con los mismos datos de razón social.

## 2. Contenido que merece ser citado (meses 1–3)
Los asistentes de IA y Google citan páginas que responden preguntas concretas con información verificable. Ideas, en orden de prioridad (cada una revisada por el abogado antes de publicar):
- **Guía: documentos que revisar antes de comprar un inmueble en Bolivia** (Folio Real, testimonio, impuestos, plano; qué es cada uno y dónde se tramita).
- **Guía: anticrético paso a paso** (qué es, cómo se formaliza, diferencias con el alquiler, riesgos).
- **Guía: cómo alquilar con seguridad** (contrato, garantías, servicios).
- **Una página por ciudad cuando haya inventario real**: ya se generan solas desde 3 inmuebles; sumar texto propio sobre zonas y barrios solo cuando se pueda respaldar con datos o experiencia propia (no estadísticas copiadas).
- **Datos propios del mercado** solo cuando existan y se puedan auditar (p. ej. «precio mediano de casas en venta publicadas en Bastet en La Paz, mes X»). **No** publicar cifras de mercado sin fuente.
- Cada guía: autor y fecha visibles, `FAQPage` solo si las preguntas están en la página, enlaces a las categorías relacionadas.

## 3. Enlaces externos legítimos (meses 2–6)
- **Alianzas con inmobiliarias y corredores**: pedirles que enlacen a su ficha en Bastet; Bastet puede enlazar a su perfil de agente.
- **Medios digitales bolivianos**: notas de prensa con noticias reales (lanzamiento, verificación, servicio para empresas) y artículos de opinión firmados por la dirección o el abogado.
- **Cámaras y gremios** (cámara inmobiliaria, cámara de comercio): directorio de miembros con enlace.
- **Universidades y escuelas de negocios**: charlas o guías con enlace de referencia.
- **Empresas aliadas** de la franja «Empresas que trabajan con nosotros»: que enlacen a `/empresas.html`.
- **Evitar**: comprar enlaces, directorios de baja calidad en masa, comentarios con enlace, intercambio masivo de enlaces.

## 4. Anunciantes (más inventario completo = más visibilidad)
El mayor freno hoy es que **17 de 20 inmuebles tienen la ficha incompleta** y por eso no tienen página propia. Acción comercial: pedir a cada anunciante descripción propia de 100+ caracteres, operación y tipo. El panel Admin → SEO lista qué le falta a cada inmueble.

## 5. Medición (cuentas de la dueña)
| Herramienta | Estado | Qué hacer |
|---|---|---|
| Google Search Console | Sitemap enviado el 30-oct | Reenviar `sitemap.xml` (ahora incluye categorías y fichas); revisar «Páginas» → indexadas/no indexadas; informe «Rendimiento» por consulta, página y país. |
| Bing Webmaster Tools | Sin verificar | Importar desde Search Console. |
| Google Analytics 4 | **No configurado** | Crear la propiedad y pasar el **ID de medición (G-XXXXXXXX)**; se instala con consentimiento de cookies. Eventos útiles: `generate_lead` (solicitar contacto), `click_whatsapp`, `view_item` (ficha). |
| Panel Admin → SEO | Hecho | Calidad del inventario, páginas publicadas, vistas y clics por ciudad/operación. |
| Posiciones por palabra clave | Pendiente | Search Console da posición media por consulta; una herramienta de pago (Semrush, Ahrefs) o revisión manual mensual de las 10 búsquedas objetivo. |

**Búsquedas objetivo para seguimiento mensual** (registrar la posición real, sin prometer resultados): «propiedades en Bolivia», «portales inmobiliarios Bolivia», «casas en venta en La Paz», «departamentos en alquiler en La Paz», «anticrético en La Paz», «anticrético Bolivia», «departamentos en alquiler Santa Cruz», «inmuebles en Cochabamba», «estadías por noche La Paz».

## 6. Prueba periódica con asistentes de IA (sin manipular)
Una vez al mes, hacer las mismas preguntas en ChatGPT, Claude, Gemini, Perplexity y Google (con IA) y **anotar** si Bastet aparece, con qué descripción y qué fuente cita. Si dice algo incorrecto (p. ej. «todos verificados»), corregir la fuente (`/sobre-bastet/`, `llms.txt`, ficha) en vez de insistir.
