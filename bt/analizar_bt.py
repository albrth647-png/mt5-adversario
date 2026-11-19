#!/usr/bin/env python3
"""Analiza el backtest de MT5 (CSV del EA) y barre SL / TP / TL.

El EA en modo backtest escribe, en la carpeta comun de MT5:

    senales.csv          id;time;symbol;tf;code;dir;entry;stop;atr;tipo;h1
    barras_<TF>.csv      time;open;high;low;close

Con eso aqui se simula la operacion completa sin volver a correr MT5:

  SL  : amplio  = max(|entrada - stop estructural|, SL_ATR * ATR)
  TP  : TP_R * distancia del SL      (por defecto 1.5R)
  TL  : limite de tiempo en velas    (0 = sin limite)

Regla conservadora: si en la misma vela se tocan SL y TP, cuenta el SL.
Coste: `--cost-atr` ATR por operacion (ida y vuelta), por defecto 0.10.

Uso:  python3 bt/analizar_bt.py --entrada artefactos --salida reporte_bt.md
"""

import argparse
import bisect
import csv
import os
from collections import defaultdict

SL_ATR_BASE = 2.0
TP_R_BASE = 1.5
TLS = [0, 8, 16, 24, 48, 96, 192]
SL_SWEEP = [1.5, 2.0, 2.5, 3.0]


def leer_csv(ruta):
    with open(ruta, newline="", encoding="utf-8", errors="replace") as f:
        texto = f.read().splitlines()
    if not texto:
        return []
    cab = texto[0].split(";")
    filas = []
    for linea in texto[1:]:
        if not linea.strip():
            continue
        partes = linea.split(";")
        if len(partes) < len(cab):
            partes += [""] * (len(cab) - len(partes))
        filas.append(dict(zip(cab, partes)))
    return filas


def cargar(entrada):
    """Devuelve {carpeta: {'barras': {tf: [...]}, 'senales': [...]}}."""
    runs = {}
    for raiz, _, archivos in os.walk(entrada):
        if "senales.csv" not in archivos:
            continue
        run = {"barras": {}, "senales": []}
        for nombre in archivos:
            ruta = os.path.join(raiz, nombre)
            if nombre.startswith("barras_") and nombre.endswith(".csv"):
                tf = nombre[len("barras_"):-4]
                barras = []
                for b in leer_csv(ruta):
                    try:
                        barras.append((
                            b["time"],
                            float(b["open"]), float(b["high"]),
                            float(b["low"]), float(b["close"]),
                        ))
                    except (ValueError, KeyError):
                        continue
                barras.sort(key=lambda x: x[0])
                run["barras"][tf] = barras
            elif nombre == "senales.csv":
                run["senales"] = leer_csv(ruta)
        if run["senales"] or run["barras"]:
            runs[raiz] = run
    return runs


def simular(senal, barras, sl_atr, tp_r, tl, cost_atr):
    """Devuelve (R, velas) o None si no hay datos suficientes."""
    try:
        entrada = float(senal["entry"])
        stop_est = float(senal["stop"])
        atr = float(senal["atr"])
    except (ValueError, KeyError):
        return None
    if atr <= 0:
        return None

    distancia = abs(entrada - stop_est)
    distancia = max(distancia, sl_atr * atr)
    if distancia <= 0:
        return None

    signo = -1.0 if senal["dir"] == "VENTA" else 1.0
    sl = entrada - signo * distancia
    tp = entrada + signo * tp_r * distancia

    horas = [b[0] for b in barras]
    i0 = bisect.bisect_right(horas, senal["time"])
    if i0 >= len(barras):
        return None
    limite = min(len(barras), i0 + (tl if tl > 0 else len(barras)))

    for j in range(i0, limite):
        _, _, alto, bajo, _ = barras[j]
        toca_sl = (bajo <= sl) if signo > 0 else (alto >= sl)
        toca_tp = (alto >= tp) if signo > 0 else (bajo <= tp)
        if toca_sl:                      # conservador: el SL gana el empate
            return -1.0 - cost_atr, j - i0 + 1
        if toca_tp:
            return tp_r - cost_atr, j - i0 + 1

    if tl > 0:                            # cierre por tiempo
        j = limite - 1
        r = signo * (barras[j][4] - entrada) / distancia
        return r - cost_atr, tl
    return None


