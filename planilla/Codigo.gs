/**
 * =====================================================================
 * EVENTOS X · PLANILLA DE SEGUIMIENTO (Google Sheets + Apps Script)
 * Dónde: la planilla → Extensiones → Apps Script → pegar TODO en Código.gs → Guardar
 * Primera vez: menú "Eventos X" → "1. Configurar PIN de admin" y después "2. Activar actualización automática".
 * Trae las entradas de Supabase cada 10 minutos y arma:
 *   - Hoja "Resumen": totales, por sexo, por tipo, recaudación, ingresos y ventas por día.
 *   - Hoja "Entradas": el detalle de cada persona.
 * El PIN se guarda en las propiedades privadas del script (no queda escrito en la planilla).
 * =====================================================================
 */
const SUPABASE_URL = 'https://vogizootbnhvbeugroyr.supabase.co';
// Clave pública (anon): es la misma que usan las páginas web, no da acceso por sí sola.
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZvZ2l6b290Ym5odmJldWdyb3lyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ2MzY3MTAsImV4cCI6MjA5MDIxMjcxMH0.7dNueBWtcx0nUHjligZl4hS72qqlswuYw0WYR0QeVhI';

const COLOR = { fondo: '#0f172a', azul: '#3b82f6', rosa: '#ec4899', verde: '#10b981', gris: '#f1f5f9', borde: '#e2e8f0' };
const ENCABEZADOS = ['Fecha de compra', 'Nombre', 'Apellido', 'DNI', 'Email', 'Tipo de entrada', 'Sexo',
                     'Precio ($)', 'Pago', 'Ingresó', 'Hora de ingreso', 'Instagram', 'En Match X'];

function onOpen() {
  SpreadsheetApp.getUi().createMenu('Eventos X')
    .addItem('🔄 Actualizar ahora', 'actualizar')
    .addSeparator()
    .addItem('1. Configurar PIN de admin', 'configurarPin')
    .addItem('2. Activar actualización automática (cada 10 min)', 'activarAutomatico')
    .addItem('Desactivar actualización automática', 'desactivarAutomatico')
    .addToUi();
}

function configurarPin() {
  const ui = SpreadsheetApp.getUi();
  const r = ui.prompt('PIN de admin', 'Escribí el PIN de admin de Eventos X (el mismo del panel Admin).', ui.ButtonSet.OK_CANCEL);
  if (r.getSelectedButton() !== ui.Button.OK) return;
  PropertiesService.getScriptProperties().setProperty('PIN_ADMIN', r.getResponseText().trim());
  try { actualizar(); ui.alert('✅ Listo: la planilla quedó conectada.'); }
  catch (e) { ui.alert('❌ ' + e.message); }
}

function activarAutomatico() {
  desactivarAutomatico();
  ScriptApp.newTrigger('actualizar').timeBased().everyMinutes(10).create();
  SpreadsheetApp.getUi().alert('✅ La planilla se va a actualizar sola cada 10 minutos.');
}

function desactivarAutomatico() {
  ScriptApp.getProjectTriggers().filter(t => t.getHandlerFunction() === 'actualizar').forEach(t => ScriptApp.deleteTrigger(t));
}

function traerDatos_() {
  const pin = PropertiesService.getScriptProperties().getProperty('PIN_ADMIN');
  if (!pin) throw new Error('Falta configurar el PIN (menú Eventos X → 1).');
  const resp = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/datos_planilla', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: SUPABASE_ANON, Authorization: 'Bearer ' + SUPABASE_ANON },
    payload: JSON.stringify({ pin_seguridad: pin }),
    muteHttpExceptions: true,
  });
  const cuerpo = JSON.parse(resp.getContentText() || '[]');
  if (resp.getResponseCode() !== 200) throw new Error(cuerpo.message || ('Error ' + resp.getResponseCode()));
  return cuerpo;
}

function aFecha_(iso) { return iso ? new Date(iso) : ''; }

