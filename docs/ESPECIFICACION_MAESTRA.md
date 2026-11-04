# BASTET.UNO --- Especificación maestra de decisiones

**Versión:** 1.0\
**Estado:** Decisiones funcionales consolidadas\
**Uso:** Documento base para especificación e implementación en Claude
Code.

## 0. Propósito y convenciones

Este documento consolida las ocho decisiones aprobadas para BASTET.UNO.
Distingue: - **Aprobado:** regla confirmada por el usuario. -
**Configurable:** parámetro gestionable desde administración. -
**Revisión jurídica:** punto que debe revisar un profesional del derecho
en Bolivia antes de su activación contractual o sancionatoria. - **No
definido:** no debe resolverse mediante supuestos de desarrollo.

**Responsabilidad económica general:** el titular de la cuenta que
publica el inmueble ---agente, inmobiliaria o propietario--- responde
por las obligaciones económicas frente a BASTET. En Estadías, el huésped
paga el 10 % a BASTET y coordina directamente el 90 % restante con el
anfitrión. BASTET no custodia ese 90 %.

------------------------------------------------------------------------

# 1. Tarifas por conexión y comisiones

## 1.1 Responsable y momento de la conexión

-   El titular de la cuenta publicante paga la tarifa de conexión, sea
    agente o propietario.
-   En inmuebles tradicionales, la tarifa se activa cuando el agente
    acepta la solicitud de contacto.
-   Los datos del interesado permanecen ocultos hasta que BASTET
    verifique el pago.
-   La obligación económica de conexión se origina al aceptar la
    conexión.

## 1.2 Tarifa de conexión

La tarifa general es variable, entre **Bs 10 y Bs 200**.

  -----------------------------------------------------------------------
  Operación                                                   Rango/regla
  ------------------------------ ----------------------------------------
  Alquiler                                                      Bs 10--50

  Compraventa                                                  Bs 51--200

  Anticrético                                 Según matriz administrativa

  Estadías temporales             Flujo separado: 10 % del valor total de
                                                                  reserva
  -----------------------------------------------------------------------

La matriz de cálculo considera: - Tipo de operación: venta, alquiler,
anticrético o temporal. - Tipo de inmueble. - Valor económico. -
Naturaleza y duración del interés. - Tipo de interesado: comprador,
arrendatario o interesado temporal. - Calidad y probidad de la
oportunidad. - Otros criterios que administración incorpore.

El interés temporal debe tender a una tarifa menor. Las operaciones de
largo plazo ---compraventa, alquiler y anticrético--- deben tender a una
tarifa mayor.

**Administración debe poder** crear y editar criterios, rangos,
ponderaciones, activar/desactivar reglas, consultar el cálculo y revisar
el historial. La tarifa aplicada debe quedar congelada como dato
histórico de la conexión, aunque luego cambie la matriz.

## 1.3 Comisiones por operación

  Operación                                Comisión BASTET
  --------------------- ----------------------------------
  Compraventa                      0,75 % del precio total
  Alquiler                Equivalente a un mes de alquiler
  Anticrético                2 % del monto total entregado
  Estadías temporales      10 % del valor total de reserva

-   El responsable es el titular de la cuenta publicante, salvo el flujo
    de Estadías, donde el huésped paga el 10 % a BASTET.
-   La comisión de alquiler se hace efectiva al firmarse el contrato de
    alquiler.
-   La comisión de compraventa se reconoce al aceptar la conexión y se
    hace efectiva al concretarse la operación.
-   La comisión de anticrético es el 2 % del monto total entregado.
-   Todas las tarifas y comisiones BASTET se expresan y cobran en
    bolivianos.

## 1.4 Contrato marco y constancia individual

Antes de publicar su primera propiedad, el titular debe aceptar
digitalmente un contrato marco. Se acepta una vez, salvo que una nueva
versión requiera aceptación.

Cada conexión genera una constancia/anexo digital individual con: -
Titular publicante e interesado. - Inmueble y tipo de operación. -
Tarifa de conexión y obligación aplicable. - Fecha/hora de eventos
relevantes. - Versión del contrato marco aceptada.

## 1.5 Confirmación de compraventa y retiro de publicación

Cuando el titular intente retirar una publicación o marcarla como
vendida, el sistema consulta si la operación se concretó y si provino de
una conexión BASTET.

-   Se solicita confirmación al titular y al interesado.
-   El titular informa a quién vendió.
-   Si se confirma, se registra la operación y se calcula la comisión.
-   Sin confirmación suficiente, no se permite eliminarla bajo el estado
    "vendida"; la publicación continúa activa hasta resolver la
    situación.
