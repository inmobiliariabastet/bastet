# -*- coding: utf-8 -*-
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import cm
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer, PageBreak, Table, TableStyle,
                                KeepTogether, ListFlowable, ListItem)
from xml.sax.saxutils import escape

OUT = r'C:\Users\HP\Desktop\MATT FIRMA LEGAL\docs\BASTET_flujos_modelo_de_negocio_y_textos_legales.pdf'
GREEN = colors.HexColor('#3D4C3A'); GOLD = colors.HexColor('#B8923A'); SOFT = colors.HexColor('#EEF1EC'); LINE = colors.HexColor('#C9D1C6')
INK = colors.HexColor('#222222')

base = dict(fontName='Helvetica', textColor=INK, alignment=TA_LEFT)
body = ParagraphStyle('body', fontSize=10, leading=14.2, spaceAfter=6, **base)
small = ParagraphStyle('small', parent=body, fontSize=8.8, leading=12, spaceAfter=3)
legal = ParagraphStyle('legal', parent=body, fontSize=8.8, leading=12.2, spaceAfter=4.5)
legalh = ParagraphStyle('legalh', parent=legal, fontName='Helvetica-Bold', spaceBefore=5, spaceAfter=2)
h1 = ParagraphStyle('h1', fontName='Helvetica-Bold', fontSize=18, leading=22, textColor=GREEN, spaceBefore=4, spaceAfter=8)
h2 = ParagraphStyle('h2', fontName='Helvetica-Bold', fontSize=12.5, leading=16, textColor=GREEN, spaceBefore=10, spaceAfter=5)
h3 = ParagraphStyle('h3', fontName='Helvetica-Bold', fontSize=10.3, leading=13, textColor=INK, spaceBefore=6, spaceAfter=3)
cell = ParagraphStyle('cell', parent=body, fontSize=8.8, leading=11.6, spaceAfter=0)
cellb = ParagraphStyle('cellb', parent=cell, fontName='Helvetica-Bold')
cellw = ParagraphStyle('cellw', parent=cellb, textColor=colors.white)
cover1 = ParagraphStyle('c1', fontName='Helvetica-Bold', fontSize=30, leading=34, textColor=GREEN)
cover2 = ParagraphStyle('c2', fontName='Helvetica', fontSize=14, leading=19, textColor=INK)
note = ParagraphStyle('note', parent=body, fontSize=9, leading=12.5, backColor=SOFT, borderColor=LINE, borderWidth=0.6, borderPadding=7, spaceBefore=6, spaceAfter=10)

def P(t, s=body): return Paragraph(t, s)
def esc(t): return escape(t)

def bullets(items, style=body):
    return ListFlowable([ListItem(P(i, style), leftIndent=14) for i in items], bulletType='bullet', start='•', leftIndent=14, bulletFontSize=9)

def steps(items):
    return ListFlowable([ListItem(P(i, body), leftIndent=18) for i in items], bulletType='1', leftIndent=18, bulletFontName='Helvetica-Bold', bulletFontSize=9.5, bulletColor=GREEN)

def table(rows, widths, header=True):
    data = []
    for r, row in enumerate(rows):
        data.append([P(c, cellw if (header and r == 0) else (cellb if i == 0 else cell)) for i, c in enumerate(row)])
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0)
    st = [('VALIGN', (0, 0), (-1, -1), 'TOP'), ('GRID', (0, 0), (-1, -1), 0.4, LINE), ('LEFTPADDING', (0, 0), (-1, -1), 5), ('RIGHTPADDING', (0, 0), (-1, -1), 5),
          ('TOPPADDING', (0, 0), (-1, -1), 4), ('BOTTOMPADDING', (0, 0), (-1, -1), 4)]
    if header: st += [('BACKGROUND', (0, 0), (-1, 0), GREEN)]
    for r in range(1 if header else 0, len(rows)):
        if r % 2 == 0: st.append(('BACKGROUND', (0, r), (-1, r), SOFT))
    t.setStyle(TableStyle(st)); return t

def footer(c, d):
    c.saveState(); c.setFont('Helvetica', 8); c.setFillColor(colors.HexColor('#6b756a'))
    c.drawString(2 * cm, 1.2 * cm, 'Bastet.uno - Flujos, modelo de negocio y textos para revisión jurídica - Documento interno y confidencial')
    c.drawRightString(A4[0] - 2 * cm, 1.2 * cm, 'Página %d' % d.page)
    c.setStrokeColor(GOLD); c.setLineWidth(1); c.line(2 * cm, 1.6 * cm, A4[0] - 2 * cm, 1.6 * cm); c.restoreState()

doc = BaseDocTemplate(OUT, pagesize=A4, leftMargin=2 * cm, rightMargin=2 * cm, topMargin=1.8 * cm, bottomMargin=2.2 * cm,
                      title='Bastet.uno - Flujos, modelo de negocio y textos para revisión jurídica', author='Bastet', subject='Documento interno para el abogado')
doc.addPageTemplates([PageTemplate(id='p', frames=[Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id='f')], onPage=footer)])
W = doc.width
S = []

# ───────────── Portada
S += [Spacer(1, 5 * cm), P('BASTET', cover1), Spacer(1, 4), P('bastet.uno', cover2), Spacer(1, 30),
      P('<b>Cómo funciona la plataforma, su modelo de negocio vigente y los textos que debe revisar un abogado en Bolivia</b>', ParagraphStyle('c3', parent=cover2, fontSize=17, leading=23, textColor=GREEN)),
      Spacer(1, 24),
      P('Documento interno y confidencial. Preparado el 3 de noviembre de 2026.', cover2), Spacer(1, 6),
      P('Para: la propietaria de Bastet y el abogado que revisará el contrato marco, el acuerdo de anfitrión, la declaración jurada de desistimiento y el resto de textos legales.', cover2),
      Spacer(1, 40),
      P('<b>Importante.</b> Todos los textos legales de este documento son <b>borradores provisionales</b> redactados para poder probar la plataforma. Ninguno ha sido revisado por un abogado. No deben usarse con personas reales hasta que un abogado boliviano los revise, corrija y apruebe.', note),
      PageBreak()]

