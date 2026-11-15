-- =====================================================================
-- Bastet · Blog (compra segura, anticrético y verificación de títulos)  — corre en el SQL Editor de Supabase
-- =====================================================================
-- · Tabla blog_posts: las entradas se escriben en el panel (Admin → Blog). El público solo ve las PUBLICADAS; solo administración crea, edita y borra.
-- · Bucket público «blog-images» para las fotos de las entradas (solo administración sube).
-- · La página pública (/blog/) se genera con tools/gen_property_pages.py (tarea diaria de GitHub o «Run workflow»).
-- · Incluye 3 entradas iniciales; volver a correr este SQL no pisa lo que edites.
-- Idempotente: se puede correr más de una vez.

do $$
begin
  if to_regprocedure('public.is_admin()') is null then raise exception 'Primero corre supabase/schema.sql (falta is_admin)'; end if;
end $$;

create table if not exists public.blog_posts (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) between 3 and 100),
  title        text not null check (char_length(btrim(title)) between 5 and 150),
  excerpt      text not null check (char_length(btrim(excerpt)) between 40 and 320),
  body_md      text not null check (char_length(btrim(body_md)) >= 200),
  cover_url    text check (cover_url is null or char_length(cover_url) <= 600),
  cover_alt    text check (cover_alt is null or char_length(cover_alt) <= 200),
  category     text not null default 'general' check (category in ('compra-segura', 'anticretico', 'verificacion', 'general')),
  author_name  text not null default 'Equipo Bastet' check (char_length(btrim(author_name)) between 2 and 80),
  status       text not null default 'draft' check (status in ('draft', 'published')),
  published_at timestamptz,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists blog_posts_status_published_idx on public.blog_posts (status, published_at desc);

-- Fechas automáticas: updated_at siempre; published_at se llena al publicar por primera vez.
create or replace function public.blog_posts_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if new.status = 'published' and new.published_at is null then new.published_at := now(); end if;
  return new;
end $$;
drop trigger if exists blog_posts_touch on public.blog_posts;
create trigger blog_posts_touch before insert or update on public.blog_posts for each row execute function public.blog_posts_touch();

alter table public.blog_posts enable row level security;

drop policy if exists "public can read published blog posts" on public.blog_posts;
create policy "public can read published blog posts" on public.blog_posts for select to anon, authenticated
  using (status = 'published' and published_at <= now());

drop policy if exists "admin can read all blog posts" on public.blog_posts;
create policy "admin can read all blog posts" on public.blog_posts for select to authenticated using (public.is_admin());

drop policy if exists "admin can insert blog posts" on public.blog_posts;
create policy "admin can insert blog posts" on public.blog_posts for insert to authenticated with check (public.is_admin());

drop policy if exists "admin can update blog posts" on public.blog_posts;
create policy "admin can update blog posts" on public.blog_posts for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admin can delete blog posts" on public.blog_posts;
create policy "admin can delete blog posts" on public.blog_posts for delete to authenticated using (public.is_admin());

-- ── Storage: fotos del blog ──
insert into storage.buckets (id, name, public) values ('blog-images', 'blog-images', true) on conflict (id) do nothing;

drop policy if exists "public can view blog images" on storage.objects;
create policy "public can view blog images" on storage.objects for select to public using (bucket_id = 'blog-images');

drop policy if exists "admin can upload blog images" on storage.objects;
create policy "admin can upload blog images" on storage.objects for insert to authenticated with check (bucket_id = 'blog-images' and public.is_admin());

drop policy if exists "admin can update blog images" on storage.objects;
create policy "admin can update blog images" on storage.objects for update to authenticated using (bucket_id = 'blog-images' and public.is_admin());

drop policy if exists "admin can delete blog images" on storage.objects;
create policy "admin can delete blog images" on storage.objects for delete to authenticated using (bucket_id = 'blog-images' and public.is_admin());