-   Si el titular desiste y desea retirar el inmueble, completa una
    declaración jurada digital de desistimiento/rescisión.

Si se vende a una persona distinta del interesado original, no hay
atribución automática. Administración analiza individualmente si existe
relación con el interesado inicial ---por ejemplo, familiar o
allegado--- o si la operación deriva del contacto originado por BASTET,
incluso por WhatsApp.

## 1.6 Ocultamiento de operación

Ocultar una venta originada por conexión BASTET es falta grave.

-   La cuenta puede suspenderse durante la investigación.
-   Debe permitirse presentar descargos.
-   La investigación y decisión deben documentarse y pasar por revisión
    jurídica.
-   Penalización económica aprobada: **2,25 % del precio de la
    operación**, equivalente a tres veces la comisión original de
    compraventa del 0,75 %.
-   Tras investigación, descargos y revisión jurídica, la cuenta puede
    eliminarse permanentemente.

**Revisión jurídica obligatoria:** redacción y exigibilidad de la
cláusula penal, proporcionalidad, pruebas, procedimiento y sanción
conforme a normativa boliviana. No ejecutar sanciones irreversibles sin
revisión y resolución documentada.

------------------------------------------------------------------------

# 2. Moneda y tipos de cambio

-   El precio se muestra en la moneda original elegida por el
    publicante: USD o Bs.
-   Si se publica en USD, se muestra junto al precio el tipo de cambio
    de publicación aceptado por el publicante. No es obligatorio mostrar
    un equivalente calculado en Bs.
-   El **tipo de cambio de publicación** es distinto del **tipo de
    cambio interno BASTET**.
-   BASTET establece y actualiza periódicamente el tipo de cambio
    interno desde administración.
-   El tipo de cambio interno se usa para cálculos y obligaciones
    económicas de la plataforma.
-   Para calcular en Bs la comisión de una propiedad publicada en USD,
    se usa el tipo de cambio interno BASTET, nunca el de publicación.
-   Tarifas y comisiones BASTET siempre se cobran en Bs.

**Trazabilidad:** cada cálculo conserva el importe base, moneda, tipo de
cambio usado y fecha de vigencia. Una actualización posterior no
modifica obligaciones históricas.

------------------------------------------------------------------------

# 3. Estadías temporales: solicitud, aprobación, pago y conexión

## 3.1 Flujo aprobado

1.  El huésped solicita una reserva e indica fechas.
2.  El anfitrión debe aprobar o rechazar manualmente cada solicitud.
3.  Tiene **2 horas** para responder.
4.  Si acepta, el huésped paga a BASTET el **10 % del valor total**.
5.  Métodos iniciales: QR interbancario y transferencia bancaria.
6.  El huésped adjunta el voucher/comprobante.
7.  BASTET verifica administrativamente el comprobante.
8.  Solo tras verificar el pago se revela el contacto/WhatsApp y se
    genera la conexión.
9.  El huésped coordina directamente con el anfitrión el pago del saldo
    del **90 %**.

BASTET recibe solo el 10 %. El anfitrión recibe directamente del huésped
el 90 %. El sistema nunca debe presentar ese 90 % como dinero cobrado,
retenido o garantizado por BASTET.

## 3.2 Estados funcionales de referencia

-   `solicitada`
-   `pendiente_respuesta_anfitrion`
-   `rechazada`
-   `expirada`
-   `aceptada_pendiente_pago`
-   `comprobante_enviado`
-   `pago_en_revision`
-   `pago_verificado`
-   `conexion_generada`
-   `cancelada`
-   `en_disputa`

Los estados son una propuesta de nomenclatura técnica para implementar
el flujo aprobado; pueden ajustarse sin cambiar su semántica.

## 3.3 Cancelación por anfitrión

Si el anfitrión cancela una reserva confirmada: - BASTET devuelve el 100
% del 10 % que recibió. - Si el anfitrión recibió el 90 %, debe
devolverlo directamente al huésped. - BASTET facilita la gestión y puede
ayudar a buscar otra propiedad, pero no garantiza fondos que no
recibió. - Si se verifica una falta del anfitrión, BASTET puede
suspender su cuenta e impedir nuevas publicaciones.

## 3.4 Cancelación por huésped

-   Cancelación gratuita durante las 4 horas siguientes a la verificación del pago (cambio del 2026-11-03: reemplaza la regla de 72 horas antes de la llegada, que impedía cancelar reservas para el día siguiente).
-   Pasadas esas 4 horas se retiene el 20 % del valor total:
    10 % para BASTET y 10 % para el anfitrión.