# ───────────── 1. Resumen
S += [P('1. Resumen en una página', h1),
      P('Bastet es una plataforma web de inmuebles en Bolivia. Publicar es <b>libre y sin vencimiento</b>: ya no hay planes ni suscripciones. Bastet gana de tres maneras distintas, según lo que haga la persona:'),
      table([['Qué hace la persona', 'Cuánto cobra Bastet', 'Quién paga y cuándo'],
             ['Reserva una estadía temporal (por noches)', '10 % del total de la reserva', 'El huésped, al confirmar la reserva. El 90 % restante lo paga directamente al anfitrión: Bastet no lo recibe ni lo custodia.'],
             ['Es contactada por un interesado en una venta, alquiler o anticrético (conexión)', 'Tarifa de conexión fija en bolivianos: alquiler de Bs 10 a 50, venta de Bs 51 a 200, anticrético según matriz', 'El titular que publica el inmueble, al aceptar la conexión. Bastet entrega los datos de contacto cuando verifica el pago.'],
             ['Concreta la venta, alquiler o anticrético con alguien conectado por Bastet', 'Venta 0,75 %, alquiler un mes, anticrético 2 %', 'El titular. Se calcula y congela al cerrar la operación en la plataforma.']],
            [W * .30, W * .32, W * .38]),
      Spacer(1, 6),
      P('Las reglas de Bastet para proteger ese modelo:'),
      bullets(['Los teléfonos de los inmuebles ya no se publican: se entregan solo después de una conexión pagada (venta, alquiler, anticrético) o de una reserva confirmada (estadías).',
               'Un inmueble con conexiones no se puede marcar como vendido ni retirar sin informar qué pasó: debe registrarse la operación o firmar una declaración jurada de desistimiento.',
               'Ocultar a Bastet una venta originada por una conexión es una falta grave: puede llevar a una investigación, suspensión y una cláusula penal del 2,25 % del precio, siempre con derecho a descargos y revisión jurídica.',
               'Existen tres distintivos de verificación independientes (agente, propietario, propiedad), reseñas solo de operaciones reales y un certificado público verificable por código.']),
      P('<b>Estado actual (3 de noviembre de 2026):</b> las estadías con pago del 10 % están en uso. Conexiones, comisiones, verificación, investigaciones y el acuerdo de anfitrión están construidos y probados, pero <b>apagados</b> hasta que la propietaria los active en el panel (<i>bastet.uno/admin</i>) y el abogado apruebe los textos.', note),
      PageBreak()]

# ───────────── 2. Modelo de negocio
S += [P('2. Modelo de negocio vigente', h1),
      P('Todo el dinero se maneja en <b>bolivianos (Bs)</b>. Cuando un precio está en dólares, Bastet usa un tipo de cambio interno (Bs por USD) que fija la administración. Cada valor económico se <b>congela</b> en el momento en que nace la obligación: si la tarifa o el tipo de cambio cambian después, no afecta lo ya registrado.'),
      P('2.1 Ingresos por tipo de operación', h2),
      table([['Operación', 'Tarifa de conexión (la paga el titular)', 'Comisión por operación concretada (la paga el titular)', 'Notas'],
             ['Alquiler', 'Matriz editable, rango aprobado Bs 10 a 50. Valor provisional actual: Bs 30', 'Un mes de alquiler', 'Los valores provisionales se ajustan en el panel.'],
             ['Venta', 'Rango aprobado Bs 51 a 200. Valor provisional: Bs 125', '0,75 % del precio de venta', 'La cláusula penal por ocultamiento es el triple: 2,25 %.'],
             ['Anticrético', 'Según matriz, de Bs 10 a 200. Valor provisional: Bs 100', '2 % del monto del anticrético', ''],
             ['Estadía temporal', 'No hay tarifa de conexión', '10 % del total de la reserva, pagado por el huésped a Bastet', 'El 90 % se paga directamente al anfitrión.']],
            [W * .15, W * .30, W * .30, W * .25]),
      P('2.2 Estadías temporales: reglas de dinero y cancelación', h2),
      bullets(['El anfitrión tiene <b>2 horas</b> para aceptar o rechazar una solicitud. Si la acepta, el huésped tiene <b>12 horas</b> para pagar el 10 % a Bastet.',
               'Al verificarse el pago, la reserva queda confirmada y se entregan al huésped el contacto del anfitrión, la ubicación y el calendario de fechas apartadas.',
               '<b>Cancelación del huésped:</b> gratis durante las <b>4 horas</b> siguientes a la verificación del pago. Pasado ese plazo se retiene el <b>20 %</b> del total: 10 % para Bastet y 10 % para el anfitrión. (Esto reemplaza la regla anterior de 72 horas antes de la llegada.)',
               '<b>Cancelación del anfitrión:</b> Bastet devuelve el 100 % del 10 % recibido. Si el anfitrión ya cobró el 90 %, debe devolverlo directamente al huésped. Bastet no garantiza fondos que no recibió, pero puede ayudar a buscar otra propiedad y suspender al anfitrión si se verifica una falta.',
               'El 90 % directo <b>no figura como dinero recibido por Bastet</b>. El anfitrión declara si lo recibió y puede adjuntar comprobante.']),
      P('2.3 Lo que Bastet no hace', h2),
      bullets(['No custodia dinero de alojamientos ni de compraventas: sus ingresos son la tarifa de conexión, la comisión y el 10 % de estadías.',
               'No garantiza que se concrete ninguna operación ni el estado legal o físico de un inmueble.',
               'No cobra automáticamente: los pagos son por transferencia o QR con comprobante, que el personal de Bastet verifica manualmente. Las devoluciones, comisiones y penalidades se registran en el sistema pero se cobran y pagan de forma manual.',
               'No envía WhatsApp automático: los avisos son botones de WhatsApp que el administrador pulsa (la API de WhatsApp Business tendría costo y requiere aprobación de Meta).']),
      PageBreak()]

# ───────────── 3. Flujos
S += [P('3. Cómo funcionan los flujos', h1),
      P('Esta sección describe cada flujo paso a paso: qué ve y hace cada persona. Quién es quién: el <b>titular</b> publica el inmueble; el <b>interesado</b> o <b>huésped</b> lo busca; el <b>administrador</b> es el personal de Bastet con acceso al panel.')]

