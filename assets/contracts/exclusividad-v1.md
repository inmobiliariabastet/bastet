# CONTRATO PRIVADO DE CORRETAJE INMOBILIARIO CON EXCLUSIVIDAD

**Nº {{numero_contrato}}**

> **Convenciones de la plantilla (para la app):**
> - `{{campo}}` → dato que llena el agente o que se calcula automáticamente.
> - `[[SI condición]] … [[FIN]]` → bloque que solo aparece si se cumple la condición.
> - `{{x_literal}}` → el monto o fecha escrito en letras (convención boliviana).

---

Conste por el presente documento privado, que con el solo reconocimiento de firmas y rúbricas surtirá los efectos de instrumento público conforme al artículo 1297 del Código Civil, un **Contrato de Corretaje Inmobiliario con Exclusividad**, sujeto a las siguientes cláusulas:

---

## PRIMERA.- (DE LAS PARTES)

**1.1. EL PROPIETARIO:** {{propietario_nombre}}, mayor de edad, hábil por derecho, con Cédula de Identidad Nº {{propietario_ci}}, de estado civil {{propietario_estado_civil}}, con domicilio en {{propietario_domicilio}}, teléfono {{propietario_telefono}}, correo electrónico {{propietario_email}}[[SI tiene_apoderado]], representado legalmente por {{apoderado_nombre}}, con C.I. Nº {{apoderado_ci}}, en mérito al Testimonio de Poder Nº {{poder_numero}} de fecha {{poder_fecha}}, otorgado ante Notaría de Fe Pública Nº {{poder_notaria}}[[FIN]].

[[SI tiene_copropietario]]
**1.2. EL/LA COPROPIETARIO(A) O CÓNYUGE:** {{copropietario_nombre}}, mayor de edad, hábil por derecho, con C.I. Nº {{copropietario_ci}}, quien suscribe el presente en señal de plena conformidad y asentimiento.
[[FIN]]

**{{numeral_agente}}. EL AGENTE:** {{agente_nombre}}, mayor de edad, hábil por derecho, con C.I. Nº {{agente_ci}}, agente inmobiliario[[SI agente_registro]] con registro Nº {{agente_registro}}[[FIN]], afiliado a **{{agencia_nombre}}**, con domicilio comercial en {{agencia_domicilio}}, teléfono {{agente_telefono}}, correo electrónico {{agente_email}}.

En adelante, EL PROPIETARIO y EL AGENTE serán denominados conjuntamente como **"LAS PARTES"**.

---

## SEGUNDA.- (DEL INMUEBLE)

EL PROPIETARIO declara ser legítimo propietario del inmueble consistente en **{{inmueble_tipo}}**, ubicado en {{inmueble_direccion}}, zona {{inmueble_zona}}, de la ciudad de {{inmueble_ciudad}}, departamento de {{inmueble_departamento}}, con una superficie de terreno de {{inmueble_sup_terreno}} m²[[SI inmueble_sup_construida]] y una superficie construida de {{inmueble_sup_construida}} m²[[FIN]], debidamente inscrito en Derechos Reales bajo la Matrícula Computarizada Nº {{inmueble_matricula}}[[SI inmueble_catastro]], con código catastral Nº {{inmueble_catastro}}[[FIN]].

[[SI sin_gravamenes]]
EL PROPIETARIO declara que el inmueble se encuentra libre de todo gravamen, hipoteca, anotación preventiva o restricción que limite su libre disponibilidad.
[[FIN]]
[[SI con_gravamenes]]
EL PROPIETARIO declara que sobre el inmueble pesa el siguiente gravamen: {{gravamenes_detalle}}, comprometiéndose a informarlo a todo interesado y a gestionar su levantamiento antes de la suscripción del contrato definitivo.
[[FIN]]

---

## TERCERA.- (DEL OBJETO)

Por el presente contrato, EL PROPIETARIO encarga a EL AGENTE, **en forma exclusiva**, la promoción, oferta, comercialización y búsqueda de interesados para **{{operacion_texto}}** del inmueble descrito en la cláusula segunda, así como la intermediación y asesoramiento en la negociación hasta la suscripción del contrato definitivo.

---

## CUARTA.- (DE LA EXCLUSIVIDAD)

Durante la vigencia del presente contrato, EL PROPIETARIO se obliga a:

a) No encargar la comercialización del inmueble a ningún otro agente, corredor o empresa inmobiliaria.

b) No publicar ni ofrecer el inmueble por cuenta propia ni a través de terceros, por ningún medio físico o digital.

c) Derivar a EL AGENTE toda consulta, visita u oferta que reciba directamente de cualquier interesado.

d) Retirar cualquier publicación o letrero que hubiera colocado con anterioridad a la firma del presente.

---

## QUINTA.- (DEL PRECIO Y CONDICIONES DE OFERTA)

El inmueble será ofertado al precio de **{{moneda_simbolo}} {{precio}} ({{precio_literal}})**[[SI operacion_alquiler]] mensuales[[FIN]].

