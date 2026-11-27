/**
 * =====================================================================
 * EVENTOS X · PLANILLA DE SEGUIMIENTO (Google Sheets + Apps Script)
 * Dónde: la planilla → Extensiones → Apps Script → pegar TODO en Código.gs → Guardar
 * Primera vez: menú "Eventos X" → "1. Configurar PIN de admin" y después "2. Activar actualización automática".
 * Trae las entradas de Supabase cada 10 minutos y arma:
 *   - "Dashboard": indicadores, insights de venta (mejor horario, mejor día, ritmo y proyección) y gráficos.
 *   - "Entradas": el detalle de cada persona.
 * El PIN se guarda en las propiedades privadas del script (no queda escrito en la planilla).
 * =====================================================================
 */
const SUPABASE_URL = 'https://vogizootbnhvbeugroyr.supabase.co';
// Clave pública (anon): es la misma que usan las páginas web, no da acceso por sí sola.
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZvZ2l6b290Ym5odmJldWdyb3lyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ2MzY3MTAsImV4cCI6MjA5MDIxMjcxMH0.7dNueBWtcx0nUHjligZl4hS72qqlswuYw0WYR0QeVhI';

const TZ = 'America/Argentina/Buenos_Aires';
const AFORO = 1500;
const FECHA_EVENTO = new Date('2026-12-18T00:00:00-03:00');

const C = {
  tinta: '#0f172a', texto: '#334155', suave: '#64748b', linea: '#e2e8f0', fondo: '#f8fafc',
  azul: '#2563eb', azulClaro: '#dbeafe', rosa: '#db2777', verde: '#059669', ambar: '#d97706', blanco: '#ffffff',
};
const FUENTE = 'Inter';
const DIAS = ['Domingo', 'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado'];
const ENCABEZADOS = ['Fecha de compra', 'Nombre', 'Apellido', 'DNI', 'Email', 'Tipo de entrada', 'Sexo',
                     'Precio ($)', 'Pago', 'Ingresó', 'Hora de ingreso', 'Instagram', 'En Match X'];

function onOpen() {
  SpreadsheetApp.getUi().createMenu('Eventos X')
    .addItem('Actualizar ahora', 'actualizar')
    .addSeparator()
    .addItem('1. Configurar PIN de admin', 'configurarPin')
    .addItem('2. Activar actualización automática (cada 10 min)', 'activarAutomatico')
    .addItem('Desactivar actualización automática', 'desactivarAutomatico')
    .addToUi();
}

function configurarPin() {
  const ui = SpreadsheetApp.getUi();
  const r = ui.prompt('PIN de admin', 'Ingresá el PIN de admin de Eventos X (el mismo del panel Admin).', ui.ButtonSet.OK_CANCEL);
  if (r.getSelectedButton() !== ui.Button.OK) return;
  PropertiesService.getScriptProperties().setProperty('PIN_ADMIN', r.getResponseText().trim());
  try { actualizar(); ui.alert('La planilla quedó conectada.'); }
  catch (e) { ui.alert('No se pudo conectar: ' + e.message); }
}

function activarAutomatico() {
  desactivarAutomatico();
  ScriptApp.newTrigger('actualizar').timeBased().everyMinutes(10).create();
  SpreadsheetApp.getUi().alert('La planilla se va a actualizar automáticamente cada 10 minutos.');
}

function desactivarAutomatico() {
  ScriptApp.getProjectTriggers().filter(t => t.getHandlerFunction() === 'actualizar').forEach(t => ScriptApp.deleteTrigger(t));
}

function traerDatos_() {
  const pin = PropertiesService.getScriptProperties().getProperty('PIN_ADMIN');
  if (!pin) throw new Error('Falta configurar el PIN (menú Eventos X → 1).');
  const resp = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/datos_planilla', {
    method: 'post', contentType: 'application/json',
    headers: { apikey: SUPABASE_ANON, Authorization: 'Bearer ' + SUPABASE_ANON },
    payload: JSON.stringify({ pin_seguridad: pin }), muteHttpExceptions: true,
  });
  const cuerpo = JSON.parse(resp.getContentText() || '[]');
  if (resp.getResponseCode() !== 200) throw new Error(cuerpo.message || ('Error ' + resp.getResponseCode()));
  return cuerpo;
}