S += [P('3.1 Registro y publicación', h2),
      steps(['La persona entra con su cuenta de Google desde el Inicio (botón «Acceder con cuenta», o «Registrarme como anfitrión») y completa su registro: nombre, teléfono, ciudad y <b>tipo de cuenta</b>: <b>cliente</b> (busca inmuebles o reserva estadías), propietario, agente o empresa.',
             'Publica un inmueble: tipo (casa, departamento, habitación o terreno), operación (venta, alquiler, anticrético o temporal), ciudad, dirección, fotos, precio, características.',
             'Si la operación es <b>venta, alquiler o anticrético</b> y las conexiones están activas, antes de publicar debe leer y aceptar el <b>contrato marco</b> (una vez por versión).',
             'Si la operación es <b>temporal</b>, debe aceptar en cambio el <b>acuerdo de anfitrión</b>. Las estadías no piden documentos de propiedad ni verificación de propiedad; el formulario de publicación tampoco los pide.',
             'Publicar es gratis y no vence. Solo la administración puede destacar una publicación.']),
      P('Las cuentas de agente o empresa pueden firmar además un <b>contrato de exclusividad</b> o de colaboración con Bastet (plantillas en el panel, sección Contratos).', small),
      P('3.2 Estadías temporales: la reserva', h2),
      steps(['El huésped elige una estadía, las fechas y la cantidad de personas. El calendario bloquea las fechas ocupadas.',
             'Pide la reserva dejando nombre y teléfono. Nace una solicitud con código de 10 caracteres.',
             'El anfitrión recibe el aviso en su panel (y el administrador pulsa el botón de WhatsApp para avisarle). Tiene 2 horas para aceptar o rechazar.',
             'Si acepta, el huésped tiene 12 horas para pagar el 10 % a Bastet y subir el comprobante, siguiendo las instrucciones de pago y el QR.',
             'El administrador revisa el comprobante. Si lo aprueba, la reserva queda confirmada: se muestran al huésped el <b>WhatsApp del dueño de la publicación</b> (para coordinar la llegada y el saldo), la ubicación, las fotos y el calendario, y la publicación aparece como <b>«En uso»</b> con la fecha en que vuelve a estar disponible.',
             'Durante las 4 horas siguientes el huésped puede cancelar sin costo; después se aplica la retención del 20 %.',
             'Al terminar la estadía, el huésped puede dejar una reseña mediante un enlace único.',
             'Cualquier persona puede verificar una reserva en <i>bastet.uno/verificar.html</i> con su código: ve el mensaje de reserva verificada y su historial.']),
      P('3.3 Conexiones (venta, alquiler, anticrético)', h2),
      steps(['El interesado abre un inmueble y pulsa el botón de contacto. El teléfono <b>no aparece</b>: debe dejar nombre, teléfono, mensaje y aceptar el tratamiento de sus datos. Esto crea una solicitud de conexión.',
             'El titular recibe el aviso. Puede <b>aceptar</b> o <b>rechazar</b> la conexión. Al aceptar nace su obligación: se congela la tarifa en bolivianos y se numera la <b>constancia de conexión</b> con la versión del contrato marco aceptada.',
             'El titular paga la tarifa siguiendo las instrucciones de pago y sube el comprobante.',
             'El administrador verifica el pago. Recién entonces Bastet entrega al interesado el contacto del titular y al titular los datos del interesado.',
             'Si una cuenta tiene la «verificación exigida» activada, las propiedades sin verificar muestran la etiqueta «Pendiente de verificación» y no reciben solicitudes.']),
      P('Protecciones técnicas: los teléfonos nunca se descargan con la lista de inmuebles; el sistema limita los intentos por dirección IP; los datos de cada persona quedan privados entre cuentas; las fotos solo las sube su dueño; y los documentos se guardan en carpetas privadas.', small),
      P('3.4 Cierre de una operación, comisión y desistimiento', h2),
      steps(['Cuando el titular quiere marcar el inmueble como vendido, alquilado o en anticrético, o retirarlo, el sistema revisa si tiene conexiones de Bastet. Si las tiene, <b>no se permite cerrar a mano</b>: aparece el formulario de cierre.',
             'El titular informa si la operación se concretó, con quién (nombre y teléfono), el monto y la fecha. Se registra la operación y se calcula la <b>comisión</b>, que se congela en bolivianos.',
             'El interesado recibe un enlace (<i>confirmar.html</i>) para confirmar la operación y dejar una reseña. Sin confirmación suficiente, el inmueble sigue publicado hasta aclarar.',
             'Si el inmueble se vendió a una persona distinta del interesado original, no hay atribución automática: la administración analiza si existe relación (un familiar o allegado, o contacto continuado por WhatsApp).',
             'El titular paga la comisión con comprobante; el administrador la verifica. La operación confirmada genera un <b>acta digital</b> imprimible y un código de certificado.',
             '<b>Si el titular solo desiste</b> (retira el inmueble sin concretar nada), firma una <b>declaración jurada digital de desistimiento</b> afirmando que no concretó la operación con personas conectadas por Bastet.']),
      P('3.5 Verificación, reputación y certificado público', h2),
      bullets(['<b>Tres distintivos independientes</b>, que solo Bastet concede tras revisar documentos subidos a una carpeta privada: <b>Agente verificado</b>, <b>Propietario verificado</b> y <b>Propiedad verificada</b>. Tener uno no implica tener los otros.',
               'Cada verificación exige una lista de comprobaciones que el administrador debe marcar (identidad, teléfono, documentación, existencia física del inmueble, según el tipo). Puede aprobar, rechazar con motivo o revocar.',
               'Las <b>estadías temporales no necesitan verificación de propiedad ni documentos de propiedad</b>.',
               'Solo escribe reseña quien concretó una operación mediante una conexión de Bastet (o una estadía reservada). Las reseñas no se pueden comprar ni pedir libremente.',
               'En <i>bastet.uno/verificar.html</i> cualquier persona puede consultar, con el código, una propiedad (BST-####), un agente (AG-XXXXXX), un certificado de operación (OP-XXXXXXXX), una solicitud de contacto o su constancia de conexión (BST-CX-AAAA-NNNN) o una reserva. Solo se muestran datos mínimos; nunca teléfonos ni documentos.']),
      P('3.6 Investigaciones y sanciones', h2),
      steps(['La administración abre una investigación (por ejemplo, por ocultamiento de una operación) y registra la evidencia. La cuenta puede suspenderse mientras dura.',
             'Se notifica a la persona investigada un enlace (<i>descargos.html</i>) con un plazo para presentar descargos y pruebas.',
             'El caso pasa a <b>revisión jurídica</b>. La decisión debe quedar documentada por escrito.',
             'Si corresponde, se impone la <b>cláusula penal del 2,25 %</b> del precio de la operación (tres veces la comisión de venta), congelada en bolivianos. Su cobro se registra como pagado o anulado.',
             'La <b>eliminación permanente de una cuenta</b> solo puede autorizarse en el registro de la investigación; el sistema nunca la ejecuta por sí solo.']),
      P('3.7 Otros flujos', h2),
      bullets(['<b>«Publicar mi inmueble»</b> (landing): formulario con título y mensajes propios para venta, alquiler, anticrético o estadía temporal; pide documentos opcionales para que Bastet gestione la operación, salvo en estadías temporales, que no piden documentos de propiedad; la solicitud se atiende desde el panel.',
               '<b>«Busco un inmueble»</b>: la persona describe lo que busca (operación, tipo, ciudad, presupuesto) y queda registrada para que agentes y administración la atiendan.',
               '<b>Favoritos y listas</b>: quien tenga cuenta puede guardar inmuebles.',
               '<b>Contratos</b>: plantillas de contratos (exclusividad, colaboración, compraventa y otros) que el panel genera con los datos de las partes. Las plantillas están en <i>assets/contracts/</i> y en <i>assets/js/contracts/</i>.']),
      P('3.8 Cuenta de cliente y «Mi espacio»', h2),
      bullets(['El <b>cliente</b> no publica inmuebles ni usa herramientas de agente. Su panel tiene solo <b>Mi espacio</b> y <b>Mi cuenta</b>. En <b>Mi cuenta</b> y en el menú lateral cada persona ve su tipo de cuenta (cliente, propietario, agente, empresa o administrador).',
               '<b>Mi espacio</b> muestra el siguiente paso de cada solicitud o reserva (pagar el 10 %, escribir por WhatsApp cuando la conexión se generó, esperar o ver alternativas), accesos a comprar, alquilar, anticrético y estadías, <b>Mis reservas</b>, <b>Mis solicitudes de contacto</b>, recomendados según lo que ya guardó o pidió, y favoritos.',
               'Las solicitudes de contacto y las reservas hechas con la sesión iniciada quedan ligadas a la cuenta; sin sesión siguen funcionando. Los formularios se precargan con nombre, WhatsApp y correo.',
               'Un cliente puede pasar a propietario, agente o empresa desde Mi espacio; no se puede volver a cliente por cuenta propia. Los <b>contratos de exclusividad</b> son solo para agentes y empresas (y administración).']),
      P('3.9 Eliminar mi cuenta', h2),
      steps(['En el panel, <i>Mi cuenta</i>, la persona pulsa <b>Eliminar mi cuenta</b>. El sistema comprueba si tiene pendientes.',
             'Solo se puede eliminar si <b>no hay pagos pendientes ni disputas abiertas</b>: tarifas de conexión o comisiones sin pagar, inmuebles con conexiones sin cerrar la operación, operaciones por confirmar, reservas en curso o en disputa, investigaciones abiertas o penalizaciones sin resolver, cobranzas y pedidos legales sin terminar. Si hay pendientes, el panel los lista. Las cuentas de administración no se eliminan por aquí.',
             'Si no hay pendientes, escribe la palabra ELIMINAR para confirmar. Se retiran sus inmuebles disponibles, se borran su perfil, favoritos, búsquedas, datos legales y solicitudes de verificación (con sus documentos, si el almacenamiento lo permite), se cierra su acceso y su correo queda libre.',
             'Bastet <b>conserva</b> los registros de conexiones, operaciones, actas, reservas, aceptaciones de contratos e investigaciones, por obligación contractual y como prueba. Esto se explica en la política de privacidad.']),
      P('3.10 Inicio del sitio', h2),
      bullets(['El Inicio (bastet.uno) tiene un buscador con cuatro modos: Comprar, Alquilar, Anticrético y Estadías por noche (con fechas y huéspedes).',
               'Debajo hay filas tipo carrusel con estadías (global y por ciudad) y con inmuebles en venta, alquiler y anticrético, cada tarjeta con corazón de favoritos y enlace a su ficha.',
               'Un botón <b>Registrarme como anfitrión</b> lleva al registro con la cuenta de propietario sugerida; después el anfitrión publica su estadía temporal y acepta el acuerdo de anfitrión.',
               'Se mantienen las secciones de empresas que trabajan con Bastet y de testimonios (ambas se administran en el panel, pestañas Marcas y Testimonios; en Marcas, el lugar de relleno lo ocupa la tarjeta «Hospeda a tu gente con nosotros», que lleva al registro de anfitriones), y la oferta de vender con respaldo legal.']),
      P('3.11 Empresas aliadas (alojamiento corporativo)', h2),
      bullets(['La tarjeta «Hospeda a tu gente con nosotros» de la franja de empresas lleva a <i>bastet.uno/empresas.html</i>, página que explica el servicio y permite <b>crear la cuenta de empresa</b>.',
               'La cuenta de empresa pide en <b>Mi empresa</b> la afiliación corporativa (razón social, NIT, contacto, cuántos trabajadores viajan). Administración la revisa y la activa fijando un <b>descuento corporativo</b>.',
               'Una empresa activa registra a sus trabajadores (no necesitan cuenta) y envía solicitudes de alojamiento (ciudad, fechas, cuántos viajan). Administración las atiende primero, <b>cotiza manualmente</b> a tarifa corporativa y coordina por WhatsApp. No cambia el cobro de las reservas normales.',
               'Todo está apagado hasta encenderlo en el panel (pestaña Empresas). <b>Para el abogado:</b> condiciones de la tarifa corporativa, contrato o convenio con cada empresa, tratamiento de los datos de los trabajadores (nombre, CI, teléfono) y responsabilidad de Bastet frente a la empresa.']),
      PageBreak()]