def metricas(rs):
    n = len(rs)
    if n == 0:
        return None
    ganadas = sum(1 for r in rs if r > 0)
    total = sum(rs)
    bruto_pos = sum(r for r in rs if r > 0)
    bruto_neg = -sum(r for r in rs if r < 0)
    pf = (bruto_pos / bruto_neg) if bruto_neg > 0 else float("inf")
    acum = 0.0
    pico = 0.0
    dd = 0.0
    for r in rs:
        acum += r
        pico = max(pico, acum)
        dd = max(dd, pico - acum)
    return {
        "n": n,
        "win": 100.0 * ganadas / n,
        "esperanza": total / n,
        "total": total,
        "pf": pf,
        "dd": dd,
    }


def tabla_tl(senales, barras_por_tf, sl_atr, tp_r, cost_atr):
    filas = []
    for tl in TLS:
        rs = []
        velas = []
        for s in senales:
            barras = barras_por_tf.get(s["tf"])
            if not barras:
                continue
            r = simular(s, barras, sl_atr, tp_r, tl, cost_atr)
            if r is None:
                continue
            rs.append(r[0])
            velas.append(r[1])
        m = metricas(rs)
        if m is None:
            continue
        m["tl"] = tl
        m["velas"] = sum(velas) / len(velas) if velas else 0.0
        filas.append(m)
    return filas


def fmt(m, etiqueta):
    pf = "inf" if m["pf"] == float("inf") else f"{m['pf']:.2f}"
    return (f"| {etiqueta} | {m['n']} | {m['win']:.1f} % | {m['esperanza']:+.3f} R "
            f"| {m['total']:+.1f} R | {pf} | {m['dd']:.1f} R | {m['velas']:.0f} |")