function hoja_(nombre, indice) {
  const ss = SpreadsheetApp.getActive();
  return ss.getSheetByName(nombre) || ss.insertSheet(nombre, indice);
}

function actualizar() {
  const datos = traerDatos_();
  escribirEntradas_(datos);
  escribirResumen_(datos);
}

// ---------- Hoja "Entradas" ----------
function escribirEntradas_(datos) {
  const h = hoja_('Entradas', 1);
  h.getBandings().forEach(b => b.remove());
  h.clear();
  const filas = datos.map(d => [aFecha_(d.fecha_compra), d.nombre, d.apellido, d.dni, d.email, d.tipo_entrada, d.sexo,
                                d.precio, d.estado_pago, d.ingreso, aFecha_(d.hora_ingreso), d.instagram ? '@' + d.instagram : '', d.en_match]);
  h.getRange(1, 1, 1, ENCABEZADOS.length).setValues([ENCABEZADOS])
    .setBackground(COLOR.fondo).setFontColor('#ffffff').setFontWeight('bold');
  if (filas.length) {
    h.getRange(2, 1, filas.length, ENCABEZADOS.length).setValues(filas);
    h.getRange(2, 1, filas.length, 1).setNumberFormat('dd/MM/yyyy HH:mm');
    h.getRange(2, 11, filas.length, 1).setNumberFormat('dd/MM/yyyy HH:mm');
    h.getRange(2, 8, filas.length, 1).setNumberFormat('$#,##0');
    h.getRange(2, 4, filas.length, 1).setNumberFormat('@');
    h.getRange(1, 1, filas.length + 1, ENCABEZADOS.length).applyRowBanding(SpreadsheetApp.BandingTheme.LIGHT_GREY, true, false);
  }
  h.setFrozenRows(1);
  h.autoResizeColumns(1, ENCABEZADOS.length);
  if (h.getFilter()) h.getFilter().remove();
  h.getRange(1, 1, Math.max(filas.length, 1) + 1, ENCABEZADOS.length).createFilter();
}