# ───────────── 4. Qué está activo
S += [P('4. Qué está activo y qué está apagado', h1),
      table([['Módulo', 'Estado hoy', 'Cómo se enciende', 'Condición para encender'],
             ['Estadías con pago del 10 %', 'Activo', 'Panel, Reservas', 'Ya configurado (instrucciones de pago, QR, tipo de cambio).'],
             ['Retiro de suscripciones', 'Hecho', '-', 'Publicar es libre y sin vencimiento.'],
             ['Conexiones y tarifas', 'Apagado', 'Panel, Conexiones, interruptor', 'Instrucciones de pago, texto del contrato marco y matriz de tarifas.'],
             ['Operaciones y comisiones', 'Listo, depende de Conexiones', 'Panel, Operaciones', 'Texto de la declaración jurada de desistimiento.'],
             ['Verificación', 'Listo, sin exigencia', 'Panel, Verificación: «exigir verificación»', 'Verificar primero un grupo de propiedades.'],
             ['Investigaciones', 'Solo administración', 'Panel, Investigaciones', 'Revisión jurídica para cada sanción.'],
             ['Cuentas de cliente y Mi espacio', 'Activo en cuanto se corra su SQL', 'Se elige al registrarse', 'Ninguna.'],
             ['Eliminar mi cuenta', 'Activo', 'Panel, Mi cuenta', 'Ninguna: se aplica a todas las cuentas que no son de administración.'],
             ['Acuerdo de anfitrión', 'Apagado (sin texto)', 'Panel, Reservas, tarjeta «Acuerdo de anfitrión»', 'Pegar el texto revisado por el abogado.']],
            [W * .24, W * .20, W * .27, W * .29]),
      P('Todos los módulos nuevos se apagan dejando vacío el texto correspondiente o con el interruptor del panel. Cambiar un texto legal sube su versión y todos los usuarios deben volver a aceptarlo.', note),
      PageBreak()]