CABECERA = ("| grupo | n | acierto | E[R] | total | PF | DD máx | velas |\n"
            "|---|---:|---:|---:|---:|---:|---:|---:|")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--entrada", default="artefactos")
    ap.add_argument("--salida", default="reporte_bt.md")
    ap.add_argument("--cost-atr", type=float, default=0.10)
    args = ap.parse_args()

    runs = cargar(args.entrada)
    if not runs:
        raise SystemExit(f"no hay senales.csv ni barras_*.csv en {args.entrada}")

    # dedup: el mismo pase escribe las 4 TF, asi que una matriz M3+M5 repite
    senales, vistos = [], set()
    barras_por_clave = {}
    cobertura = {}
    simbolos = set()
    rango = [None, None]

    for raiz, run in runs.items():
        for tf, barras in run["barras"].items():
            if barras:
                clave = os.path.basename(raiz) + "|" + tf
                barras_por_clave[clave] = barras
                cobertura[clave] = (barras[0][0], barras[-1][0], len(barras))
        for s in run["senales"]:
            if s.get("tipo") != "ENTRADA":
                continue
            clave = (s["symbol"], s["tf"], s["time"], s["code"], s["dir"])
            if clave in vistos:
                continue
            vistos.add(clave)
            s["_run"] = os.path.basename(raiz)
            senales.append(s)
            simbolos.add(s["symbol"])
            if rango[0] is None or s["time"] < rango[0]:
                rango[0] = s["time"]
            if rango[1] is None or s["time"] > rango[1]:
                rango[1] = s["time"]

    # barras por (run, tf)
    barras_por_run_tf = defaultdict(dict)
    for raiz, run in runs.items():
        for tf, barras in run["barras"].items():
            if barras:
                barras_por_run_tf[os.path.basename(raiz)][tf] = barras
    for s in senales:
        s["_barras"] = barras_por_run_tf.get(s["_run"], {}).get(s["tf"])

    lineas = []
    lineas.append("# Backtest MT5 — señales, SL amplio, TP 1.5R y TL\n")
    lineas.append(f"- **Símbolos:** {', '.join(sorted(simbolos)) or '(ninguno)'}")
    lineas.append(f"- **Señales de entrada:** {len(senales)}")
    if rango[0]:
        lineas.append(f"- **Rango de señales:** {rango[0]} → {rango[1]}")
    lineas.append(f"- **Coste aplicado:** {args.cost_atr:.2f} ATR por operación")
    lineas.append("- **SL:** `max(distancia al stop estructural, "
                 f"{SL_ATR_BASE:.1f} ATR)` — amplio, no en la punta exacta")
    lineas.append(f"- **TP:** {TP_R_BASE:.1f}R · **TL:** barrido "
                 f"{', '.join('sin límite' if t == 0 else str(t) for t in TLS)} velas")
    lineas.append("- Empate en la misma vela: **cuenta el SL** (conservador).\n")

    lineas.append("## Cobertura de historia\n")
    lineas.append("| run | TF | velas | primera | última |")
    lineas.append("|---|---|---:|---|---|")
    for clave in sorted(cobertura):
        run, tf = clave.split("|")
        a, b, n = cobertura[clave]
        lineas.append(f"| {run} | {tf} | {n} | {a} | {b} |")
    lineas.append("\n> Si la primera vela es muy posterior a la fecha pedida, el broker "
                  "no tenía más historia: el tester no avisa de eso.\n")

    lineas.append(f"## TL × sensibilidad del SL (TP {TP_R_BASE:.1f}R)\n")
    for sl_atr in SL_SWEEP:
        filas = tabla_tl(senales, {s["tf"]: s["_barras"] for s in senales if s["_barras"]},
                         sl_atr, TP_R_BASE, args.cost_atr)
        if not filas:
            continue
        lineas.append(f"### SL = {sl_atr:.1f} ATR\n")
        lineas.append(CABECERA)
        for m in filas:
            etiqueta = "sin TL" if m["tl"] == 0 else f"{m['tl']} velas"
            lineas.append(fmt(m, etiqueta))
        lineas.append("")

    # por código, con el SL base y el mejor TL
    grupos = defaultdict(list)
    for s in senales:
        grupos[s["code"]].append(s)

    lineas.append("## Por código (SL amplio 2.0 ATR, TP 1.5R)\n")
    lineas.append("| código | n | mejor TL | acierto | E[R] | total |")
    lineas.append("|---|---:|---:|---:|---:|---:|")
    resumen = []
    for code, ss in grupos.items():
        filas = tabla_tl(ss, {s["tf"]: s["_barras"] for s in ss if s["_barras"]},
                         SL_ATR_BASE, TP_R_BASE, args.cost_atr)
        if not filas:
            continue
        mejor = max(filas, key=lambda m: m["esperanza"])
        resumen.append((code, filas, mejor))
    for code, filas, mejor in sorted(resumen, key=lambda x: -x[2]["n"]):
        etiqueta = "sin TL" if mejor["tl"] == 0 else f"{mejor['tl']} velas"
        lineas.append(f"| `{code}` | {mejor['n']} | {etiqueta} | {mejor['win']:.1f} % "
                      f"| {mejor['esperanza']:+.3f} R | {mejor['total']:+.1f} R |")
    lineas.append("")

    lineas.append("## Por código y TF (SL 2.0 ATR, TP 1.5R, mejor TL)\n")
    lineas.append("| código | TF | n | TL | acierto | E[R] |")
    lineas.append("|---|---|---:|---:|---:|---:|")
    detalle = defaultdict(list)
    for s in senales:
        detalle[(s["code"], s["tf"])].append(s)
    for (code, tf), ss in sorted(detalle.items(), key=lambda kv: -len(kv[1])):
        if len(ss) < 5:
            continue
        filas = tabla_tl(ss, {s["tf"]: s["_barras"] for s in ss if s["_barras"]},
                         SL_ATR_BASE, TP_R_BASE, args.cost_atr)
        if not filas:
            continue
        mejor = max(filas, key=lambda m: m["esperanza"])
        etiqueta = "sin TL" if mejor["tl"] == 0 else f"{mejor['tl']}"
        lineas.append(f"| `{code}` | {tf} | {mejor['n']} | {etiqueta} | "
                      f"{mejor['win']:.1f} % | {mejor['esperanza']:+.3f} R |")
    lineas.append("")

    lineas.append("## Cómo leerlo\n")
    lineas.append("- **E[R]** es lo que se gana por operación en unidades de riesgo. "
                  "Positivo y estable es lo que importa; el % de acierto solo no dice nada.")
    lineas.append("- **TL** es el límite de tiempo. Si la fila `sin TL` es la mejor, el "
                  "mercado necesita tiempo y cortar por reloj solo sirve para empeorar.")
    lineas.append("- **DD máx** está en R, no en dinero: es la peor racha acumulada.")
    lineas.append("- Un `n` pequeño (menos de 30) no decide nada: es ruido.")
    lineas.append("- El informe no modela spread variable ni swaps: se descuenta un coste "
                  "fijo en ATR (`--cost-atr`).")

    with open(args.salida, "w", encoding="utf-8") as f:
        f.write("\n".join(lineas) + "\n")
    print(f"informe: {args.salida} ({len(senales)} senales)")


if __name__ == "__main__":
    main()
