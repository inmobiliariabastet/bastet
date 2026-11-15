# Auditoría SEO / GEO de bastet.uno — 15 de noviembre de 2026

> Alcance: lo que hay **hoy** en el repositorio y en producción. Distingue lo implementado y probado de lo pendiente. No promete posiciones: las posiciones dependen de Google, Bing y los motores de IA; aquí solo se construyen las condiciones técnicas y de contenido.

## 1. Arquitectura actual (resumen)

- Sitio **estático** (HTML + CSS + JavaScript sin framework) publicado en Hostinger desde GitHub (`inmobiliariabastet/bastet`, rama `main`).
- Datos en **Supabase** (tabla `properties`, perfiles públicos, reservas, etc.). El navegador lee los inmuebles con la clave pública y los pinta con JavaScript (`main.js`, `home.js`, `estadias.js`): **las tarjetas del Inicio, Propiedades y Estadías no están en el HTML inicial.**
- La ficha de cada inmueble se abre como ventana sobre el listado (`marketplace.html?p=BST-1020`); su canonical apunta al listado.
- Desde el 14-nov: páginas estáticas por inmueble en `/inmueble/` generadas por `tools/gen_property_pages.py` (tarea diaria de GitHub Actions).

## 2. Resultado por área

| # | Área | Estado | Evidencia / observación |
|---|---|---|---|
| 1 | SEO técnico | ✅ Bueno | HTTPS, `lang="es"`, canonical en páginas públicas, `noindex` en admin y verificador, 404 de marca. |
| 2 | SEO on-page | ✅ Bueno en 4 páginas | Títulos 53–58 car., descripciones 140–160, un H1, H2/H3 en orden (Inicio, Propiedades, Estadías, Empresas). `app.html` no tiene canonical ni Open Graph. |
| 3 | Indexabilidad de propiedades | ⚠️ Parcial | Solo 3 de 20 inmuebles disponibles cumplen la regla de ficha completa (descripción ≥ 100 car.); el resto solo existe dentro del listado con JavaScript. |
| 4 | Velocidad / Core Web Vitals | ✅ Mejorado | Lighthouse móvil del Inicio: 45 → ~90 (3 corridas: 90/93/92), LCP 2,3–2,6 s, TBT 180–260 ms, CLS 0. Otras páginas sin medir. |
| 5 | Mobile-first | ✅ | `viewport`, diseño adaptable, barra inferior móvil. |
| 6 | Renderizado de JavaScript | ⚠️ Riesgo | El inventario se pinta con JS: Google lo ejecuta, pero **los rastreadores de IA suelen no ejecutarlo**. Mitigado solo para los inmuebles con página estática y para las páginas de categoría nuevas (esta entrega). |
| 7 | Sitemap XML | ✅ | Páginas principales + `/inmueble/` (se regenera a diario). |
| 8 | robots.txt | ✅ | Permite todo salvo `/admin/`; bots de buscadores y de IA declarados. Lighthouse lo marcó «no válido» en 2 de ~12 corridas con detalle vacío (respuesta lenta del origen). |
| 9 | Canonical | ✅ | Cada página pública y cada ficha estática se auto-referencian. |
| 10 | Open Graph / Twitter | ✅ en 4 páginas + fichas | Faltan en `app.html`, `privacidad`, `terminos`, `dmca`. |
| 11 | Schema.org | ✅ | `Organization/RealEstateAgent`, `WebSite`, `FAQPage` (Inicio y Empresas), `CollectionPage`, `RealEstateListing` + `BreadcrumbList` en fichas. |
| 12 | Enlaces internos | ⚠️ Débil | No existían páginas de categoría (ciudad/operación/tipo) y las tarjetas del listado son botones, no enlaces a una URL propia. |
| 13 | Experiencia de búsqueda | ✅ base / ⚠️ falta | Hay buscador, filtros, mapa (`prop-extras.js`), favoritos y «solicitar contacto». **No hay** búsquedas guardadas ni alertas. |
| 14 | Accesibilidad para crawlers | ✅ | Lighthouse accesibilidad 100 en Inicio, Propiedades, Estadías y Empresas. |
| 15 | Presencia en buscadores / IA | ❓ Sin medir | Sitemap enviado a Search Console (30-oct). No hay Google Analytics 4, ni Bing Webmaster verificado en el repositorio, ni dato de indexación a la vista. |

Datos que **no existen** hoy y limitan lo que se puede prometer: la tabla `properties` no tiene `updated_at`, ni zona/barrio como columna (la zona solo está en la solicitud de publicación).

## 3. Comparación con otros portales

Metodología: se consultó la web pública. **Solo se reporta lo observable.**