# ───────────── 5. Lo que debe revisar el abogado
S += [P('5. Lo que debe revisar el abogado', h1),
      P('La siguiente tabla lista cada documento o regla con implicancia legal, dónde se edita y qué preguntas concretas necesitan respuesta. Los tres primeros están redactados como anexos (secciones 7, 8 y 9). La política de privacidad y los términos de uso ya están publicados en el sitio como borradores. Los demás son reglas del modelo que debe validar y, cuando corresponda, redactar.'),
      table([['Documento o regla', 'Dónde se edita', 'Qué debe resolver el abogado'],
             ['Contrato marco de conexiones (anexo A)', 'Panel, Conexiones, «Contrato marco». Cambiarlo sube la versión.', 'Razón social, NIT, domicilio y representante de Bastet. Validez de la aceptación electrónica con casilla. Exigibilidad de tarifas, comisiones y cláusula penal. Foro y ley aplicable.'],
             ['Acuerdo de anfitrión de estadías (anexo B)', 'Panel, Reservas, «Acuerdo de anfitrión».', 'Exigibilidad de que el 90 % pagado directamente no sea responsabilidad de Bastet. Proporcionalidad de la retención del 20 %. Qué es «cancelación sin causa justificada».'],
             ['Declaración jurada de desistimiento (anexo C)', 'Panel, Operaciones.', 'Si una declaración por casilla tiene valor probatorio. Duración y condiciones de la cláusula 6 (pagar comisión si se vende después a un conectado).'],
             ['Cláusula penal del 2,25 % por ocultamiento', 'Cláusula 7 del contrato marco; código fijo en el sistema.', 'Si es una cláusula penal válida, proporcional y exigible en Bolivia; cómo probar el ocultamiento; si cabe reclamar además la comisión.'],
             ['Procedimiento de descargos y sanciones', 'Pestaña Investigaciones y página de descargos.', 'Plazo de descargos (hoy «razonable», conviene fijar días), forma de notificación, quién decide, recursos del investigado, y cuándo procede la eliminación de una cuenta.'],
             ['Constancia de conexión', 'Se genera sola con cada conexión.', 'Si basta como prueba de la conexión; qué datos debe incluir.'],
             ['Acta digital y certificado público de una operación', 'Se generan solos al confirmar una operación.', 'Valor probatorio del acta. Qué datos pueden mostrarse públicamente en el certificado.'],
             ['Reglas de cancelación de Estadías', 'Valores fijos en Reservas; texto en el acuerdo de anfitrión.', 'Que el reembolso y la retención se informen claramente al huésped. Relación con normas de protección al consumidor.'],
             ['Condiciones de la reserva para el huésped', 'Pantalla de reserva del sitio.', 'No existen aún términos propios para el huésped. Conviene redactarlos: reglas de pago, cancelación, uso de datos.'],
             ['Política de privacidad (borrador actualizado el 3 de noviembre)', 'Archivo privacidad.html del sitio.', 'Ya incluye: datos de reservas, conexiones, pagos, verificación, operaciones, reseñas e investigaciones; con quién se comparten; conservación; derechos y eliminación de cuenta. Falta la revisión del abogado: bases legales, plazos de conservación concretos, transferencia de datos fuera de Bolivia y el procedimiento de derechos de las personas.'],
             ['Eliminación de cuenta y datos conservados', 'Panel, Mi cuenta (texto en la política de privacidad, sección 7).', 'Qué registros pueden conservarse y por cuánto tiempo tras eliminar una cuenta; si la anonimización cumple la ley; plazo de respuesta a pedidos de eliminación; qué pasa con los reclamos de terceros.'],
             ['Contratos de exclusividad y colaboración', 'assets/contracts/ (plantillas).', 'Ya existían: confirmar que siguen vigentes y que no contradicen el nuevo modelo (sin suscripción, con tarifas y comisiones).'],
             ['Términos de uso del sitio (borrador del 3 de noviembre)', 'Archivo terminos.html del sitio.', 'Revisar el conjunto: cuentas, contenido, conexiones y comisiones (resumen que remite al contrato marco), estadías, conductas no permitidas, limitación de responsabilidad, ley aplicable y foro. Conviene añadir el NIT y los datos de registro de Bastet.']],
            [W * .25, W * .27, W * .48]),
      Spacer(1, 6),
      P('<b>Datos que solo la propietaria puede dar al abogado:</b> el NIT, el representante legal y su poder, la cuenta bancaria para cobros y el tipo de cambio interno que se usará. La razón social (Bastet Real State S.R.L.) y el domicilio (Calle Yanacocha, Edif. Cristal, Piso 7, Of. 706, La Paz) ya figuran en el sitio; los anexos A, B y C dicen solo «Bastet» y deben completarse con esos datos.', note),
      PageBreak()]