const aFecha_ = iso => iso ? new Date(iso) : '';
const fmt_ = (d, p) => Utilities.formatDate(d, TZ, p);
const miles_ = n => String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, '.');
const pesos_ = n => '$' + miles_(n);
const pct_ = (a, b) => b ? Math.round(a * 100 / b) + '%' : '—';

function hoja_(nombre, indice) {
  const ss = SpreadsheetApp.getActive();
  return ss.getSheetByName(nombre) || ss.insertSheet(nombre, indice);
}

function actualizar() {
  const datos = traerDatos_();
  SpreadsheetApp.getActive().setSpreadsheetLocale('es_AR');
  const viejo = SpreadsheetApp.getActive().getSheetByName('Resumen');
  if (viejo) SpreadsheetApp.getActive().deleteSheet(viejo);
  escribirDashboard_(datos);
  escribirEntradas_(datos);
}

// ---------- Hoja "Entradas" ----------
function escribirEntradas_(datos) {
  const h = hoja_('Entradas', 1);
  h.getBandings().forEach(b => b.remove());
  if (h.getFilter()) h.getFilter().remove();
  h.clear();
  const filas = datos.map(d => [aFecha_(d.fecha_compra), d.nombre, d.apellido, d.dni, d.email, d.tipo_entrada, d.sexo,
                                d.precio, d.estado_pago, d.ingreso, aFecha_(d.hora_ingreso), d.instagram ? '@' + d.instagram : '', d.en_match]);
  const n = ENCABEZADOS.length;
  h.getRange(1, 1, 1, n).setValues([ENCABEZADOS]).setBackground(C.tinta).setFontColor(C.blanco)
    .setFontWeight('bold').setFontFamily(FUENTE).setVerticalAlignment('middle');
  h.setRowHeight(1, 34);
  if (filas.length) {
    const r = h.getRange(2, 1, filas.length, n);
    r.setValues(filas).setFontFamily(FUENTE).setFontColor(C.texto).setVerticalAlignment('middle');
    h.getRange(2, 1, filas.length, 1).setNumberFormat('dd/MM/yyyy HH:mm');
    h.getRange(2, 11, filas.length, 1).setNumberFormat('dd/MM/yyyy HH:mm');
    h.getRange(2, 8, filas.length, 1).setNumberFormat('$#,##0');
    h.getRange(2, 4, filas.length, 1).setNumberFormat('@');
    h.getRange(1, 1, filas.length + 1, n).applyRowBanding(SpreadsheetApp.BandingTheme.LIGHT_GREY, true, false);
    const reglas = [
      SpreadsheetApp.newConditionalFormatRule().whenTextEqualTo('Aprobada').setFontColor(C.verde).setBold(true).setRanges([h.getRange(2, 9, filas.length, 1)]).build(),
      SpreadsheetApp.newConditionalFormatRule().whenTextEqualTo('Pendiente').setFontColor(C.ambar).setBold(true).setRanges([h.getRange(2, 9, filas.length, 1)]).build(),
    ];
    h.setConditionalFormatRules(reglas);
  }
  h.setFrozenRows(1);
  h.autoResizeColumns(1, n);
  for (let c = 1; c <= n; c++) h.setColumnWidth(c, Math.max(h.getColumnWidth(c) + 16, 90));
  h.getRange(1, 1, Math.max(filas.length, 1) + 1, n).createFilter();
}