| Portal | Lo observado | Comparación con Bastet |
|---|---|---|
| **InfoCasas Bolivia** (infocasas.com.bo) | Título y H1 descriptivos; navegación por operación (Venta, Alquiler, Anticrético, Proyectos, Inmobiliarias), ciudades y zonas; URLs jerárquicas `/venta/casas/la-paz/achumani`; bloques densos de «Búsquedas recomendadas» y pies de página con enlaces por ciudad/operación/tipo; app móvil con avisos. No se vio FAQ, blog ni datos estructurados en la página consultada. Publica estudios de mercado propios (p. ej. informe de rentabilidad de alquileres, 2018). | Su ventaja es **arquitectura de URLs por ciudad/zona/tipo y volumen de inventario**. Bastet no tenía esas páginas. Bastet sí tiene: FAQ, JSON-LD, verificación con distintivos, contacto protegido y estadías por noche. |
| **Ultracasas** | Aparece en la búsqueda como portal boliviano; la página de inicio redirige a un subdominio y no se pudo evaluar. | Sin datos fiables. |
| **Morada, PAX MARKA, 360 Real Estate** | **No se encontró información pública verificable** (la búsqueda no devolvió su sitio o corresponden a otros países). | No se compara ni se inventa. Si tienes su dirección web, se audita. |

## 4. Brechas priorizadas

1. **Páginas de categoría indexables** (operación, ciudad, tipo) con inventario real → *se implementa en esta entrega*.
2. **Ficha propia para cada inmueble** → depende de que los anunciantes escriban descripciones completas; se agrega un **panel de calidad** en el Admin que muestra qué falta en cada ficha.
3. **Fechas y estado** en las fichas (`datePosted`/`dateModified`/disponibilidad) → se implementa con las fechas reales disponibles.
4. **Contenido institucional y guías** que los asistentes de IA puedan citar → se implementa (sobre Bastet, guías de operaciones) y pasa por revisión del abogado.
5. **Medición**: GA4, Bing Webmaster, seguimiento de indexación → requiere cuentas de la dueña; se deja preparado y documentado.
6. **Autoridad externa** (Google Business Profile, Bing Places, directorios, medios, alianzas) → plan en `docs/ESTRATEGIA_AUTORIDAD.md`; son acciones fuera del código.
7. **Búsquedas guardadas y alertas** → requieren backend de envíos; no se construyen sin decidir proveedor de correo/WhatsApp.

## 5. Estado tras la implementación (15-nov-2026)

| Qué | Estado | Cómo se comprobó |
|---|---|---|
| Páginas de categoría (operación / ciudad / tipo / combinaciones) | ✅ En producción: 7 hoy (`propiedades-en-venta-en-bolivia`, `…-alquiler-…`, `…-anticretico-…`, `inmuebles-en-la-paz`, `casas-en-venta`, `casas-en-alquiler`, `propiedades-en-venta-en-la-paz`). Las demás ciudades y tipos aparecen solas cuando tengan 3+ inmuebles reales. | `python tests/seo_pages_test.py` (0 fallas) + URLs 200 en vivo; sin barra final redirige 301 a la versión con barra. |
| Fichas por inmueble con migas, fecha de publicación y de actualización, anunciante y enlaces a categorías | ✅ | Prueba + lectura del JSON-LD. «Actualizada» es la fecha en que cambió el contenido de la página (la tabla `properties` no guarda `updated_at`). |
| Anuncios retirados / vencidos / vendidos | ✅ La tarea diaria borra su página y la saca del sitemap; si ocurre antes, la página avisa y se marca `noindex`. | Revisión de código; no se probó con un retiro real. |
| Página institucional `/sobre-bastet/` | ✅ Texto sin afirmar que todo esté verificado. Pendiente: revisión del abogado. | Prueba. |
| `robots.txt` por tipo de rastreador | ✅ Buscadores/asistentes permitidos; entrenamiento de modelos permitido hoy y **decisión de la dueña** (comentario en el archivo). | Prueba + archivo en vivo. |
| `llms.txt` con categorías | ✅ Se actualiza solo. | Prueba. |
| Panel Admin → SEO | ✅ Calidad del inventario, páginas publicadas, vistas/clics por ciudad y operación, enlaces a herramientas. | Probado con datos reales en una página de prueba; **no** probado dentro del admin con sesión iniciada. |
| Filtros funcionales en las categorías | ✅ Formulario que abre Propiedades con operación, tipo y ciudad. | Revisión; los parámetros ya los entiende `marketplace.html`. |
| Google Analytics 4, Bing Webmaster, Google Business Profile | ❌ Requieren cuentas de la dueña (`docs/ESTRATEGIA_AUTORIDAD.md`). | — |
| Búsquedas guardadas y alertas de nuevos inmuebles | ❌ No construido: requiere decidir proveedor de envíos (correo/WhatsApp) y una tabla nueva. | — |
| Guías largas y contenido de mercado | ❌ Solo hay una guía corta por operación en las páginas nacionales. Más contenido necesita fuentes y revisión legal. | — |

**Datos que condicionan el resultado:** solo 3 de 20 inmuebles tienen la ficha completa; 9 de 20 no tienen operación o tipo (listados antiguos) y por eso no entran en ninguna categoría. Completarlos en el panel es lo que más amplía el SEO.