# ───────────── 6. Límites conocidos
S += [P('6. Límites conocidos de la plataforma', h1),
      bullets(['Cuando una persona recibe un contacto verificado puede intentar usarlo por fuera de Bastet. Lo cubren el contrato marco, la cláusula penal y las investigaciones, pero no lo impide la tecnología.',
               'El blindaje de datos rige solo después de correr el SQL de seguridad (ya aplicado a la base de datos real). Mientras las conexiones estén apagadas, el teléfono de una propiedad aún se entrega a quien lo pide, uno por consulta y con límite de intentos.',
               'Las subidas de archivos de «Vender mi inmueble» siguen abiertas sin cuenta, con tope de tamaño y tipo de archivo.',
               'La política de seguridad de contenido admite scripts dentro de la página (unsafe-inline) por el diseño actual del sitio.',
               'El límite de intentos por dirección IP depende de la IP que informe el servidor de Bastet.',
               'Los pagos, comisiones, devoluciones y penalidades se registran y se cobran manualmente: no hay pasarela de pago.',
               'Al eliminar una cuenta se borran los documentos de verificación desde el navegador de la persona, con mejor esfuerzo: si el almacenamiento no lo permite, quedan en la carpeta privada hasta que la administración los purgue.',
               'Los avisos por WhatsApp son manuales (un botón por solicitud, a pulsar dentro de las 2 horas de plazo).',
               'Las pantallas nuevas se probaron con datos simulados y la base de datos con réplicas locales. Falta una prueba de punta a punta con cuentas reales antes del lanzamiento público.']),
      PageBreak()]

# ───────────── Anexos
def legal_text(raw):
    out = []
    for blk in raw.strip().split('\n'):
        blk = blk.rstrip()
        if not blk: continue
        t = esc(blk)
        if blk[:3].strip() and (blk[0].isdigit() or blk.isupper()) and (len(blk) < 90 and not blk.startswith(('a)', 'b)', 'c)', 'd)'))):
            out.append(P(t, legalh))
        else:
            out.append(P(t, legal))
    return out

