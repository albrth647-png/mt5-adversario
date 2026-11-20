// Panel web del EA adversario.
//
// Corre en la misma máquina que MT5 (el runner de GitHub Actions o tu PC).
// No habla con MT5: lee los dos archivos que el EA ya deja en MQL5/Files
//   panel_estado.json  velas, EMAs, ATR y precio por símbolo y temporalidad
//   adv.log            todo lo que el bot hace (señales, filtros, embudo)
// y los publica por HTTP para que el móvil los vea.
//
// Sin dependencias: solo Node >= 18 (http y fs nativos).
//
// Variables de entorno:
//   PANEL_PORT    puerto local (8787)
//   PANEL_TOKEN   clave que debe venir en ?k=... (si está vacía, no se exige)
//   MT5_FILES     carpeta MQL5/Files del terminal
//                 (por defecto C:\Program Files\MetaTrader 5\MQL5\Files)

import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const PUERTO = Number(process.env.PANEL_PORT || 8787);
const CLAVE = process.env.PANEL_TOKEN || '';
const FILES = process.env.MT5_FILES || 'C:\\Program Files\\MetaTrader 5\\MQL5\\Files';
const RUTA_ESTADO = path.join(FILES, 'panel_estado.json');
const RUTA_LOG = path.join(FILES, 'adv.log');

// El log crece durante toda la sesión. Se guarda solo la cola para no leer
// megabytes en cada consulta del móvil.
const MAX_LOG_BYTES = 4 * 1024 * 1024;
const LINEAS_LOG = 500;

let cacheLog = { firma: '', lineas: [] };

async function leerEstado() {
  try {
    const txt = await readFile(RUTA_ESTADO, 'utf8');
    const datos = JSON.parse(txt);
    const st = await stat(RUTA_ESTADO);
    datos._edadSeg = Math.round((Date.now() - st.mtimeMs) / 1000);
    return datos;
  } catch (e) {
    return { error: 'sin datos del EA todavía', detalle: String(e.message), _edadSeg: null };
  }
}

async function leerLog() {
  let st;
  try {
    st = await stat(RUTA_LOG);
  } catch {
    return { firma: '', lineas: [] };
  }
  const firma = `${st.size}:${Math.round(st.mtimeMs)}`;
  if (firma === cacheLog.firma) return cacheLog;

  let texto = '';
  try {
    const todo = await readFile(RUTA_LOG);
    const desde = Math.max(0, todo.length - MAX_LOG_BYTES);
    texto = todo.subarray(desde).toString('latin1');
  } catch {
    return cacheLog;
  }
  const todas = texto.split(/\r?\n/).filter((l) => l.trim() !== '');
  cacheLog = { firma, lineas: todas.slice(-LINEAS_LOG) };
  return cacheLog;
}

function autorizado(url) {
  if (!CLAVE) return true;
  return url.searchParams.get('k') === CLAVE;
}

function enviar(res, codigo, tipo, cuerpo) {
  res.writeHead(codigo, {
    'content-type': tipo,
    'cache-control': 'no-store',
    'access-control-allow-origin': '*',
  });
  res.end(cuerpo);
}

const servidor = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (url.pathname === '/salud') {
    let estado = 'sin-json';
    try {
      const st = await stat(RUTA_ESTADO);
      estado = `ok edad=${Math.round((Date.now() - st.mtimeMs) / 1000)}s`;
    } catch {}
    return enviar(res, 200, 'text/plain; charset=utf-8', `panel adversario vivo · ${estado}\n`);
  }

  if (!autorizado(url)) {
    return enviar(res, 401, 'text/plain; charset=utf-8', 'clave incorrecta (falta ?k=...)\n');
  }

  if (url.pathname === '/api/estado') {
    const [estado, log] = await Promise.all([leerEstado(), leerLog()]);
    const senales = log.lineas.filter((l) => l.includes('[SENAL]')).slice(-60);
    return enviar(
      res,
      200,
      'application/json; charset=utf-8',
      JSON.stringify({ ok: true, estado, log: log.lineas, senales })
    );
  }

  if (url.pathname === '/' || url.pathname === '/index.html') {
    try {
      const html = readFileSync(path.join(AQUI, 'index.html'));
      return enviar(res, 200, 'text/html; charset=utf-8', html);
    } catch (e) {
      return enviar(res, 500, 'text/plain; charset=utf-8', 'falta index.html: ' + e.message);
    }
  }

  return enviar(res, 404, 'text/plain; charset=utf-8', 'no existe\n');
});

servidor.listen(PUERTO, '127.0.0.1', () => {
  console.log(`panel escuchando en http://127.0.0.1:${PUERTO}`);
  console.log(`estado: ${RUTA_ESTADO}`);
  console.log(`log:    ${RUTA_LOG}`);
  console.log(`clave:  ${CLAVE ? 'activa' : 'sin clave'}`);
});
