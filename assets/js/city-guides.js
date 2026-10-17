/* Sugerencias para visitar y explorar en cada ciudad de Bolivia (ficha de Estadías). Son lugares conocidos y generales, escritos a mano:
   no dependen de ningún servicio externo. Para agregar o corregir un lugar, edita esta lista (n = nombre, d = descripción breve,
   t = tipo). Los lugares CERCANOS al alojamiento salen aparte, en vivo, de OpenStreetMap (ver estadias-extras.js). */
window.CITY_GUIDES = {
  'La Paz': [
    { n: 'Mi Teleférico', d: 'Recorre la ciudad en cabina con vistas del Illimani y del altiplano.', t: 'Paseo' },
    { n: 'Plaza Murillo', d: 'Centro histórico y político: Catedral, Palacio de Gobierno y Congreso.', t: 'Historia' },
    { n: 'Calle Jaén', d: 'Calle colonial con museos, galerías y cafés.', t: 'Cultura' },
    { n: 'Mercado de las Brujas', d: 'Artesanías, amuletos y hierbas andinas junto a la calle Linares.', t: 'Compras' },
    { n: 'Mirador Killi Killi', d: 'Una de las mejores vistas panorámicas de la ciudad.', t: 'Mirador' },
    { n: 'Valle de la Luna', d: 'Formaciones de arcilla y arenisca a las afueras, ideal para medio día.', t: 'Naturaleza' },
    { n: 'Museo Nacional de Etnografía y Folklore (MUSEF)', d: 'Textiles, máscaras y tradiciones de los pueblos de Bolivia.', t: 'Museo' },
  ],
  'El Alto': [
    { n: 'Feria 16 de Julio', d: 'Uno de los mercados al aire libre más grandes de Sudamérica (jueves y domingos).', t: 'Compras' },
    { n: 'Mi Teleférico Línea Roja', d: 'Conecta El Alto con La Paz con vistas de las dos ciudades.', t: 'Paseo' },
  ],
  'Santa Cruz de la Sierra': [
    { n: 'Plaza 24 de Septiembre', d: 'Corazón de la ciudad, rodeada de cafés y de la Catedral.', t: 'Historia' },
    { n: 'Catedral Metropolitana de Santa Cruz', d: 'Templo del casco viejo con su museo y su mirador del campanario.', t: 'Historia' },
    { n: 'Biocentro Güembé', d: 'Parque con mariposario, aviario y vegetación tropical.', t: 'Naturaleza' },
    { n: 'Jardín Botánico de Santa Cruz', d: 'Áreas verdes y senderos para pasear en familia.', t: 'Naturaleza' },
    { n: 'Lomas de Arena', d: 'Dunas y lagunas a las afueras de la ciudad.', t: 'Naturaleza' },
    { n: 'Museo de Arte Contemporáneo (MUSAC)', d: 'Arte boliviano contemporáneo en pleno centro.', t: 'Museo' },
  ],
  'Cochabamba': [
    { n: 'Cristo de la Concordia', d: 'Gran monumento con vistas de todo el valle (se sube en teleférico o por escaleras).', t: 'Mirador' },
    { n: 'Plaza 14 de Septiembre', d: 'Plaza principal con la Catedral y portales con cafés.', t: 'Historia' },
    { n: 'Palacio Portales', d: 'Mansión de estilo europeo rodeada de jardines.', t: 'Cultura' },
    { n: 'Laguna Alalay', d: 'Espacio para caminar, andar en bicicleta y ver aves.', t: 'Naturaleza' },
    { n: 'La Cancha', d: 'Enorme mercado popular: comida, ropa y productos del valle.', t: 'Compras' },
  ],
  'Sucre': [
    { n: 'Casa de la Libertad', d: 'Museo donde se firmó el acta de independencia de Bolivia.', t: 'Historia' },
    { n: 'Plaza 25 de Mayo', d: 'Plaza principal de la ciudad blanca, rodeada de edificios coloniales.', t: 'Historia' },
    { n: 'Parque Cretácico (Cal Orck\'o)', d: 'Muro con miles de huellas de dinosaurio.', t: 'Naturaleza' },
    { n: 'Mirador de la Recoleta', d: 'Convento y plaza con una de las mejores vistas de Sucre.', t: 'Mirador' },
    { n: 'Mercado Central', d: 'Jugos, comida típica y productos de la región.', t: 'Compras' },
  ],
  'Oruro': [
    { n: 'Santuario del Socavón', d: 'Templo de la Virgen del Socavón, centro del Carnaval de Oruro.', t: 'Historia' },
    { n: 'Museo Antropológico Eduardo López Rivas', d: 'Colección de máscaras y trajes del Carnaval y culturas andinas.', t: 'Museo' },
    { n: 'Faro de Conchupata', d: 'Mirador de la ciudad en el cerro.', t: 'Mirador' },
    { n: 'Plaza 10 de Febrero', d: 'Plaza principal, punto de encuentro de la ciudad.', t: 'Historia' },
  ],
  'Potosí': [
    { n: 'Casa Nacional de Moneda', d: 'Museo de la antigua fábrica de monedas de la época colonial.', t: 'Museo' },
    { n: 'Cerro Rico', d: 'La montaña que dio origen a la ciudad; hay visitas guiadas a las minas.', t: 'Historia' },
    { n: 'Convento de Santa Teresa', d: 'Museo de arte religioso colonial.', t: 'Cultura' },
    { n: 'Plaza 10 de Noviembre', d: 'Plaza principal con la Catedral.', t: 'Historia' },
  ],
  'Tarija': [
    { n: 'Plaza Luis de Fuentes', d: 'Plaza principal de la ciudad, con palmeras y cafés.', t: 'Historia' },
    { n: 'Casa Dorada', d: 'Casona histórica del centro.', t: 'Cultura' },
    { n: 'Mirador San Roque', d: 'Vista de la ciudad con el monumento del Cristo.', t: 'Mirador' },
    { n: 'Valle de la Concepción', d: 'Zona de viñedos y bodegas con degustaciones.', t: 'Vinos' },
    { n: 'Museo Paleontológico y Arqueológico de Tarija', d: 'Fósiles y hallazgos de la región.', t: 'Museo' },
  ],
  'Trinidad': [
    { n: 'Plaza Mariscal José Ballivián', d: 'Plaza principal de la capital beniana.', t: 'Historia' },
    { n: 'Laguna Suárez', d: 'Laguna cercana para paseos y atardeceres.', t: 'Naturaleza' },
  ],
  'Cobija': [
    { n: 'Plaza Germán Busch', d: 'Plaza principal de la capital pandina.', t: 'Historia' },
    { n: 'Puente de la Amistad', d: 'Puente fronterizo sobre el río Acre, junto a Brasil.', t: 'Paseo' },
  ],
};