[[SI precio_minimo]]
EL PROPIETARIO autoriza a EL AGENTE a recibir y presentar ofertas a partir de **{{moneda_simbolo}} {{precio_minimo}} ({{precio_minimo_literal}})**.
[[FIN]]

Toda oferta será comunicada por escrito a EL PROPIETARIO, a quien corresponde de manera exclusiva la decisión final de aceptarla o rechazarla. Cualquier modificación del precio o de las condiciones de oferta deberá constar por escrito.

---

## SEXTA.- (DEL PLAZO)

El presente contrato tendrá una vigencia de **{{plazo_dias}} ({{plazo_dias_literal}}) días calendario**, computables desde el {{fecha_inicio_literal}} hasta el {{fecha_fin_literal}}.

[[SI renovacion_automatica]]
Vencido el plazo, el contrato se renovará automáticamente por períodos iguales, salvo que cualquiera de LAS PARTES comunique por escrito su decisión de no renovarlo con al menos {{dias_preaviso}} días de anticipación al vencimiento.
[[FIN]]
[[SI sin_renovacion_automatica]]
Vencido el plazo, el contrato concluirá de pleno derecho, pudiendo LAS PARTES renovarlo únicamente mediante acuerdo escrito.
[[FIN]]

---

## SÉPTIMA.- (DE LOS HONORARIOS)

Por la prestación de sus servicios, EL PROPIETARIO pagará a EL AGENTE, en calidad de honorarios profesionales:

[[SI operacion_venta]]
El **{{comision_porcentaje}}% ({{comision_porcentaje_literal}} por ciento)** sobre el precio final de venta efectivamente pactado.
[[FIN]]
[[SI operacion_alquiler]]
El equivalente a **{{comision_meses}} ({{comision_meses_literal}}) mes(es)** del canon de alquiler efectivamente pactado.
[[FIN]]
[[SI operacion_anticretico]]
El **{{comision_porcentaje}}% ({{comision_porcentaje_literal}} por ciento)** sobre el monto de anticrético efectivamente pactado.
[[FIN]]

Dicho monto {{impuestos_texto}}. Los honorarios serán exigibles en su totalidad al momento de la suscripción de la minuta o contrato definitivo, o al momento en que EL PROPIETARIO reciba cualquier suma en calidad de arras, seña o anticipo, lo que ocurra primero. El pago se realizará mediante {{forma_pago}}.

---

## OCTAVA.- (DEL DEVENGO DE HONORARIOS EN CASOS ESPECIALES)

EL AGENTE tendrá derecho al pago íntegro de los honorarios pactados en la cláusula séptima en los siguientes casos:

a) Si durante la vigencia del contrato EL PROPIETARIO concreta la operación de manera directa o por intermedio de un tercero, en contravención de la cláusula cuarta.

b) Si dentro de los **{{dias_proteccion}} ({{dias_proteccion_literal}}) días** posteriores al vencimiento del contrato, EL PROPIETARIO concreta la operación con una persona presentada por EL AGENTE durante la vigencia del mismo. A tal efecto, EL AGENTE entregará a EL PROPIETARIO, al vencimiento, un registro escrito de los interesados presentados.

c) Si EL PROPIETARIO, habiendo aceptado por escrito una oferta ajustada al precio y condiciones de la cláusula quinta, desiste injustificadamente de concretar la operación.

d) Si EL PROPIETARIO revoca unilateralmente el presente contrato antes de su vencimiento sin causa justificada, pagará a EL AGENTE, en calidad de penalidad, el **{{penalidad_porcentaje}}%** de los honorarios calculados sobre el precio de oferta señalado en la cláusula quinta, sin perjuicio del devengo previsto en el inciso b).

---

## NOVENA.- (DE LAS OBLIGACIONES DEL AGENTE)

EL AGENTE se obliga a:

a) Promocionar el inmueble a través de portales inmobiliarios, redes sociales, su cartera de clientes y los demás canales que estime convenientes.

b) Elaborar material de promoción de calidad profesional (fotografías, descripción y, en su caso, video).

c) Calificar a los interesados y coordinar y acompañar las visitas al inmueble.

d) Informar a EL PROPIETARIO sobre las gestiones realizadas, visitas y ofertas recibidas, al menos cada **{{frecuencia_informe}} días**.

e) Asesorar a EL PROPIETARIO durante la negociación y en la revisión de la documentación necesaria para la operación.

f) Abstenerse de recibir sumas de dinero a nombre de EL PROPIETARIO sin su autorización expresa y escrita.

g) Guardar reserva sobre la información de EL PROPIETARIO y del inmueble.

---

## DÉCIMA.- (DE LAS OBLIGACIONES DEL PROPIETARIO)

EL PROPIETARIO se obliga a:

a) Entregar a EL AGENTE copia de la documentación del inmueble: Testimonio de propiedad, Folio Real actualizado, comprobantes de pago de impuestos al día, plano aprobado (si corresponde) y cédula de identidad.

b) Permitir las visitas de interesados, previa coordinación con al menos **{{horas_aviso_visita}} horas** de anticipación.

c) Mantener el inmueble en condiciones adecuadas de presentación durante la vigencia del contrato.