Como el anfitrión puede haber recibido directamente el 90 %, el sistema
debe obligarlo a declarar si recibió ese importe y, cuando corresponda,
adjuntar el comprobante. Debe registrar: - Si recibió el pago directo. -
Importe y fecha. - Medio de pago, si se conoce. - Comprobante, cuando
exista. - Estado de revisión de la evidencia.

Distinguir: 90 % no recibido; recibido con comprobante; declarado
recibido sin comprobante; información controvertida o pendiente de
revisión.

BASTET no puede descontar ni devolver automáticamente fondos del
anfitrión que no controla. Puede documentar la obligación, solicitar
devolución, facilitar reclamos y aplicar medidas sobre la cuenta cuando
se verifique un incumplimiento.

## 3.5 Disputas

BASTET puede recibir denuncias, solicitar comprobantes, escuchar a ambas
partes, registrar evidencia y decisiones, devolver el importe que
recibió cuando corresponda y suspender al anfitrión si se verifica una
falta. La resolución económica del 90 % pagado directamente corresponde
a huésped y anfitrión. BASTET no garantiza fondos ajenos.

------------------------------------------------------------------------

# 4. Cancelaciones, confirmaciones e incidencias

Esta sección consolida las reglas transversales de Estadías.

  -----------------------------------------------------------------------
  Escenario                           Regla
  ----------------------------------- -----------------------------------
  Huésped cancela dentro de las 4 h   Cancelación gratuita
  siguientes a la verificación del   
  pago                                

  Huésped cancela pasadas esas 4 h    Retención del 20 % del total: 10 %
                                      BASTET y 10 % anfitrión

  Anfitrión cancela reserva           BASTET devuelve el 100 % del 10 %
  confirmada                          recibido; anfitrión devuelve
                                      directamente el 90 % si lo recibió
  -----------------------------------------------------------------------

Toda solicitud requiere aprobación manual del anfitrión en un plazo de 2
horas. La aceptación no revela el contacto: primero se verifica el pago
del 10 %.

En cancelaciones tardías, la declaración y comprobante del 90 % deben
quedar vinculados a la reserva. Administración debe consultar
cronología, pagos, evidencia y resolución. La asistencia de BASTET no
equivale a garantizar fondos que no recibió.

------------------------------------------------------------------------

# 5. Perfiles públicos, reputación, agentes y propietarios

## 5.1 Perfil de agente

Puede incluir descripción profesional, años de experiencia, idiomas,
contacto, redes sociales, matrícula/acreditación cuando corresponda y
otros datos que generen confianza.

## 5.2 Propietarios y reseñas

Agentes y propietarios pueden acumular reputación mediante operaciones
verificadas.

Las reseñas incluyen estrellas y comentarios sobre atención/servicio.
Solo clientes verificados pueden reseñar, y únicamente después de una
operación concretada mediante una conexión BASTET. Se pueden reseñar
perfiles de agentes y propietarios.

La reseña debe vincularse a la operación verificada que la habilita.

## 5.3 Tres distintivos independientes

**Agente verificado por BASTET** - Identidad personal y teléfono
verificados. - Documentación profesional revisada. - Contrato directo
con BASTET, por pertenecer a su plantilla/inmobiliaria o por relación
contractual directa.

**Propietario verificado** - Identidad y documentación correspondiente
revisadas.

**Propiedad verificada** - Identidad del propietario revisada. -
Documentación legal revisada. - Existencia física del inmueble
comprobada.

Los tres estados son independientes. Si publica un propietario
particular, se muestran propietario verificado y propiedad verificada
cuando corresponda. Si publica un agente, se muestran los distintivos
que correspondan a cada rol y verificación real. Reputación y
verificación no son equivalentes.

------------------------------------------------------------------------

# 6. Fotografías y contenido

-   Las fotografías las aporta el titular de la cuenta publicante:
    propietario, anfitrión o agente.
-   Se realiza revisión automática y moderación manual solo cuando sea
    necesario.
-   BASTET puede ofrecer sesiones fotográficas profesionales como
    servicio adicional pagado.
-   Dirección visual: fotografía inmobiliaria profesional, natural,
    luminosa, editorial premium y arquitectónica.

No se ha aprobado un catálogo exhaustivo de criterios de rechazo; no
inventarlo como política cerrada.

------------------------------------------------------------------------

# 7. Verificación de contratos, propiedades, agentes y operaciones

## 7.1 Sección Verificar

BASTET tendrá una pestaña **Verificar** para contratos, propiedades,
agentes y operaciones inmobiliarias.

## 7.2 Propiedad pendiente

Una propiedad puede publicarse con la etiqueta **"Pendiente de
verificación"**, pero no puede generar conexiones hasta completar la
verificación administrativa.

