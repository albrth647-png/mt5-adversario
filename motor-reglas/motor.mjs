#!/usr/bin/env node
// Motor de reglas: lee CSV M1, agrega al TF de cada regla, evalua el contrato
// de 8 campos sobre velas CERRADAS, deduplica, resta coste y devuelve R medio
// con IC95% y desglose por hora / regimen / particion temporal.
//
// Uso:
//   node motor.mjs --reglas reglas.json --datos datos_m1 --salida salida
//
// Cada CSV: time,open,high,low,close,volume  (time en ISO UTC, p.ej. 2026-09-22T17:29:00Z)
//
// No copia nada de otros motores: parseo, agregacion, indicadores, evaluador
// de expresiones y estadistica estan escritos aqui desde cero.

import fs from 'node:fs';
import path from 'node:path';

// ------------------------------------------------------------------ args
function args() {
  const a = { reglas: 'reglas.json', datos: 'datos_m1', salida: 'salida' };
  const v = process.argv.slice(2);
  for (let i = 0; i < v.length; i++) {
    if (v[i].startsWith('--')) { a[v[i].slice(2)] = v[i + 1]; i++; }
  }
  return a;
}
const A = args();

// ------------------------------------------------------------------ TF
const TF_MS = { M1: 60e3, M3: 180e3, M5: 300e3, M15: 900e3, M30: 1800e3, H1: 3600e3, H4: 14400e3 };

// ------------------------------------------------------------------ CSV
function leerCSV(ruta) {
  const txt = fs.readFileSync(ruta, 'utf8').trim().split(/\r?\n/);
  const cab = txt[0].toLowerCase().split(',');
  const iT = cab.indexOf('time');
  const iO = cab.indexOf('open'), iH = cab.indexOf('high');
  const iL = cab.indexOf('low'), iC = cab.indexOf('close');
  const iV = cab.indexOf('volume');
  const out = [];
  for (let k = 1; k < txt.length; k++) {
    const c = txt[k].split(',');
    if (c.length < 5) continue;
    const t = Date.parse(c[iT]);
    if (!Number.isFinite(t)) continue;
    out.push({
      t,
      o: +c[iO], h: +c[iH], l: +c[iL], c: +c[iC],
      v: iV >= 0 ? +c[iV] : 0,
    });
  }
  return out;
}

// ------------------------------------------------------------- resample
function agrega(m1, tfMs) {
  const out = [];
  let cur = null;
  for (const b of m1) {
    const t = Math.floor(b.t / tfMs) * tfMs;
    if (!cur || cur.t !== t) {
      if (cur) out.push(cur);
      cur = { t, o: b.o, h: b.h, l: b.l, c: b.c, v: b.v };
    } else {
      if (b.h > cur.h) cur.h = b.h;
      if (b.l < cur.l) cur.l = b.l;
      cur.c = b.c;
      cur.v += b.v;
    }
  }
  if (cur) out.push(cur);
  return out;
}

// ---------------------------------------------------------- indicadores
function ema(serie, n) {
  const k = 2 / (n + 1);
  const out = new Array(serie.length).fill(NaN);
  let prev = NaN;
  for (let i = 0; i < serie.length; i++) {
    const x = serie[i];
    prev = Number.isNaN(prev) ? x : x * k + prev * (1 - k);
    out[i] = prev;
  }
  return out;
}
function sma(serie, n) {
  const out = new Array(serie.length).fill(NaN);
  let sum = 0;
  for (let i = 0; i < serie.length; i++) {
    sum += serie[i];
    if (i >= n) sum -= serie[i - n];
    if (i >= n - 1) out[i] = sum / n;
  }
  return out;
}
function atr(bars, n) {
  const out = new Array(bars.length).fill(NaN);
  let prevC = NaN, atrPrev = NaN;
  for (let i = 0; i < bars.length; i++) {
    const tr = i === 0 ? bars[i].h - bars[i].l
      : Math.max(bars[i].h - bars[i].l, Math.abs(bars[i].h - prevC), Math.abs(bars[i].l - prevC));
    prevC = bars[i].c;
    if (i < n) {
      if (i === n - 1) {
        let s = 0;
        for (let j = 0; j < n; j++) {
          const pc = j === 0 ? NaN : bars[j - 1].c;
          s += j === 0 ? bars[j].h - bars[j].l
            : Math.max(bars[j].h - bars[j].l, Math.abs(bars[j].h - pc), Math.abs(bars[j].l - pc));
        }
        atrPrev = s / n;
        out[i] = atrPrev;
      }
    } else {
      atrPrev = (atrPrev * (n - 1) + tr) / n;
      out[i] = atrPrev;
    }
  }
  return out;
}