d) Comunicar de inmediato a EL AGENTE cualquier hecho que afecte la situación jurídica o física del inmueble.

e) Cumplir la exclusividad pactada en la cláusula cuarta y pagar los honorarios en la forma y plazo convenidos.

---

## DÉCIMA PRIMERA.- (DE LOS GASTOS)

Los gastos ordinarios de promoción correrán por cuenta de EL AGENTE[[SI gastos_extra]], salvo los siguientes gastos extraordinarios previamente acordados, que serán cubiertos por EL PROPIETARIO: {{gastos_extra_detalle}}[[FIN]]. Los gastos de transferencia, impuestos, aranceles notariales y de registro se regirán por lo que acuerden las partes de la operación definitiva y por la ley, y no serán de cargo de EL AGENTE.

---

## DÉCIMA SEGUNDA.- (DE LA AUTORIZACIÓN DE PUBLICIDAD)

EL PROPIETARIO autoriza a EL AGENTE a fotografiar y filmar el inmueble y a difundir dicho material con fines exclusivamente comerciales[[SI autoriza_letrero]], así como a colocar un letrero de oferta en el inmueble[[FIN]]. Por razones de seguridad, la dirección exacta del inmueble no será publicada sin autorización expresa de EL PROPIETARIO.

---

## DÉCIMA TERCERA.- (DE LAS DECLARACIONES DEL PROPIETARIO)

EL PROPIETARIO declara bajo su exclusiva responsabilidad que tiene plena capacidad y titularidad para disponer del inmueble, que la información y documentación proporcionadas son verídicas, y que responderá frente al futuro adquirente por evicción y vicios ocultos conforme a ley, liberando a EL AGENTE de toda responsabilidad derivada de información falsa, incompleta u omitida.

---

## DÉCIMA CUARTA.- (DE LA CONFIDENCIALIDAD Y DATOS PERSONALES)

LAS PARTES se obligan a utilizar la información y los datos personales contenidos en el presente contrato únicamente para los fines del mismo, absteniéndose de divulgarlos a terceros salvo lo estrictamente necesario para la ejecución de la operación o por mandato de autoridad competente.

---

## DÉCIMA QUINTA.- (DE LA RESOLUCIÓN)

El presente contrato podrá resolverse:

a) Por mutuo acuerdo de LAS PARTES, expresado por escrito.

b) Por incumplimiento grave de cualquiera de LAS PARTES, previa notificación escrita a la parte incumplida otorgándole un plazo de **{{dias_subsanacion}} días** para subsanarlo.

La resolución no afectará los honorarios ya devengados conforme a las cláusulas séptima y octava.

---

## DÉCIMA SEXTA.- (DE LAS COMUNICACIONES)

LAS PARTES señalan como válidos para toda comunicación los domicilios, teléfonos y correos electrónicos consignados en la cláusula primera. Las comunicaciones enviadas por correo electrónico o mensajería instantánea a dichos datos tendrán plena validez.

---

## DÉCIMA SÉPTIMA.- (DE LA SOLUCIÓN DE CONTROVERSIAS)

Cualquier controversia derivada del presente contrato será resuelta, en primera instancia, mediante negociación directa entre LAS PARTES en un plazo de quince (15) días. De no alcanzarse acuerdo, LAS PARTES se someten a la jurisdicción de los jueces y tribunales ordinarios de la ciudad de {{ciudad_jurisdiccion}}.

---

## DÉCIMA OCTAVA.- (DE LA CONFORMIDAD)

LAS PARTES declaran su plena conformidad con todas y cada una de las cláusulas del presente contrato, obligándose a su fiel cumplimiento, y lo suscriben en {{ejemplares}} ({{ejemplares_literal}}) ejemplares de un mismo tenor y validez, en la ciudad de {{ciudad_firma}}, {{fecha_firma_literal}}.

---

&nbsp;

| | |
|:---:|:---:|
| ______________________________ | ______________________________ |
| **{{propietario_nombre}}** | **{{agente_nombre}}** |
| C.I. Nº {{propietario_ci}} | C.I. Nº {{agente_ci}} |
| EL PROPIETARIO | EL AGENTE — {{agencia_nombre}} |

[[SI tiene_copropietario]]

| |
|:---:|
| ______________________________ |
| **{{copropietario_nombre}}** |
| C.I. Nº {{copropietario_ci}} |
| COPROPIETARIO(A) / CÓNYUGE |

[[FIN]]

---

## ANEXO A — DOCUMENTACIÓN RECIBIDA

| Documento | Recibido |
|---|:---:|
| Testimonio de propiedad | {{doc_testimonio}} |
| Folio Real actualizado | {{doc_folio}} |
| Impuestos al día | {{doc_impuestos}} |
| Plano aprobado | {{doc_plano}} |
| Copia de C.I. del propietario | {{doc_ci}} |
[[SI tiene_apoderado]]| Testimonio de poder | {{doc_poder}} |[[FIN]]

*Documento generado en bastet.uno · Nº {{numero_contrato}} · Código de verificación {{codigo_verificacion}}*