Un equipo administrativo especializado revisa documentos según tipo de
inmueble y operación.

## 7.3 Propiedad verificada

Implica: 1. Identidad del propietario revisada. 2. Documentación legal
revisada. 3. Existencia física del inmueble comprobada.

La verificación de agentes utiliza los requisitos definidos en la
sección 5. El distintivo "Verificado por BASTET" solo se muestra tras
completar los requisitos y obtener aprobación administrativa.

## 7.4 Operaciones verificadas

BASTET registra documentos de respaldo para compraventas, alquileres y
anticréticos, asociados a: - Conexión original. - Propiedad. - Partes
involucradas. - Tipo de operación. - Fechas y datos relevantes.

Una operación se marca verificada cuando existe documentación que
acredita que se concretó.

## 7.5 Dos documentos por operación

Se generan ambos:

1.  **Documento contractual o acta digital de operación**, que respalda
    la operación y recoge información y aceptación/firma de las partes
    según el flujo jurídico definido.
2.  **Certificado público de verificación**, con código único para
    consultar y comprobar la autenticidad del registro.

El certificado público no debe exponer información personal ni
contractual confidencial. Administración accede a la documentación de
respaldo según permisos; la vista pública se limita a los datos cuya
divulgación haya sido aprobada.

**Revisión jurídica y técnica:** mecanismo de firma, validez probatoria,
conservación, datos públicos, protección de datos y formato documental
deben definirse con asesoría jurídica boliviana antes de producción.

------------------------------------------------------------------------

# 8. Historias y estados temporales

**Decisión aprobada: no implementar por ahora.**

No desarrollar historias o estados temporales en esta versión. Priorizar
publicación y gestión de inmuebles, conexiones, monetización, Estadías,
perfiles, reputación, verificación y administración. No crear módulos o
modelos de historias salvo aprobación expresa posterior.

------------------------------------------------------------------------

# 9. Requisitos transversales del panel administrativo

## 9.1 Configuración económica

Administración gestiona matriz de tarifas, rangos, criterios,
ponderaciones, tipo de cambio interno e historial de cambios.

## 9.2 Pagos y comprobantes

Administración revisa vouchers de Estadías, aprueba/rechaza
comprobantes, registra responsable, fecha y motivo, y consulta
declaraciones/comprobantes del 90 % directo.

## 9.3 Conexiones y obligaciones

Administración consulta contrato marco y versión, constancias
individuales, titular responsable, tarifa aplicada, regla de cálculo,
pago, operación y comisión.

## 9.4 Investigación y sanciones

Administración abre investigaciones, registra evidencia y descargos,
mantiene cronología, documenta revisión jurídica y decisión, suspende
temporalmente y registra eliminación permanente cuando proceda.

## 9.5 Verificación

Administración revisa documentos, registra observaciones,
aprueba/rechaza verificaciones, gestiona pendientes, registra
operaciones, genera actas y certificados y consulta historial.

## 9.6 Auditoría

Para eventos económicos, contractuales, de pago, verificación y sanción
conservar: identificador, actor, fecha/hora, estado anterior/nuevo,
importe/moneda, parámetros de cálculo, evidencia y motivo/comentario
cuando aplique.

------------------------------------------------------------------------

# 10. Criterios de aceptación

## Conexiones y tarifas

-   [ ] El titular publicante es responsable económico, sea agente o
    propietario.
-   [ ] La tarifa se calcula con la matriz y rangos configurados.
-   [ ] Administración modifica la matriz sin despliegue de código.
-   [ ] La tarifa queda congelada como dato histórico de la conexión.
-   [ ] El contacto permanece oculto hasta verificar el pago.
-   [ ] Cada conexión genera constancia individual.
-   [ ] La primera publicación exige aceptación del contrato marco.

## Comisiones y moneda

-   [ ] Compraventa: 0,75 % del precio total.
-   [ ] Alquiler: un mes de alquiler, exigible al firmar contrato.
-   [ ] Anticrético: 2 % del monto total entregado.
-   [ ] Estadías: 10 % del valor total de reserva.
-   [ ] Tarifas y comisiones BASTET se expresan/cobran en Bs.
-   [ ] Publicaciones muestran moneda original.
-   [ ] Publicación en USD muestra el tipo de cambio aceptado por
    publicante.
-   [ ] Comisión de publicación USD utiliza tipo de cambio interno
    BASTET.
-   [ ] Los cálculos históricos conservan el tipo de cambio usado.

## Estadías y cancelaciones

