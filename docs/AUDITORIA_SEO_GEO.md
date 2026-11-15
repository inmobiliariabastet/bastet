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