-- ── Entradas iniciales ──
insert into public.blog_posts (id, slug, title, excerpt, body_md, cover_url, cover_alt, category, author_name, status, published_at) values
  ('1c5ed005-d1c7-5c4f-ac0f-435daeda1086', 'como-comprar-una-casa-en-bolivia-de-forma-segura', $md$Cómo comprar una casa en Bolivia de forma segura: guía paso a paso$md$, $md$Los pasos para comprar un inmueble en Bolivia sin sorpresas: qué documentos pedir, qué revisar en Derechos Reales y cómo cerrar la compra con protección.$md$, $md$Comprar una casa, un departamento o un terreno es probablemente la decisión económica más grande que tomarás. En Bolivia, la mayoría de los problemas después de una compra no vienen del precio: vienen de **papeles que nadie revisó a tiempo**. Esta guía resume el orden en que conviene hacer las cosas para comprar con seguridad.

> Esta guía es información general y no reemplaza la asesoría de un abogado. Los trámites y costos pueden variar según el municipio y el tipo de inmueble.

## 1. Define el presupuesto completo, no solo el precio

El precio acordado no es lo único que pagarás. Antes de ofertar, suma:

- Los **impuestos y trámites de la transferencia** (consulta los montos vigentes en tu municipio y con el notario).
- Los **honorarios** del notario y, si lo contratas, del abogado que revise los documentos.
- Los **gastos de registro** en Derechos Reales.
- Posibles **deudas pendientes** del inmueble (impuestos, servicios básicos, expensas).

Tener esa cifra clara evita que una buena oferta se convierta en un problema de caja el día de la firma.

## 2. Verifica quién vende y con qué derecho

Pide la cédula de identidad del vendedor y compárala con el nombre que figura como propietario en los documentos. Pregunta con claridad:

- ¿El inmueble está a nombre de una sola persona o de varias? Si hay copropietarios, **todos deben firmar**.
- ¿El vendedor es casado o tiene unión libre registrada? Según el caso, el cónyuge puede tener que participar en la venta.
- Si vende un apoderado, pide el **poder notarial** y comprueba que lo autorice expresamente a vender ese inmueble.
- Si el inmueble viene de una herencia, pide el documento que acredite a los herederos y que todos estén de acuerdo.

## 3. Revisa el Folio Real en Derechos Reales

El **Folio Real** es el documento del registro de Derechos Reales que muestra, entre otras cosas, quién figura como propietario, el historial de transferencias y si el inmueble tiene **gravámenes o restricciones** (por ejemplo hipotecas, embargos o anotaciones). Pídelo actualizado: un folio con meses de antigüedad puede no mostrar lo último que pasó con el bien.

Revisa especialmente que:

- El propietario del folio sea la persona que te vende.
- Los datos del inmueble (ubicación, superficie, colindancias) coincidan con lo que te muestran.
- No existan hipotecas, embargos u otras cargas que impidan o condicionen la venta. Si las hay, la compra debe condicionarse a su cancelación.

Si quieres profundizar en esta revisión, lee nuestra guía [cómo verificar el título de propiedad de un inmueble en Bolivia](/blog/como-verificar-el-titulo-de-propiedad-de-un-inmueble-en-bolivia/).

## 4. Pide el testimonio y el historial del título

El **testimonio de la escritura pública** es la copia del documento notarial con el que el vendedor adquirió el inmueble. Compáralo con el Folio Real: deben contar la misma historia. Si hay saltos (por ejemplo, un propietario anterior que no aparece), pide explicaciones y no avances hasta resolverlas.

## 5. Comprueba impuestos, servicios y catastro

Antes de pagar, pide pruebas de que el inmueble está al día:

- **Impuesto municipal a la propiedad**: comprobantes de pago de las gestiones que correspondan.
- **Servicios básicos** (agua, luz, gas): que no haya facturas atrasadas.
- **Plano y certificado catastral**: que la superficie y los límites coincidan con la realidad. Una visita al terreno con el plano en la mano evita sorpresas con vecinos.

Una deuda pendiente puede terminar siendo del comprador si no se aclara antes de la firma.

## 6. Visita el inmueble más de una vez

Ve en distintos horarios, pregunta a los vecinos, revisa el estado de las instalaciones y confirma quién vive ahí. Si está ocupado por un inquilino o un anticresista, pregunta bajo qué contrato y hasta cuándo: esa situación **puede seguir vigente después de que compres**.

## 7. Cierra con un contrato claro y escritura pública

La compra se formaliza con una **escritura pública ante notario**, y luego se **inscribe en Derechos Reales**. Esa inscripción es la que da publicidad al cambio de propietario y te protege frente a terceros. Cuida estos puntos:

- Que el contrato diga con precisión el precio, la forma de pago y las fechas de entrega.
- Que los pagos queden **documentados** (transferencia bancaria o recibo firmado) y no se hagan en efectivo sin constancia.
- Que la entrega del inmueble y de los documentos esté pactada por escrito.
- Que la inscripción en Derechos Reales se haga a tu nombre lo antes posible.

## Señales de alerta que conviene tomar en serio

- El vendedor tiene prisa y se niega a que un abogado revise los documentos.
- El precio es muy inferior al de inmuebles parecidos de la zona.
- Piden un adelanto grande antes de mostrar el Folio Real y el testimonio.
- Los nombres o números no coinciden entre los documentos.
- El inmueble está en conflicto con vecinos, en proceso judicial o con ocupantes que no quieren irse.

## Preguntas frecuentes

### ¿Qué documentos debo pedir para comprar un inmueble en Bolivia?

Como mínimo: cédula de identidad del vendedor, Folio Real actualizado de Derechos Reales, testimonio de la escritura pública, comprobantes del impuesto municipal a la propiedad, plano o certificado catastral y recibos de servicios básicos al día.

### ¿Qué es el Folio Real y por qué importa?

Es el documento del registro de Derechos Reales que muestra quién figura como propietario, el historial del inmueble y si tiene gravámenes o restricciones. Revisarlo antes de pagar es la forma más directa de confirmar que quien vende puede vender.

### ¿Necesito un abogado para comprar una casa?

No es obligatorio, pero es muy recomendable. Un abogado revisa que los documentos coincidan, detecta cargas ocultas y redacta o revisa el contrato. Su costo suele ser pequeño frente al valor del inmueble.

### ¿Cuándo soy realmente el dueño?

Firmas la escritura pública ante notario y luego se inscribe en Derechos Reales. La inscripción es la que da publicidad a tu derecho y te protege frente a terceros, por eso conviene hacerla cuanto antes.

## Cómo te acompaña Bastet

En Bastet publicamos inmuebles en venta, alquiler y anticrético, y ofrecemos servicios de **revisión documental y verificación registral** para quien quiere comprar con respaldo. Mira los [inmuebles en venta en Bolivia](/propiedades-en-venta-en-bolivia/) o escríbenos desde la ficha de cualquier inmueble con «Solicitar contacto». Los teléfonos no se publican: se entregan cuando tu solicitud se confirma.$md$, 'assets/img/blog/como-comprar-una-casa-en-bolivia-de-forma-segura.webp', $md$Ilustración de Bastet: compra segura de un inmueble en Bolivia$md$, 'compra-segura', $md$Equipo Bastet$md$, 'published', '2026-11-15 12:00:00-04'),
  ('61009147-4332-5443-9712-46f44b368fab', 'como-verificar-el-titulo-de-propiedad-de-un-inmueble-en-bolivia', $md$Cómo verificar el título de propiedad de un inmueble en Bolivia$md$, $md$Qué es verificar un título, qué documentos revisar (Folio Real, testimonio, plano e impuestos) y qué señales indican que un inmueble no está limpio.$md$, $md$Verificar el título de un inmueble significa comprobar, con documentos oficiales, que **quien vende es realmente el propietario, que el inmueble es el que dice ser y que no tiene deudas ni restricciones que te afecten** como comprador o anticresista. Es el paso que más problemas evita y el que más gente se salta por confiar en la palabra del vendedor.

> Esta guía es información general y no reemplaza la asesoría de un abogado. Si el inmueble tiene algo que no entiendes, consulta antes de pagar.

## Qué es un «título» de propiedad

En la práctica, hablar de título es hablar del conjunto de documentos que prueban el derecho del propietario sobre el inmueble. Los principales son:

- **El testimonio de la escritura pública** con la que el propietario adquirió el bien (compra, donación, herencia u otra forma).
- **El Folio Real** del registro de Derechos Reales, donde figura el inmueble, su propietario y su historial.
- **El plano y el certificado catastral**, que describen la superficie y los límites.
- **Los comprobantes de impuestos y servicios**, que muestran si está al día.

Ninguno de ellos, solo, alcanza. Lo importante es que **cuenten la misma historia** y que los datos coincidan.

## Paso 1: Pide un Folio Real actualizado

El Folio Real es la fuente más directa para saber cómo está registrado un inmueble. Compruébalo con calma:

- **Propietario:** ¿es la persona (o personas) que te vende? ¿Su nombre completo coincide con la cédula de identidad?
- **Datos del inmueble:** ubicación, superficie y colindancias deben coincidir con el plano y con lo que ves en el terreno.
- **Historial:** busca cómo llegó el inmueble al propietario actual y si hay saltos o transferencias que no entiendes.
- **Gravámenes y restricciones:** hipotecas, embargos, anotaciones preventivas u otras cargas. Si hay alguna, pregunta qué es, quién la puso y cómo se cancela **antes** de pagar.

Pide siempre la versión más reciente: el estado de un inmueble puede cambiar en pocos días.

## Paso 2: Compara con el testimonio de la escritura

El testimonio debe corresponder al mismo inmueble y al mismo propietario del Folio Real. Revisa que:

- El nombre del comprador original sea el actual propietario o que exista una cadena clara de transferencias hasta él.
- La descripción del inmueble (superficie, límites, ubicación) coincida con el Folio Real y con el plano.
- Las firmas y sellos del notario estén completos y legibles.

Si el inmueble viene de una **herencia o de un poder**, pide los documentos que lo respaldan: declaratoria o documento que acredite a los herederos y el poder notarial con facultad expresa de vender.

## Paso 3: Verifica la identidad y la capacidad de quien vende

- Pide la **cédula de identidad** y compárala con los datos de los documentos.
- Pregunta por el **estado civil**: según el caso, el cónyuge puede tener que firmar o dar su consentimiento.
- Si hay **varios propietarios**, todos deben firmar.
- Si vende una **sociedad o empresa**, pide los documentos que acrediten a su representante legal y su facultad de vender.

## Paso 4: Revisa impuestos, servicios y catastro

- **Impuesto municipal a la propiedad:** comprobantes de pago de las gestiones correspondientes.
- **Servicios básicos:** que no existan deudas pendientes.
- **Plano y certificado catastral:** que la superficie y los límites coincidan con lo que ves. Una visita al terreno con el plano en la mano evita conflictos con vecinos.

## Paso 5: Averigua si hay conflictos o procesos

Pregunta directamente al vendedor si existe algún conflicto judicial, reclamo de vecinos o disputa familiar sobre el inmueble, y pide que la respuesta quede por escrito en el contrato. Un abogado puede ayudarte a confirmar si hay procesos que afecten el inmueble.

## Señales de alerta

- El vendedor se niega a mostrar el Folio Real o el testimonio.
- El nombre del Folio Real **no coincide** con el de quien vende.
- La superficie o los límites cambian entre un documento y otro.
- Hay hipotecas, embargos o anotaciones y el vendedor «no sabe» de qué se trata.
- Te piden un adelanto grande antes de que revises los documentos.
- El precio es muy inferior al de la zona sin una razón clara.

## Preguntas frecuentes

### ¿Qué significa verificar un título de propiedad?

Es comprobar, con documentos oficiales, que quien vende es el propietario, que el inmueble es el que se describe y que no tiene deudas ni restricciones que afecten al comprador.

### ¿Qué documentos necesito para verificar un título?

El Folio Real actualizado de Derechos Reales, el testimonio de la escritura pública, la cédula de identidad del vendedor, el plano o certificado catastral y los comprobantes de impuestos y servicios.

### ¿Cómo sé si un inmueble tiene hipotecas o embargos?

En el Folio Real figuran los gravámenes y restricciones registrados. Pídelo actualizado y revisa que no aparezcan hipotecas, embargos ni anotaciones que impidan o condicionen la venta.

### ¿Puedo verificar un título yo mismo?

Puedes hacer una primera revisión con esta guía, pero para decisiones de valor alto conviene que un abogado o un servicio especializado revise los documentos, porque detecta cosas que un comprador sin experiencia no ve.

### ¿Verifica Bastet los títulos de los inmuebles publicados?

Bastet ofrece servicios de revisión documental y verificación registral, y entrega distintivos de verificación a los agentes, propietarios y propiedades que completan el proceso. No todos los inmuebles publicados están verificados: busca el distintivo en la ficha.

## Verificación con Bastet

Si quieres una revisión de documentos antes de comprar o de entregar un anticrético, en Bastet ofrecemos **revisión documental y verificación registral**. Puedes comprobar un código de verificación en [bastet.uno/verificar](/verificar.html), explorar [inmuebles en venta en Bolivia](/propiedades-en-venta-en-bolivia/) o leer nuestra guía [cómo comprar una casa en Bolivia de forma segura](/blog/como-comprar-una-casa-en-bolivia-de-forma-segura/).$md$, 'assets/img/blog/como-verificar-el-titulo-de-propiedad-de-un-inmueble-en-bolivia.webp', $md$Ilustración de Bastet: verificación del título de propiedad de un inmueble$md$, 'verificacion', $md$Equipo Bastet$md$, 'published', '2026-11-15 12:00:00-04'),
  ('ade87158-d412-5bed-aedf-e81ea3556f7d', 'que-es-el-anticretico-en-bolivia-guia-para-inquilinos-y-propietarios', $md$Qué es el anticrético en Bolivia: guía para inquilinos y propietarios$md$, $md$Cómo funciona el anticrético, en qué se diferencia del alquiler y qué cuidar antes de firmar: contrato, registro y devolución del dinero en Bolivia.$md$, $md$El **anticrético** es una forma de ocupar un inmueble muy usada en Bolivia y poco conocida fuera del país. En lugar de pagar un alquiler mensual, quien ocupa la vivienda **entrega una suma de dinero al propietario** y usa el inmueble durante un plazo acordado. Al terminar el contrato, el propietario **devuelve esa suma**. Para ambas partes puede ser un buen trato, siempre que se haga con orden y por escrito.

> Esta guía es información general y no reemplaza la asesoría de un abogado. Antes de firmar, confirma las condiciones con un profesional.

## Cómo funciona, en pocas palabras

1. El propietario recibe una suma de dinero y entrega el inmueble para que otra persona lo use.
2. Quien lo ocupa **no paga un alquiler mensual** por usarlo durante el plazo del contrato.
3. Al vencer el plazo, el propietario **devuelve la suma entregada**. El inmueble regresa al propietario.

Para el propietario, el anticrético es una forma de disponer de un capital sin vender el inmueble. Para quien ocupa, es una forma de vivir sin pagar cuota mensual a cambio de inmovilizar un monto que luego recupera.

## Anticrético y alquiler: las diferencias que importan

| | Alquiler | Anticrético |
|---|---|---|
| Qué paga el ocupante | Una cuota periódica (mensual) | Una suma única al inicio |
| ¿Se recupera el dinero? | No: la cuota es el precio del uso | Sí: se devuelve al terminar el contrato |
| Cuota mensual por el uso | Sí | No, durante el plazo del contrato |
| Para quién suele convenir | Quien prefiere flexibilidad y poco capital inicial | Quien dispone de un monto y quiere evitar la cuota mensual |

## Qué debe tener un buen contrato de anticrético

Pon por escrito, con claridad:

- **Los datos de ambas partes** y del inmueble (dirección, superficie, características).
- **La suma entregada** y cómo se pagó (transferencia o recibo firmado; evita entregas en efectivo sin constancia).
- **El plazo** exacto del contrato y qué pasa al vencer: si se renueva, bajo qué condiciones y con qué aviso previo.
- **La fecha y la forma de devolución** del dinero, y qué ocurre si el propietario se retrasa.
- **Quién paga qué**: servicios básicos, mantenimiento, reparaciones y mejoras.
- **Un inventario del estado del inmueble** al entregarlo y al devolverlo, idealmente con fotos.

Lo recomendable es formalizarlo ante notario y consultar con un abogado si conviene **inscribirlo en Derechos Reales**: un contrato registrado da más protección si el inmueble cambia de dueño o tiene otras deudas.

## Qué debe revisar quien entrega el dinero

Quien entrega la suma es quien asume el mayor riesgo, porque su capital queda en manos del propietario. Antes de firmar:

- **Verifica que quien te ofrece el inmueble sea realmente el propietario.** Pide el Folio Real y la cédula de identidad, y compáralos. Revisa también cómo se [verifica el título de propiedad](/blog/como-verificar-el-titulo-de-propiedad-de-un-inmueble-en-bolivia/).
- **Comprueba que no tenga hipotecas, embargos u otras cargas.** Si las tiene, tu dinero podría estar en riesgo si el propietario no cumple con otras deudas.
- **Confirma que no haya otro ocupante o contrato vigente** sobre el mismo inmueble.
- **Pide que la devolución esté garantizada por escrito**, con fecha y forma de pago.
- **Desconfía de las ofertas muy por debajo del valor del mercado** o que piden decidir con prisa.

## Qué debe cuidar el propietario

- **Debes poder devolver la suma** en la fecha pactada. Calcula con realismo antes de recibirla.
- **No ofrezcas el mismo inmueble en dos contratos** ni entregues un bien con cargas que no hayas declarado: puede generar responsabilidad legal.
- **Documenta el estado del inmueble** y las reglas de uso (mascotas, subarriendo, reformas).
- **Entrega recibos** de lo recibido y guarda copia de todo.

## Señales de alerta

- El propietario no quiere mostrar el Folio Real ni la cédula.
- Piden una suma alta sin contrato firmado ni recibo.
- El monto no coincide con el que figura en el contrato.
- El inmueble está en proceso judicial, con litigios con vecinos o con ocupantes que no se van.
- El contrato no dice cómo ni cuándo se devuelve el dinero.

## Preguntas frecuentes

### ¿Qué es el anticrético?

Es un contrato en el que quien ocupa un inmueble entrega una suma de dinero al propietario y lo usa sin pagar alquiler mensual durante un plazo. Al terminar, el propietario devuelve esa suma.

### ¿Es mejor el anticrético que el alquiler?

Depende de tu situación. Si tienes un monto disponible y quieres evitar la cuota mensual, el anticrético puede convenir. Si prefieres no inmovilizar capital o necesitas flexibilidad, el alquiler suele ser más simple.

### ¿Se devuelve el dinero del anticrético?

Sí. La suma entregada se devuelve al finalizar el contrato, en la fecha y forma que se hayan pactado. Por eso el contrato debe decirlo con claridad.

### ¿Hay que registrar el contrato de anticrético?

Lo habitual es formalizarlo ante notario. Conviene consultar con un abogado si corresponde inscribirlo en Derechos Reales, porque un contrato registrado ofrece más protección frente a terceros, por ejemplo si el propietario vende el inmueble.

### ¿Qué pasa si el propietario no devuelve el dinero?

Depende de lo que diga el contrato y de la situación del inmueble. Por eso es tan importante pactar por escrito la fecha de devolución y asesorarse con un abogado antes de firmar.

## Anticrético en Bastet

En Bastet puedes explorar [inmuebles en anticrético en Bolivia](/propiedades-en-anticretico-en-bolivia/), con fotos, precio y datos de cada propiedad. Desde la ficha, «Solicitar contacto» pone en contacto con quien publica; los teléfonos no se publican y se entregan cuando la solicitud se confirma. Si necesitas revisar documentos antes de firmar, también ofrecemos **revisión documental y verificación registral**.$md$, 'assets/img/blog/que-es-el-anticretico-en-bolivia-guia-para-inquilinos-y-propietarios.webp', $md$Ilustración de Bastet: anticrético de inmuebles en Bolivia$md$, 'anticretico', $md$Equipo Bastet$md$, 'published', '2026-11-15 12:00:00-04')
on conflict (slug) do nothing;

notify pgrst, 'reload schema';