-   [ ] Cada solicitud requiere aprobación manual del anfitrión.
-   [ ] La ventana de respuesta es de 2 horas.
-   [ ] Aceptar no revela contacto antes de verificar el pago.
-   [ ] El huésped adjunta comprobante y BASTET lo revisa.
-   [ ] Solo tras verificar el 10 % se genera conexión y se revela
    contacto.
-   [ ] El 90 % directo no aparece como dinero recibido por BASTET.
-   [ ] Cancelación gratuita dentro de las 4 h siguientes a la verificación del pago.
-   [ ] Cancelación pasadas esas 4 h: retención total del 20 %, reparto 10
    % BASTET / 10 % anfitrión.
-   [ ] El anfitrión declara si recibió el 90 % y adjunta comprobante
    cuando corresponda.
-   [ ] Cancelación por anfitrión: BASTET devuelve el 10 % recibido;
    anfitrión devuelve directamente el 90 % si lo recibió.

## Perfiles y reputación

-   [ ] Perfil agente admite datos profesionales.
-   [ ] Agentes y propietarios pueden acumular reputación.
-   [ ] Solo clientes de operaciones concretadas/verificadas mediante
    conexión BASTET pueden reseñar.
-   [ ] Agente, propietario y propiedad tienen verificaciones
    independientes.

## Fotografías

-   [ ] El titular aporta las fotos.
-   [ ] Hay revisión automática y moderación manual cuando sea
    necesaria.
-   [ ] Sesión profesional puede ofrecerse como servicio pagado
    opcional.

## Verificación

-   [ ] Propiedad pendiente puede publicarse, pero no generar
    conexiones.
-   [ ] Propiedad verificada tiene identidad, documentos legales y
    existencia física revisados.
-   [ ] Operaciones tienen documentos asociados a conexión, inmueble y
    partes.
-   [ ] Se genera documento contractual/acta digital.
-   [ ] Se genera certificado público con código único.
-   [ ] El certificado público no expone información confidencial.

## Historias

-   [ ] No se implementa el módulo de historias/estados temporales en
    esta versión.

------------------------------------------------------------------------

# 11. Revisión jurídica obligatoria en Bolivia

Solicitar revisión jurídica antes de activar: 1. Contrato marco digital
y mecanismo de aceptación. 2. Constancia/anexo individual de conexión.
3. Obligaciones económicas y momento de exigibilidad de comisiones. 4.
Cláusula penal de 2,25 % por ocultamiento de compraventa. 5.
Investigación, suspensión, descargos y eliminación de cuenta. 6.
Declaración jurada digital de desistimiento/rescisión. 7. Documentos de
alquiler, compraventa y anticrético. 8. Acta/contrato digital, mecanismo
de firma y validez probatoria. 9. Certificado público y datos que puede
divulgar. 10. Cancelaciones, retenciones y obligaciones directas entre
huésped y anfitrión. 11. Protección de datos, conservación documental y
acceso administrativo.

Este documento define decisiones de producto; no sustituye contratos ni
asesoramiento legal.

------------------------------------------------------------------------

# 12. Decisiones no definidas: no asumir durante el desarrollo

-   No existe rango fijo aprobado para conexión de anticrético; se
    calcula mediante matriz administrativa.
-   No existe atribución automática de una venta a una conexión cuando
    el comprador es distinto; requiere análisis individual.
-   No se implementa pasarela integrada de pago para Estadías en esta
    etapa; se usa QR/transferencia y comprobante.
-   BASTET no custodia el 90 % pagado directamente al anfitrión.
-   Firma y validez jurídica de actas/contratos requieren definición y
    revisión legal.
-   No está definido un catálogo exhaustivo de moderación fotográfica.
-   Historias/estados temporales quedan fuera de esta versión.

------------------------------------------------------------------------

## Adenda 2026-11-04 · Empresas aliadas (posterior a esta especificación)

-   Servicio para empresas con trabajadores que viajan dentro de Bolivia: atención preferencial y tarifa corporativa. Cuenta de tipo «empresa» → afiliación (razón social, NIT, contacto) revisada y activada por administración con un descuento corporativo → registro de trabajadores y solicitudes de alojamiento → cotización manual de Bastet.
-   No cambia el cobro de las reservas normales de Estadías (10 % al huésped, 90 % directo). Aplicar el descuento automáticamente en reservas queda como decisión abierta (cuánto baja el anfitrión y cuánto Bastet).
-   Todo apagado por defecto (`corporate_settings.enabled`). Descuento por defecto 10 % provisional. Detalle técnico en HANDOFF («Empresas aliadas»). No definido y a revisar por el abogado: convenio por empresa, condiciones de la tarifa corporativa, tratamiento de datos de trabajadores.


**Fin de la especificación maestra.**