A = '''CONTRATO MARCO DE USO DE LA PLATAFORMA BASTET (versión provisional 1)

1. QUIÉNES PARTICIPAN
Este contrato lo celebran, por un lado, BASTET (en adelante "Bastet"), operadora de la plataforma bastet.uno, y por otro la persona natural o jurídica que publica un inmueble (en adelante "el Titular"). Al marcar la casilla de aceptación, el Titular declara haber leído este contrato, entenderlo y obligarse a cumplirlo. La aceptación queda registrada con fecha, hora y versión del texto.

2. QUÉ HACE BASTET
Bastet es una plataforma de publicación y conexión. Pone en contacto al Titular con personas interesadas en su inmueble. Bastet no es parte de la compraventa, alquiler ni anticrético que las partes decidan celebrar, no garantiza que se concrete ninguna operación, y no responde por el estado legal o físico del inmueble, ni por el comportamiento de terceros.

3. DECLARACIONES DEL TITULAR
El Titular declara que:
a) Es propietario del inmueble o cuenta con autorización suficiente para ofrecerlo, y puede acreditarlo si Bastet se lo pide.
b) La información y las fotografías que publica son verdaderas, actuales y no engañosas.
c) Sus datos de contacto son reales y se mantendrán actualizados.
d) No publicará inmuebles de terceros sin autorización, ni contenido ilegal.

4. CONEXIÓN Y TARIFA DE CONEXIÓN
4.1. Se llama "conexión" a la entrega al Titular de los datos de contacto de una persona interesada que solicitó información sobre su inmueble a través de Bastet.
4.2. Por cada conexión, el Titular paga a Bastet una tarifa de conexión cuyo monto depende del tipo de operación (alquiler, venta, anticrético) según la tabla vigente publicada en la plataforma al momento de la conexión. El monto aplicable se fija y queda registrado en la constancia de la conexión; los cambios posteriores de la tabla no alteran conexiones ya registradas.
4.3. Las tarifas se expresan y cobran en bolivianos (Bs), con el tipo de cambio interno de Bastet cuando corresponda convertir desde dólares.
4.4. Bastet entrega los datos de contacto cuando verifica el pago, siguiendo las instrucciones de pago indicadas en la plataforma. Bastet puede rechazar o dejar pendiente una conexión si el comprobante es ilegible o no coincide.
4.5. Cada conexión genera una constancia digital con número propio, que identifica al Titular, a la persona interesada, el inmueble, el tipo de operación, la tarifa y las fechas de los hechos relevantes.

5. COMISIÓN POR OPERACIÓN CONCRETADA
5.1. Si la operación se concreta con una persona que llegó al inmueble por una conexión de Bastet, el Titular paga además a Bastet una comisión, calculada así:
 - Venta: 0,75 por ciento del precio de la operación.
 - Alquiler: el equivalente a un (1) mes de alquiler.
 - Anticrético: 2 por ciento del monto del anticrético.
5.2. La comisión se calcula sobre el precio efectivamente pactado y se registra en bolivianos al momento de cerrar la operación en la plataforma. Su pago se hará según las instrucciones que Bastet comunique.
5.3. Si el inmueble se concreta con una persona distinta de la interesada original, Bastet analizará caso por caso si la operación deriva del contacto originado por Bastet (por ejemplo, un familiar o allegado de la persona interesada, o un contacto continuado por otro medio, incluido WhatsApp). El Titular se compromete a colaborar con ese análisis y a responder con veracidad.
5.4. La tarifa de conexión ya pagada no se descuenta de la comisión salvo que Bastet lo indique expresamente.

6. CIERRE, RETIRO Y CONFIRMACIÓN DE OPERACIONES
6.1. Si el Titular desea marcar un inmueble como vendido, alquilado o dado en anticrético, o retirarlo de la plataforma, y ese inmueble tiene conexiones registradas, debe informar si la operación se concretó, con quién y por qué monto.
6.2. Bastet puede pedir confirmación a la persona interesada. Si no hay confirmación suficiente, el inmueble puede permanecer publicado hasta que se aclare la situación.
6.3. Si el Titular decide retirar el inmueble sin haberlo vendido, alquilado o dado en anticrético, firmará una declaración jurada digital de desistimiento en la que afirma que no concretó ninguna operación con personas conectadas por Bastet.
6.4. Cada cierre genera un acta digital con número propio y datos de las partes, que Bastet podrá exhibir como constancia.

7. OCULTAMIENTO DE OPERACIONES
7.1. Ocultar a Bastet una operación originada por una conexión de Bastet es una falta grave.
7.2. En ese caso, Bastet podrá abrir una investigación, suspender la cuenta de forma provisional mientras dure, y exigir al Titular, como cláusula penal, el equivalente al 2,25 por ciento del precio de la operación (tres veces la comisión original de venta del 0,75 por ciento), sin perjuicio de cobrar la comisión que corresponda y de otras acciones legales.
7.3. Antes de decidir, Bastet notificará al Titular los hechos que se le atribuyen y le dará un plazo razonable para presentar descargos y pruebas. La decisión será por escrito, documentada, y revisada jurídicamente. Ninguna sanción irreversible, como la eliminación de la cuenta, se aplicará sin ese procedimiento.

8. VERIFICACIÓN
8.1. Bastet puede ofrecer distintivos de verificación (de persona o empresa, de propietario y de inmueble). Cada distintivo es independiente: tener uno no implica tener los otros.
8.2. Los distintivos se otorgan con base en los documentos y la información que el Titular presente, y pueden retirarse si se descubre que son falsos, vencidos o engañosos. La verificación no sustituye la debida diligencia de las partes ni constituye garantía de Bastet sobre el inmueble o la operación.

9. SUSPENSIÓN Y TERMINACIÓN
Bastet puede suspender o cerrar una cuenta cuando se incumpla este contrato, cuando exista fraude o suplantación, o por orden de autoridad competente, siguiendo el procedimiento de la cláusula 7 cuando corresponda. El Titular puede dejar de usar la plataforma y retirar sus publicaciones, cumpliendo la cláusula 6.

10. PROTECCIÓN DE DATOS PERSONALES
10.1. Bastet usa los datos del Titular y de las personas interesadas para operar la plataforma, verificar identidad, registrar conexiones y operaciones, y atender reclamos. No vende datos a terceros.
10.2. Los datos de contacto de las personas interesadas se entregan al Titular únicamente para atender la consulta sobre el inmueble indicado, y no deben usarse para otros fines ni compartirse con terceros.
10.3. Los documentos presentados para la verificación se guardan de forma privada y solo los ve el personal autorizado de Bastet.

11. DEBERES DE BUENA FE
El Titular no intentará evitar el pago de tarifas o comisiones, por ejemplo cerrando la operación por fuera de la plataforma con una persona conectada por Bastet, ni usará datos de la plataforma para fines distintos a los permitidos.

12. CAMBIOS AL CONTRATO
Bastet puede actualizar este contrato. Cada texto nuevo tiene un número de versión, y el Titular deberá aceptar la versión vigente antes de seguir publicando. Las conexiones ya registradas se rigen por la versión que estaba aceptada cuando se registraron.

13. LEY APLICABLE Y CONTROVERSIAS
Este contrato se rige por las leyes del Estado Plurinacional de Bolivia. Las partes procurarán resolver cualquier controversia de buena fe y por vía directa; de no lograrlo, se someterán a la jurisdicción de los tribunales competentes del domicilio de Bastet.

14. ACEPTACIÓN ELECTRÓNICA
El Titular reconoce que marcar la casilla de aceptación en la plataforma equivale a su consentimiento expreso a este contrato, y acepta que el registro electrónico de la fecha, hora y versión sirva como prueba de su aceptación.'''