// ---------- Hoja "Resumen" ----------
function escribirResumen_(datos) {
  const h = hoja_('Resumen', 0);
  h.getRange(1, 1, h.getMaxRows(), h.getMaxColumns()).breakApart();
  h.clear(); h.getCharts().forEach(c => h.removeChart(c));
  h.setHiddenGridlines(true);

  const aprob = datos.filter(d => d.estado_pago === 'Aprobada');
  const pend = datos.filter(d => d.estado_pago !== 'Aprobada');
  const ingresados = aprob.filter(d => d.ingreso === 'Sí');
  const recaudado = aprob.reduce((s, d) => s + (d.precio || 0), 0);
  const aCobrar = pend.reduce((s, d) => s + (d.precio || 0), 0);
  const enMatch = datos.filter(d => d.en_match === 'Sí').length;

  h.getRange('A1').setValue('EVENTOS X · Seguimiento de entradas').setFontSize(18).setFontWeight('bold');
  h.getRange('A2').setValue('Actualizado: ' + Utilities.formatDate(new Date(), 'America/Argentina/Buenos_Aires', 'dd/MM/yyyy HH:mm') + ' hs')
    .setFontColor('#64748b');

  // Tarjetas de totales
  const tarjetas = [
    ['Reservas totales', datos.length], ['Pagas (aprobadas)', aprob.length], ['Pendientes de pago', pend.length],
    ['Ingresaron', ingresados.length], ['Recaudado', recaudado], ['Por cobrar', aCobrar], ['Perfiles en Match X', enMatch],
  ];
  tarjetas.forEach((t, i) => {
    const col = 1 + (i % 4) * 2, fila = 4 + Math.floor(i / 4) * 3;
    h.getRange(fila, col, 1, 2).merge().setValue(t[0]).setFontColor('#64748b').setFontSize(10);
    const v = h.getRange(fila + 1, col, 1, 2).merge().setValue(t[1]).setFontSize(22).setFontWeight('bold');
    if (t[0] === 'Recaudado' || t[0] === 'Por cobrar') v.setNumberFormat('$#,##0');
    h.getRange(fila, col, 2, 2).setBackground(COLOR.gris).setBorder(true, true, true, true, false, false, COLOR.borde, null);
  });

  // Tablas: por sexo, por tipo, ventas por día
  const contar = (lista, clave) => lista.reduce((m, d) => (m[d[clave]] = (m[d[clave]] || 0) + 1, m), {});
  let fila = 11;
  const tabla = (titulo, encab, filas) => {
    h.getRange(fila, 1).setValue(titulo).setFontWeight('bold').setFontSize(12);
    h.getRange(fila + 1, 1, 1, encab.length).setValues([encab]).setBackground(COLOR.fondo).setFontColor('#fff').setFontWeight('bold');
    if (filas.length) h.getRange(fila + 2, 1, filas.length, encab.length).setValues(filas);
    const inicio = fila + 1;
    fila += filas.length + 4;
    return { inicio, filas: filas.length, cols: encab.length };
  };

  const sexos = ['Mujer', 'Hombre', 'Sin dato'];
  const porSexo = sexos.map(s => {
    const t = datos.filter(d => d.sexo === s);
    return [s, t.length, t.filter(d => d.estado_pago === 'Aprobada').length, t.filter(d => d.ingreso === 'Sí').length];
  }).filter(r => r[1] > 0);
  const tSexo = tabla('Por sexo', ['Sexo', 'Reservas', 'Pagas', 'Ingresaron'], porSexo);

  const tipos = Object.keys(contar(datos, 'tipo_entrada'));
  const porTipo = tipos.map(tp => {
    const t = datos.filter(d => d.tipo_entrada === tp), a = t.filter(d => d.estado_pago === 'Aprobada');
    return [tp, t.length, a.length, a.reduce((s, d) => s + (d.precio || 0), 0)];
  });
  const tTipo = tabla('Por tipo de entrada', ['Tipo', 'Reservas', 'Pagas', 'Recaudado ($)'], porTipo);
  if (porTipo.length) h.getRange(tTipo.inicio + 1, 4, porTipo.length, 1).setNumberFormat('$#,##0');

  const dias = {};
  datos.forEach(d => {
    const k = Utilities.formatDate(new Date(d.fecha_compra), 'America/Argentina/Buenos_Aires', 'yyyy-MM-dd');
    dias[k] = dias[k] || [0, 0]; dias[k][0]++; if (d.estado_pago === 'Aprobada') dias[k][1]++;
  });
  const porDia = Object.keys(dias).sort().map(k => [new Date(k + 'T12:00:00'), dias[k][0], dias[k][1]]);
  const tDia = tabla('Reservas por día', ['Día', 'Reservas', 'Pagas'], porDia);
  if (porDia.length) h.getRange(tDia.inicio + 1, 1, porDia.length, 1).setNumberFormat('dd/MM/yyyy');

  // Gráficos
  if (porSexo.length) h.insertChart(h.newChart().asPieChart()
    .addRange(h.getRange(tSexo.inicio, 1, tSexo.filas + 1, 2))
    .setPosition(11, 7, 0, 0).setOption('title', 'Reservas por sexo').setOption('pieHole', 0.5)
    .setOption('colors', [COLOR.rosa, COLOR.azul, '#94a3b8']).setOption('width', 420).setOption('height', 260).build());
  if (porDia.length) h.insertChart(h.newChart().asColumnChart()
    .addRange(h.getRange(tDia.inicio, 1, tDia.filas + 1, 3))
    .setPosition(25, 7, 0, 0).setOption('title', 'Reservas por día').setOption('colors', ['#94a3b8', COLOR.verde])
    .setOption('legend', { position: 'bottom' }).setOption('width', 520).setOption('height', 280).build());

  h.setColumnWidths(1, 8, 120);
}