// ---------- Hoja "Dashboard" ----------
function escribirDashboard_(datos) {
  const h = hoja_('Dashboard', 0);
  h.getCharts().forEach(c => h.removeChart(c));
  h.getRange(1, 1, h.getMaxRows(), h.getMaxColumns()).breakApart();
  h.clear(); h.clearConditionalFormatRules();
  h.setHiddenGridlines(true);
  h.getRange(1, 1, h.getMaxRows(), h.getMaxColumns()).setFontFamily(FUENTE).setFontColor(C.texto).setBackground(C.blanco);
  h.setColumnWidth(1, 24);
  for (let c = 2; c <= 13; c++) h.setColumnWidth(c, 104);

  const ahora = new Date();
  const aprob = datos.filter(d => d.estado_pago === 'Aprobada');
  const pend = datos.filter(d => d.estado_pago !== 'Aprobada');
  const recaudado = aprob.reduce((s, d) => s + (d.precio || 0), 0);
  const aCobrar = pend.reduce((s, d) => s + (d.precio || 0), 0);
  const mujeres = aprob.filter(d => d.sexo === 'Mujer').length;
  const hombres = aprob.filter(d => d.sexo === 'Hombre').length;
  const diasFaltan = Math.max(0, Math.ceil((FECHA_EVENTO - ahora) / 86400000));

  // Encabezado
  h.getRange('B2:M3').merge().setBackground(C.tinta);
  h.getRange('B2').setValue('EVENTOS X  ·  Seguimiento de ventas').setFontSize(20).setFontWeight('bold')
    .setFontColor(C.blanco).setVerticalAlignment('middle').setHorizontalAlignment('left');
  h.setRowHeights(2, 2, 26);
  h.getRange('B4:M4').merge().setValue(`Actualizado ${fmt_(ahora, 'dd/MM/yyyy HH:mm')} hs  ·  Faltan ${diasFaltan} días para el evento  ·  Aforo ${miles_(AFORO)}`)
    .setFontColor(C.suave).setFontSize(10).setBackground(C.fondo);
  h.setRowHeight(4, 26);

  // Tarjetas
  const tarjetas = [
    ['ENTRADAS VENDIDAS', aprob.length, `${pct_(aprob.length, AFORO)} del aforo`, '0'],
    ['RECAUDADO', recaudado, aprob.length ? `Ticket promedio ${pesos_(recaudado / aprob.length)}` : 'Sin ventas aún', '$#,##0'],
    ['PENDIENTES DE PAGO', pend.length, `${pesos_(aCobrar)} por cobrar`, '0'],
    ['CONVERSIÓN', pct_(aprob.length, datos.length), 'Reservas que pagaron'],
    ['MUJERES / HOMBRES', `${mujeres} / ${hombres}`, aprob.length ? `${pct_(mujeres, aprob.length)} mujeres` : '—'],
    ['INGRESARON', aprob.filter(d => d.ingreso === 'Sí').length, `${datos.filter(d => d.en_match === 'Sí').length} en Match X`],
  ];
  tarjetas.forEach((t, i) => {
    const col = 2 + i * 2;
    const caja = h.getRange(6, col, 3, 2);
    caja.setBackground(C.fondo).setBorder(true, true, true, true, false, false, C.linea, SpreadsheetApp.BorderStyle.SOLID);
    h.getRange(6, col, 1, 2).merge().setValue(t[0]).setFontSize(8).setFontWeight('bold').setFontColor(C.suave);
    h.getRange(7, col, 1, 2).merge().setValue(t[1]).setNumberFormat(t[3] || '@').setFontSize(20).setFontWeight('bold').setFontColor(C.tinta).setHorizontalAlignment('left');
    h.getRange(8, col, 1, 2).merge().setValue(t[2]).setFontSize(9).setFontColor(C.suave);
  });
  h.setRowHeight(6, 22); h.setRowHeight(7, 34); h.setRowHeight(8, 20);

  // Análisis de horarios y días (sobre todas las reservas: muestran cuándo la gente decide comprar)
  const porHora = Array.from({ length: 24 }, () => [0, 0]);
  const porDiaSem = Array.from({ length: 7 }, () => [0, 0]);
  const porFecha = {};
  datos.forEach(d => {
    const f = new Date(d.fecha_compra);
    const hr = Number(fmt_(f, 'H')), ds = Number(fmt_(f, 'u')) % 7, k = fmt_(f, 'yyyy-MM-dd');
    const ok = d.estado_pago === 'Aprobada' ? 1 : 0;
    porHora[hr][0]++; porHora[hr][1] += ok;
    porDiaSem[ds][0]++; porDiaSem[ds][1] += ok;
    porFecha[k] = porFecha[k] || [0, 0, 0]; porFecha[k][0]++; porFecha[k][1] += ok; porFecha[k][2] += ok ? (d.precio || 0) : 0;
  });

  // Mejor franja de 3 horas
  let mejorFranja = -1, maxFranja = 0;
  for (let i = 0; i < 24; i++) {
    const s = porHora[i][0] + porHora[(i + 1) % 24][0] + porHora[(i + 2) % 24][0];
    if (s > maxFranja) { maxFranja = s; mejorFranja = i; }
  }
  const mejorDiaSem = porDiaSem.reduce((m, v, i) => v[0] > porDiaSem[m][0] ? i : m, 0);
  const fechas = Object.keys(porFecha).sort();
  const mejorFecha = fechas.reduce((m, k) => !m || porFecha[k][0] > porFecha[m][0] ? k : m, '');
  const hace7 = fmt_(new Date(ahora - 7 * 86400000), 'yyyy-MM-dd');
  const hace14 = fmt_(new Date(ahora - 14 * 86400000), 'yyyy-MM-dd');
  const ult7 = fechas.filter(k => k > hace7).reduce((s, k) => s + porFecha[k][1], 0);
  const prev7 = fechas.filter(k => k > hace14 && k <= hace7).reduce((s, k) => s + porFecha[k][1], 0);
  const ritmo = ult7 / 7;
  const proyeccion = Math.min(AFORO, Math.round(aprob.length + ritmo * diasFaltan));
  const hh = n => ('0' + (n % 24)).slice(-2) + ':00';

  const insights = datos.length ? [
    ['Mejor horario', mejorFranja >= 0 ? `Entre las ${hh(mejorFranja)} y las ${hh(mejorFranja + 3)} hs se concentra el ${pct_(maxFranja, datos.length)} de las reservas. Programá publicaciones e historias 30 minutos antes.` : '—'],
    ['Mejor día', `Los ${DIAS[mejorDiaSem].toLowerCase()} son el día de más reservas (${porDiaSem[mejorDiaSem][0]}). Conviene lanzar cambios de preventa o promociones ese día.`],
    ['Pico de ventas', mejorFecha ? `El ${fmt_(new Date(mejorFecha + 'T12:00:00'), 'dd/MM')} fue el día récord con ${porFecha[mejorFecha][0]} reservas. Revisá qué se publicó ese día y repetilo.` : '—'],
    ['Ritmo actual', `${ult7} entradas pagas en los últimos 7 días (${ritmo.toFixed(1)} por día)` + (prev7 ? `, ${ult7 >= prev7 ? 'más' : 'menos'} que la semana anterior (${prev7}).` : '.')],
    ['Proyección', `A este ritmo llegarías a unas ${miles_(proyeccion)} entradas (${pct_(proyeccion, AFORO)} del aforo) para el ${fmt_(FECHA_EVENTO, 'dd/MM')}.`],
    ['Pagos pendientes', pend.length ? `${pend.length} reservas sin pagar (${pesos_(aCobrar)}). Un recordatorio puede convertir parte de ese monto.` : 'No hay pagos pendientes.'],
  ] : [['Sin datos', 'Todavía no hay reservas. Los insights aparecen con las primeras ventas.']];

  let fila = 10;
  h.getRange(fila, 2, 1, 12).merge().setValue('INSIGHTS DE VENTA').setFontSize(11).setFontWeight('bold').setFontColor(C.tinta);
  h.getRange(fila, 2, 1, 12).setBorder(null, null, true, null, null, null, C.azul, SpreadsheetApp.BorderStyle.SOLID_MEDIUM);
  fila++;
  insights.forEach(([t, txt]) => {
    h.getRange(fila, 2, 1, 2).merge().setValue(t).setFontWeight('bold').setFontColor(C.azul).setFontSize(10).setVerticalAlignment('middle');
    h.getRange(fila, 4, 1, 10).merge().setValue(txt).setFontSize(10).setWrap(true).setVerticalAlignment('middle');
    h.getRange(fila, 2, 1, 12).setBorder(null, null, true, null, null, null, C.linea, SpreadsheetApp.BorderStyle.SOLID);
    h.setRowHeight(fila, 30);
    fila++;
  });
  fila += 1;

  // Tablas de datos (alimentan los gráficos)
  const tabla = (col, titulo, encab, filas, formatos) => {
    h.getRange(fila, col, 1, encab.length).merge().setValue(titulo).setFontWeight('bold').setFontColor(C.tinta).setFontSize(11);
    h.getRange(fila + 1, col, 1, encab.length).setValues([encab]).setBackground(C.tinta).setFontColor(C.blanco).setFontWeight('bold').setFontSize(9);
    if (filas.length) {
      const r = h.getRange(fila + 2, col, filas.length, encab.length);
      r.setValues(filas).setFontSize(9).setBorder(null, null, true, null, null, true, C.linea, SpreadsheetApp.BorderStyle.SOLID);
      (formatos || []).forEach(([c, f]) => h.getRange(fila + 2, col + c, filas.length, 1).setNumberFormat(f));
    }
    return { fila: fila + 1, col, n: filas.length, w: encab.length };
  };

  const inicio = fila;
  const tHora = tabla(2, 'Reservas por hora', ['Hora', 'Reservas', 'Pagas'], porHora.map((v, i) => [hh(i), v[0], v[1]]));
  const tDia = tabla(6, 'Reservas por día de la semana', ['Día', 'Reservas', 'Pagas'], [1, 2, 3, 4, 5, 6, 0].map(i => [DIAS[i], porDiaSem[i][0], porDiaSem[i][1]]));
  const tipos = [...new Set(datos.map(d => d.tipo_entrada))];
  fila = inicio + 11;
  const tTipo = tabla(6, 'Por tipo de entrada', ['Tipo', 'Pagas', 'Recaudado'], tipos.map(tp => {
    const a = aprob.filter(d => d.tipo_entrada === tp);
    return [String(tp).split(' - ')[0], a.length, a.reduce((s, d) => s + (d.precio || 0), 0)];
  }), [[2, '$#,##0']]);
  fila = inicio + 27;
  let acum = 0;
  const tFecha = tabla(2, 'Evolución diaria', ['Día', 'Reservas', 'Pagas', 'Acumulado pagas'],
    fechas.map(k => { acum += porFecha[k][1]; return [new Date(k + 'T12:00:00'), porFecha[k][0], porFecha[k][1], acum]; }), [[0, 'dd/MM']]);
  h.getRange(tHora.fila + 1, 3, 24, 2).setFontColor(C.texto);
  if (porHora.some(v => v[0])) {
    h.setConditionalFormatRules([SpreadsheetApp.newConditionalFormatRule()
      .setGradientMinpoint(C.blanco).setGradientMaxpoint('#93c5fd').setRanges([h.getRange(tHora.fila + 1, 3, 24, 1)]).build()]);
  }

  // Gráficos
  const base = (b, titulo) => b.setOption('title', titulo)
    .setOption('legend', { position: 'bottom' })
    .setOption('backgroundColor', C.blanco);

  h.insertChart(base(h.newChart().asColumnChart(), 'Cuándo se compra: reservas por hora del día')
    .addRange(h.getRange(tHora.fila, 2, 25, 3)).setOption('colors', ['#cbd5e1', C.azul])
    .setPosition(inicio, 10, 0, 0).setOption('width', 620).setOption('height', 300).build());
  h.insertChart(base(h.newChart().asColumnChart(), 'Reservas por día de la semana')
    .addRange(h.getRange(tDia.fila, 6, 8, 3)).setOption('colors', ['#cbd5e1', C.azul])
    .setPosition(inicio + 16, 10, 0, 0).setOption('width', 620).setOption('height', 280).build());
  if (fechas.length) h.insertChart(base(h.newChart().asComboChart(), 'Evolución de ventas')
    .addRange(h.getRange(tFecha.fila, 2, fechas.length + 1, 1)).addRange(h.getRange(tFecha.fila, 4, fechas.length + 1, 2))
    .setOption('series', { 0: { type: 'bars', color: '#93c5fd' }, 1: { type: 'line', color: C.verde, lineWidth: 3, targetAxisIndex: 1 } })
    .setPosition(inicio + 31, 10, 0, 0).setOption('width', 620).setOption('height', 300).build());
  if (mujeres + hombres) {
    const r = tFecha.fila + Math.max(fechas.length, 1) + 3;
    h.getRange(r, 2, 3, 2).setValues([['Sexo', 'Pagas'], ['Mujeres', mujeres], ['Hombres', hombres]]).setFontColor(C.blanco).setFontSize(1);
    h.insertChart(base(h.newChart().asPieChart(), 'Mujeres y hombres (pagas)')
      .addRange(h.getRange(r, 2, 3, 2)).setOption('pieHole', 0.55).setOption('colors', [C.rosa, C.azul])
      .setPosition(inicio + 48, 10, 0, 0).setOption('width', 420).setOption('height', 260).build());
  }
  h.setFrozenRows(4);
}