B = '''ACUERDO DE ANFITRIÓN DE ESTADÍAS TEMPORALES DE BASTET (versión provisional 1)

1. QUÉ ES ESTE ACUERDO
Lo celebran BASTET (en adelante "Bastet"), operadora de bastet.uno, y la persona que ofrece un inmueble o habitación por noches en la sección Estadías (en adelante "el Anfitrión"). Aplica solo a estadías temporales. No es una venta, alquiler ni anticrético, y no se rige por el contrato marco de conexiones y comisiones.

2. ROL DE BASTET
Bastet publica la oferta, recibe las solicitudes de reserva y facilita el contacto entre el huésped y el Anfitrión. Bastet no es el alojamiento ni parte del servicio de hospedaje, no custodia el dinero del alojamiento y no garantiza que haya reservas.

3. DECLARACIONES DEL ANFITRIÓN
Declaro que:
a) Puedo ofrecer este alojamiento (soy su propietario, inquilino autorizado o administrador con permiso).
b) La descripción, las fotografías, el precio, la capacidad y las reglas que publico son verdaderos y están actualizados.
c) Mantendré mi calendario y mis datos de contacto al día.
d) El alojamiento es seguro y cumple con lo que la ley exija para recibir huéspedes.
Reconozco que, por tratarse de una estadía temporal, Bastet no me pide documentos de propiedad.

4. FLUJO DE UNA RESERVA
4.1. El huésped solicita fechas. Tengo 2 horas para aceptar o rechazar desde el aviso en mi panel (y por WhatsApp si Bastet lo envía). Si no respondo, la solicitud puede vencer.
4.2. Si acepto, el huésped tiene 12 horas para pagar a Bastet el 10 por ciento del total de la reserva. Si no paga, la solicitud se cancela sin costo para nadie.
4.3. Cuando Bastet verifica ese pago, la reserva queda confirmada y se entregan los datos de contacto y la ubicación al huésped.

5. PAGOS
5.1. El huésped paga a Bastet el 10 por ciento del total como tarifa de reserva. Ese monto es de Bastet.
5.2. El 90 por ciento restante lo paga el huésped directamente a mí, en la forma que acordemos. Bastet no recibe ni custodia ese dinero, y no se responsabiliza por su pago, cobro o devolución.
5.3. Debo informar en la plataforma si recibí o no el 90 por ciento y, si me lo piden, adjuntar comprobante.

6. SI EL HUÉSPED CANCELA
6.1. El huésped puede cancelar sin costo hasta 4 horas después de que Bastet verifique su pago.
6.2. Pasado ese plazo, se retiene el 20 por ciento del total de la reserva: 10 por ciento para Bastet y 10 por ciento para mí. Si ya cobré el 90 por ciento, debo devolver al huésped lo que exceda mi parte.

7. SI YO CANCELO UNA RESERVA CONFIRMADA
7.1. Bastet devuelve al huésped el 100 por ciento del 10 por ciento que recibió.
7.2. Si ya cobré el 90 por ciento, debo devolverlo íntegro y directamente al huésped, por mis propios medios.
7.3. Bastet puede ayudar a buscar otro alojamiento, pero no garantiza fondos que no recibió.
7.4. Cancelar sin causa justificada es una falta que Bastet puede registrar y que puede afectar mi cuenta.

8. RECLAMOS
Si el huésped o yo presentamos un reclamo, Bastet puede pedir comprobantes, escuchar a ambos, registrar la evidencia y la decisión, devolver el importe que recibió cuando corresponda, y suspender mi cuenta si se verifica una falta. La resolución económica del 90 por ciento pagado directamente es entre el huésped y yo.

9. CONDUCTA
No cobraré cargos ocultos ni condicionaré la entrega del alojamiento a pagos distintos de lo publicado. No discriminaré. No usaré los datos del huésped para otro fin que atender la reserva. No usaré fotografías o datos falsos.

10. RESEÑAS Y VERIFICACIÓN
Acepto que los huéspedes con reserva concretada puedan dejar reseñas públicas sobre su estadía. Bastet puede mostrar mi distintivo de verificación de agente o propietario si lo obtengo, que es independiente de este acuerdo.

11. SUSPENSIÓN
Bastet puede suspender o retirar mi oferta o mi cuenta por incumplir este acuerdo, por fraude o por orden de autoridad, dándome la oportunidad de explicarme cuando corresponda.

12. DATOS PERSONALES
Bastet usa mis datos para operar Estadías, atender reclamos y verificar identidad. Mis datos de contacto se entregan al huésped solo cuando su reserva queda confirmada.

13. CAMBIOS Y LEY APLICABLE
Bastet puede actualizar este acuerdo y yo deberé aceptar la versión vigente para seguir publicando. Se rige por las leyes de Bolivia y los tribunales competentes del domicilio de Bastet.

14. ACEPTACIÓN ELECTRÓNICA
Al marcar la casilla de aceptación acepto este acuerdo, y el registro de fecha, hora y versión sirve como prueba.'''

C = '''DECLARACIÓN JURADA DIGITAL DE DESISTIMIENTO (versión provisional 1)

Yo, el titular de la cuenta que realiza esta declaración, quien publica el inmueble en la plataforma Bastet (bastet.uno), declaro bajo juramento, de forma libre y voluntaria, lo siguiente:

1. Que soy propietario del inmueble identificado en esta solicitud, o que cuento con autorización suficiente para ofrecerlo y para decidir sobre su retiro.

2. Que deseo retirar el inmueble de la plataforma porque he desistido de la operación que ofrecía (venta, alquiler o anticrético).

3. Que NO he vendido, alquilado, dado en anticrético ni transferido de ninguna forma el inmueble, ni he pactado, prometido o acordado hacerlo, con ninguna de las personas que se contactaron conmigo a través de Bastet, ni con familiares, allegados, representantes o terceros vinculados a ellas.

4. Que tampoco he concretado ni pactado esa operación con cualquier otra persona a partir de un contacto, visita, información o conversación que se originó por una conexión de Bastet, incluidas las que se hayan mantenido por WhatsApp, llamada u otro medio fuera de la plataforma.

5. Que no retiro el inmueble para evitar el pago de tarifas o comisiones a Bastet, ni para concretar la operación por fuera de la plataforma.

6. Que, si en el futuro vuelvo a ofrecer este inmueble o lo cedo a una persona conectada por Bastet mientras esta declaración esté vigente o dentro del plazo en que se origine esa conexión, informaré a Bastet y pagaré la comisión que corresponda según el contrato marco vigente.

7. Que he leído el contrato marco de Bastet y sé que ocultar una operación originada por una conexión de Bastet es una falta grave, que puede dar lugar a una investigación, a la suspensión de mi cuenta, a la aplicación de la cláusula penal prevista en ese contrato y a otras acciones legales.

8. Que la información de esta declaración es verdadera. Reconozco que declarar algo falso puede tener consecuencias legales y contractuales, y autorizo a Bastet a conservar esta declaración con la fecha, la hora, la identidad de mi cuenta y el motivo que indico, como constancia.

Al marcar la casilla de aceptación y enviar esta declaración, confirmo con firma electrónica todo lo anterior.'''

for letter, title, hint, txt in [
    ('A', '7. Anexo A: Contrato marco de conexiones (borrador)', 'Dónde se pega: panel, Conexiones, campo «Contrato marco». Lo aceptan los titulares de ventas, alquileres y anticréticos antes de publicar.', A),
    ('B', '8. Anexo B: Acuerdo de anfitrión de estadías (borrador)', 'Dónde se pega: panel, Reservas, tarjeta «Acuerdo de anfitrión». Lo aceptan quienes publican estadías temporales.', B),
    ('C', '9. Anexo C: Declaración jurada de desistimiento (borrador)', 'Dónde se pega: panel, Operaciones. La firma el titular que retira un inmueble con conexiones sin haber concretado la operación.', C)]:
    S += [P(title, h1), P(hint, note)] + legal_text(txt) + [PageBreak()]
S.pop()  # última PageBreak

doc.build(S)
print('ok', OUT)