// nombres de indicador -> array
function calculaIndicador(nombre, bars, cache) {
  if (cache[nombre]) return cache[nombre];
  const m = nombre.match(/^(ema|sma|atr)(\d+)$/);
  if (!m) throw new Error('indicador desconocido: ' + nombre);
  const n = +m[2];
  let arr;
  if (m[1] === 'ema') arr = ema(bars.map(b => b.c), n);
  else if (m[1] === 'sma') arr = sma(bars.map(b => b.c), n);
  else arr = atr(bars, n);
  cache[nombre] = arr;
  return arr;
}

// --------------------------------------------------- evaluador de expr
// Compila una expresion a funcion usando new Function con los identificadores
// que aparecen en ella como parametros. Sin eval con alcance dinamico.
const FUNCS = { min: Math.min, max: Math.max, abs: Math.abs, sqrt: Math.sqrt, floor: Math.floor, ceil: Math.ceil, round: Math.round };
function compila(expr) {
  const ids = new Set();
  const re = /[A-Za-z_][A-Za-z0-9_]*/g;
  let m;
  const sinFunc = expr.replace(/\b(min|max|abs|sqrt|floor|ceil|round)\s*\(/g, '(');
  while ((m = re.exec(sinFunc))) {
    const id = m[0];
    if (['true', 'false', 'null'].includes(id)) continue;
    ids.add(id);
  }
  const params = [...ids];
  const cuerpo = 'return (' + expr.replace(/\b(min|max|abs|sqrt|floor|ceil|round)\s*\(/g,
    (_, f) => 'FUNC.' + f + '(') + ');';
  // eslint-disable-next-line no-new-func
  const fn = new Function('FUNC', ...params, cuerpo);
  return (env) => fn(FUNCS, ...params.map(p => env[p]));
}

// ------------------------------------------------ entorno de una barra
function entornoBarra(bars, i, inds, extra = {}) {
  const b = bars[i];
  const p = i >= 1 ? bars[i - 1] : b;
  const p2 = i >= 2 ? bars[i - 2] : p;
  const p3 = i >= 3 ? bars[i - 3] : p2;
  const env = {
    open: b.o, high: b.h, low: b.l, close: b.c, volume: b.v,
    range: b.h - b.l, body: Math.abs(b.c - b.o),
    prev_open: p.o, prev_high: p.h, prev_low: p.l, prev_close: p.c,
    prev_range: p.h - p.l, prev_body: Math.abs(p.c - p.o),
    prev2_open: p2.o, prev2_high: p2.h, prev2_low: p2.l, prev2_close: p2.c,
    prev2_range: p2.h - p2.l, prev2_body: Math.abs(p2.c - p2.o),
    prev3_open: p3.o, prev3_high: p3.h, prev3_low: p3.l, prev3_close: p3.c,
    prev3_range: p3.h - p3.l, prev3_body: Math.abs(p3.c - p3.o),
    ...extra,
  };
  for (const [nombre, arr] of Object.entries(inds)) env[nombre] = arr[i];
  // valores del indicador en velas anteriores (para reglas tipo "spike")
  if (inds.atr14) {
    env.atr14_prev = i >= 1 ? inds.atr14[i - 1] : NaN;
    env.atr14_prev2 = i >= 2 ? inds.atr14[i - 2] : NaN;
  }
  return env;
}

// ------------------------------------------------------- percentiles
function quantile(orden, q) {
  if (!orden.length) return NaN;
  const pos = (orden.length - 1) * q;
  const lo = Math.floor(pos), hi = Math.ceil(pos);
  return orden[lo] + (orden[hi] - orden[lo]) * (pos - lo);
}

// ------------------------------------------------------ simular 1 trade
function simular(bars, iDisp, dir, stop, objetivo, caducidad, cfg) {
  const iEnt = iDisp + 1;
  if (iEnt >= bars.length) return null;
  const entrada = bars[iEnt].o;
  const riesgo = dir === 'long' ? entrada - stop : stop - entrada;
  if (!(riesgo > 0)) return null;
  const coste = entrada * (cfg.spread_frac + cfg.slippage_frac);
  let exit = null, motivo = null;
  const fin = Math.min(iEnt + caducidad, bars.length - 1);
  for (let j = iEnt; j <= fin; j++) {
    const b = bars[j];
    if (dir === 'long') {
      if (b.l <= stop) { exit = stop; motivo = 'stop'; break; }
      if (b.h >= objetivo) { exit = objetivo; motivo = 'objetivo'; break; }
    } else {
      if (b.h >= stop) { exit = stop; motivo = 'stop'; break; }
      if (b.l <= objetivo) { exit = objetivo; motivo = 'objetivo'; break; }
    }
  }
  if (exit === null) { exit = bars[fin].c; motivo = 'caducidad'; }
  const bruto = dir === 'long' ? exit - entrada : entrada - exit;
  const neto = bruto - coste;
  return {
    iEnt, entrada, stop, objetivo, exit, motivo, riesgo, coste,
    R_gross: bruto / riesgo,
    R_net: neto / riesgo,
  };
}

// ------------------------------------------------------------ estadistica
function stats(Rs) {
  const n = Rs.length;
  if (!n) return { n: 0, media: NaN, ic95: [NaN, NaN], sd: NaN, acierto: NaN };
  const media = Rs.reduce((a, b) => a + b, 0) / n;
  const var_ = n > 1 ? Rs.reduce((a, b) => a + (b - media) ** 2, 0) / (n - 1) : 0;
  const sd = Math.sqrt(var_);
  const se = n > 1 ? sd / Math.sqrt(n) : NaN;
  return {
    n, media, sd,
    ic95: [media - 1.96 * se, media + 1.96 * se],
    acierto: Rs.filter(r => r > 0).length / n,
  };
}

// ------------------------------------------------------- evaluar 1 regla
function evaluaRegla(regla, m1, cfg) {
  const tfDisp = TF_MS[regla.tf_disparo];
  if (!tfDisp) throw new Error('tf_disparo invalido: ' + regla.tf_disparo);
  const bars = agrega(m1, tfDisp);
  const tfCtx = regla.tf_contexto ? TF_MS[regla.tf_contexto] : null;
  const ctx = tfCtx ? agrega(m1, tfCtx) : null;

  // que indicadores pide cada expresion
  const todas = [regla.contexto, regla.disparador, regla.stop, regla.objetivo]
    .filter(Boolean).join(' ');
  const indsNombres = [...new Set((todas.match(/\b(ema|sma|atr)\d+\b/g) || []))];

  const cacheDisp = {}, cacheCtx = {};
  const indsDisp = {}, indsCtx = {};
  for (const nm of indsNombres) {
    try { indsDisp[nm] = calculaIndicador(nm, bars, cacheDisp); } catch { /* ignora en disparo si falla */ }
    if (ctx) { try { indsCtx[nm] = calculaIndicador(nm, ctx, cacheCtx); } catch { /* idem */ } }
  }

  const fCtx = regla.contexto ? compila(regla.contexto) : () => true;
  const fDisp = compila(regla.disparador);
  const fStop = compila(regla.stop);
  const fObj = compila(regla.objetivo);

  // cuantiles de ATR para etiquetar regimen (solo etiqueta, no filtra)
  const atrArr = indsDisp['atr14'] || calculaIndicador('atr14', bars, cacheDisp);
  const atrValidos = atrArr.filter(Number.isFinite).sort((a, b) => a - b);
  const q33 = quantile(atrValidos, 0.33), q66 = quantile(atrValidos, 0.66);
  // ema100 se necesita SIEMPRE para etiquetar regimen, aunque la regla no lo pida
  const ema100 = indsDisp['ema100'] || calculaIndicador('ema100', bars, cacheDisp);

  // indice del ultimo bar de contexto CERRADO antes del open del disparo
  function ctxCierto(tOpen) {
    if (!ctx) return -1;
    let lo = 0, hi = ctx.length - 1, res = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (ctx[mid].t + tfCtx <= tOpen) { res = mid; lo = mid + 1; } else hi = mid - 1;
    }
    return res;
  }

  const disparos = [];
  let ultimo = -1e9;
  for (let i = 1; i < bars.length; i++) {
    const envD = entornoBarra(bars, i, indsDisp);
    // vetos
    let vetado = false;
    for (const v of (regla.vetos || [])) {
      if (v.tipo === 'rango_atr') {
        // la propia vela disparadora >= mult*ATR -> veto
        if (envD.range >= v.mult * envD.atr14) { vetado = true; break; }
      } else if (v.tipo === 'hora') {
        const hUTC = new Date(bars[i].t).getUTCHours();
        const dentro = v.desde < v.hasta
          ? (hUTC >= v.desde && hUTC < v.hasta)
          : (hUTC >= v.desde || hUTC < v.hasta);
        if (dentro) { vetado = true; break; }
      } else if (v.tipo === 'spread') {
        // sin spread por barra: nunca bloquea (documentado)
      }
    }
    if (vetado) continue;

    let ok;
    try { ok = fDisp(envD); } catch { ok = false; }
    if (!ok) continue;

    // contexto
    if (ctx) {
      const ic = ctxCierto(bars[i].t);
      if (ic < 0) continue;
      const envC = entornoBarra(ctx, ic, indsCtx);
      let okC;
      try { okC = fCtx(envC); } catch { okC = false; }
      if (!okC) continue;
    }

    // dedupe
    if (i - ultimo < (regla.dedupe_velas || 1)) continue;
    ultimo = i;

    // stop y objetivo
    let stop, objetivo;
    try {
      const eStop = { ...envD, entrada: bars[i + 1] ? bars[i + 1].o : NaN };
      stop = fStop(eStop);
      const eObj = { ...envD, entrada: eStop.entrada, stop };
      objetivo = fObj(eObj);
    } catch { continue; }
    if (!Number.isFinite(stop) || !Number.isFinite(objetivo)) continue;

    const tr = simular(bars, i, regla.direccion, stop, objetivo, regla.caducidad || 1, cfg);
    if (!tr) continue;

    // etiqueta de regimen en el disparo
    let regimen = 'na';
    if (Number.isFinite(ema100 ? ema100[i] : NaN)) {
      const tend = bars[i].c > ema100[i] ? 'alcista' : 'bajista';
      const a = atrArr[i];
      const vol = a > q66 ? 'vol_alta' : (a < q33 ? 'vol_baja' : 'vol_media');
      regimen = tend + '/' + vol;
    }
    disparos.push({
      i, t: bars[i].t,
      hora: new Date(bars[i].t).getUTCHours(),
      regimen, ...tr,
    });
  }
  return { disparos, bars };
}

// ------------------------------------------------------------- programa
function main() {
  const cfg = { spread_frac: 0.0002, slippage_frac: 0.0001 };
  const reglasDoc = JSON.parse(fs.readFileSync(path.join(A.reglas), 'utf8'));
  Object.assign(cfg, reglasDoc.config || {});
  const reglas = reglasDoc.reglas || [];

  const ficheros = fs.readdirSync(A.datos).filter(f => f.endsWith('.csv'));
  const activos = ficheros.map(f => ({ activo: f.replace(/_M1\.csv$/, ''), ruta: path.join(A.datos, f) }));

  fs.mkdirSync(A.salida, { recursive: true });
  const filas = [];
  const resumen = [];

  for (const { activo, ruta } of activos) {
    const m1 = leerCSV(ruta);
    if (!m1.length) continue;
    for (const regla of reglas) {
      let salida;
      try { salida = evaluaRegla(regla, m1, cfg); }
      catch (e) { console.error(`[${activo}][${regla.id}] ERROR: ${e.message}`); continue; }
      const ds = salida.disparos;
      if (!ds.length) {
        resumen.push({ activo, regla: regla.id, n: 0 });
        continue;
      }
      // particion temporal 60/20/20 sobre el rango temporal del activo
      const t0 = m1[0].t, t1 = m1[m1.length - 1].t;
      const corte1 = t0 + (t1 - t0) * 0.60, corte2 = t0 + (t1 - t0) * 0.80;
      for (const d of ds) {
        const split = d.t < corte1 ? 'descubrimiento' : (d.t < corte2 ? 'validacion' : 'test');
        filas.push({
          activo, regla: regla.id, split,
          fecha_utc: new Date(d.t).toISOString(),
          hora_utc: d.hora, direccion: regla.direccion,
          entrada: d.entrada, stop: d.stop, objetivo: d.objetivo,
          exit: d.exit, motivo: d.motivo, regimen: d.regimen,
          R_gross: d.R_gross.toFixed(4), R_net: d.R_net.toFixed(4),
        });
      }
      const Rn = ds.map(d => d.R_net);
      const Rg = ds.map(d => d.R_gross);
      const st = stats(Rn);
      // por split
      const porSplit = {};
      for (const sp of ['descubrimiento', 'validacion', 'test']) {
        const sub = ds.filter((d, k) => {
          const split = d.t < corte1 ? 'descubrimiento' : (d.t < corte2 ? 'validacion' : 'test');
          return split === sp;
        });
        porSplit[sp] = stats(sub.map(d => d.R_net));
      }
      resumen.push({
        activo, regla: regla.id, n: st.n,
        mediaR: st.media, ic95: st.ic95, acierto: st.acierto,
        mediaR_bruto: stats(Rg).media,
        porSplit,
        porHora: agrupa(ds, d => 'h' + d.hora, d => d.R_net),
        porRegimen: agrupa(ds, d => d.regimen, d => d.R_net),
      });
    }
  }

  // disparos.csv
  const cab = ['activo', 'regla', 'split', 'fecha_utc', 'hora_utc', 'direccion',
    'entrada', 'stop', 'objetivo', 'exit', 'motivo', 'regimen', 'R_gross', 'R_net'];
  const csv = [cab.join(',')].concat(filas.map(f => cab.map(c => f[c]).join(','))).join('\n');
  fs.writeFileSync(path.join(A.salida, 'disparos.csv'), csv + '\n');
  fs.writeFileSync(path.join(A.salida, 'resumen.json'), JSON.stringify(resumen, null, 2));

  // resumen.md
  const L = ['# Resumen del motor de reglas', ''];
  L.push('Coste modelado: spread_frac=' + cfg.spread_frac + ', slippage_frac=' + cfg.slippage_frac + ' (fraccion del precio).');
  L.push('Metrica de decision: R medio por operacion (neto) y su IC95%.', '');
  const porRegla = {};
  for (const r of resumen) {
    if (!r.n) continue;
    (porRegla[r.regla] ||= []).push(r);
  }
  for (const [regla, arr] of Object.entries(porRegla)) {
    L.push('## ' + regla, '');
    L.push('| activo | n | R medio | IC95% | acierto | R bruto | desc | val | test |');
    L.push('|---|---|---|---|---|---|---|---|---|');
    for (const r of arr) {
      const ci = `[${r.ic95[0].toFixed(3)}, ${r.ic95[1].toFixed(3)}]`;
      const f = (s) => s.n ? `${s.media.toFixed(3)} (n=${s.n})` : '—';
      L.push(`| ${r.activo} | ${r.n} | ${r.mediaR.toFixed(3)} | ${ci} | ${(r.acierto * 100).toFixed(1)}% | ${r.mediaR_bruto.toFixed(3)} | ${f(r.porSplit.descubrimiento)} | ${f(r.porSplit.validacion)} | ${f(r.porSplit.test)} |`);
    }
    L.push('');
  }
  // agregado por hora y regimen sobre todos los disparos
  const num = (x) => parseFloat(x);
  const porHoraAll = {};
  const porRegAll = {};
  for (const f of filas) {
    (porHoraAll[f.hora_utc] ||= []).push(num(f.R_net));
    (porRegAll[f.regimen] ||= []).push(num(f.R_net));
  }
  L.push('## Desglose por hora UTC (todas las reglas juntas)', '');
  L.push('| hora | n | R medio | IC95% |');
  L.push('|---|---|---|---|');
  for (const h of Object.keys(porHoraAll).map(Number).sort((a, b) => a - b)) {
    const s = stats(porHoraAll[h]);
    L.push(`| ${String(h).padStart(2, '0')}:00 | ${s.n} | ${s.media.toFixed(3)} | [${s.ic95[0].toFixed(3)}, ${s.ic95[1].toFixed(3)}] |`);
  }
  L.push('', '## Desglose por regimen (todas las reglas juntas)', '');
  L.push('| regimen | n | R medio | IC95% |');
  L.push('|---|---|---|---|');
  for (const [reg, arr] of Object.entries(porRegAll).sort((a, b) => b[1].length - a[1].length)) {
    const s = stats(arr);
    L.push(`| ${reg} | ${s.n} | ${s.media.toFixed(3)} | [${s.ic95[0].toFixed(3)}, ${s.ic95[1].toFixed(3)}] |`);
  }
  L.push('');
  fs.writeFileSync(path.join(A.salida, 'resumen.md'), L.join('\n') + '\n');
  console.log(`Disparos: ${filas.length} filas -> ${A.salida}/disparos.csv`);
  console.log(`Reglas con senales: ${Object.keys(porRegla).length}/${reglas.length}`);
}

function agrupa(arr, clave, valor) {
  const m = {};
  for (const x of arr) {
    const k = clave(x);
    (m[k] ||= []).push(valor(x));
  }
  const out = {};
  for (const [k, v] of Object.entries(m)) out[k] = stats(v);
  return out;
}

main();
