#!/usr/bin/env python3
"""Analiza el backtest de MT5 (CSV del EA) y barre SL / TP / TL.

El EA en modo backtest escribe, en la carpeta comun de MT5:

    senales.csv          id;time;symbol;tf;code;dir;entry;stop;atr;tipo;h1
    barras_<TF>.csv      time;open;high;low;close

Con eso se simula la operacion completa sin volver a correr MT5:

  SL  : amplio  = max(|entrada - stop estructural|, SL_ATR * ATR)
  TP  : TP_R * distancia del SL      (1.5R por defecto)
  TL  : limite de tiempo en velas    (0 = sin limite)
  Dinero: capital, riesgo por operacion, lotes y curva de capital.

Regla conservadora: si en la misma vela se tocan SL y TP, cuenta el SL.
Coste: `--cost-atr` ATR por operacion (ida y vuelta), por defecto 0.10.

El camino del precio se recorre UNA vez por senal y SL: de ahi salen todos
los TL a la vez. Con 28k senales eso es la diferencia entre minutos y horas.

Uso:  python3 bt/analizar_bt.py --entrada artefactos --salida reporte_bt.md \
        --capital 200 --riesgo 3
"""

import argparse
import bisect
import os
import sys
from collections import defaultdict

SL_ATR_BASE = 2.0
TP_R_BASE = 1.5
TLS = [0, 8, 16, 24, 48, 96, 192]
SL_SWEEP = [1.5, 2.0, 2.5, 3.0]
MAX_VELAS = 300           # horizonte maximo del caso "sin TL" (15 h en M3)


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


def distancia_sl(senal, sl_atr):
    """(entrada, stop, distancia, signo) o None."""
    try:
        entrada = float(senal["entry"])
        stop_est = float(senal["stop"])
        atr = float(senal["atr"])
    except (ValueError, KeyError):
        return None
    if atr <= 0:
        return None
    dist = max(abs(entrada - stop_est), sl_atr * atr)
    if dist <= 0:
        return None
    signo = -1.0 if senal["dir"] == "VENTA" else 1.0
    return entrada, dist, signo


def resultados(senal, sl_atr, tp_r, cost_atr):
    """Una pasada: {tl: (R, velas, hora_salida)} para todos los TL."""
    barras = senal.get("_barras")
    d = distancia_sl(senal, sl_atr)
    if not barras or d is None:
        return None
    entrada, dist, signo = d
    sl = entrada - signo * dist
    tp = entrada + signo * tp_r * dist

    horas = senal["_horas"]
    i0 = bisect.bisect_right(horas, senal["time"])
    if i0 >= len(barras):
        return None

    fin = min(len(barras), i0 + MAX_VELAS)
    salida = None
    for j in range(i0, fin):
        _, _, alto, bajo, _ = barras[j]
        toca_sl = (bajo <= sl) if signo > 0 else (alto >= sl)
        toca_tp = (alto >= tp) if signo > 0 else (bajo <= tp)
        if toca_sl:                       # conservador: el SL gana el empate
            salida = (-1.0 - cost_atr, j - i0 + 1, barras[j][0], "SL")
            break
        if toca_tp:
            salida = (tp_r - cost_atr, j - i0 + 1, barras[j][0], "TP")
            break

    res = {}
    for tl in TLS:
        if salida is not None and (tl == 0 or salida[1] <= tl):
            res[tl] = salida
            continue
        j = (min(len(barras), i0 + tl) if tl > 0 else fin) - 1
        if j < i0:
            res[tl] = None
            continue
        r = signo * (barras[j][4] - entrada) / dist - cost_atr
        res[tl] = (r, j - i0 + 1, barras[j][0], "TL")
    return res


def cache(senal, sl_atr, tp_r, cost_atr):
    if not hasattr(senal, "_res"):
        senal["_res"] = {}
    clave = (sl_atr, tp_r, cost_atr)
    if clave not in senal["_res"]:
        senal["_res"][clave] = resultados(senal, sl_atr, tp_r, cost_atr)
    return senal["_res"][clave]


def metricas(rs, tipos=None):
    n = len(rs)
    if n == 0:
        return None
    ganadas = sum(1 for r in rs if r > 0)
    total = sum(rs)
    pos = sum(r for r in rs if r > 0)
    neg = -sum(r for r in rs if r < 0)
    pf = (pos / neg) if neg > 0 else float("inf")
    acum = pico = dd = 0.0
    for r in rs:
        acum += r
        pico = max(pico, acum)
        dd = max(dd, pico - acum)
    m = {"n": n, "win": 100.0 * ganadas / n, "esperanza": total / n,
         "total": total, "pf": pf, "dd": dd}
    if tipos:
        m["tp"] = 100.0 * sum(1 for t in tipos if t == "TP") / n
        m["sl"] = 100.0 * sum(1 for t in tipos if t == "SL") / n
    return m


def tabla_tl(senales, sl_atr, tp_r, cost_atr):
    filas = []
    for tl in TLS:
        rs, velas, tipos = [], [], []
        for s in senales:
            if not s.get("_barras"):
                continue
            res = cache(s, sl_atr, tp_r, cost_atr)
            if not res or res.get(tl) is None:
                continue
            rs.append(res[tl][0])
            velas.append(res[tl][1])
            tipos.append(res[tl][3])
        m = metricas(rs, tipos)
        if m is None:
            continue
        m["tl"] = tl
        m["velas"] = sum(velas) / len(velas) if velas else 0.0
        filas.append(m)
    return filas


def lotes_para(riesgo_usd, distancia, contrato, min_lote, lote_max):
    """Lotes que arriesgan <= riesgo_usd, redondeando a la baja."""
    if distancia <= 0 or contrato <= 0:
        return 0.0, 0.0
    pasos = int((riesgo_usd / (distancia * contrato)) / min_lote + 1e-9)
    lotes = round(pasos * min_lote, 8)
    if lotes < min_lote:
        return min_lote, min_lote * distancia * contrato
    if lotes > lote_max:
        return lote_max, lote_max * distancia * contrato
    return lotes, lotes * distancia * contrato


def tabla_dinero(senales, sl_atr, tp_r, tl, cost_atr, capital, riesgo_usd,
                 contrato, min_lote, lote_max, riesgo_pct=0.0):
    ops = []
    for s in senales:
        if not s.get("_barras"):
            continue
        res = cache(s, sl_atr, tp_r, cost_atr)
        if not res or res.get(tl) is None:
            continue
        ops.append((s["time"], s, res[tl][0], res[tl][2]))
    ops.sort(key=lambda x: x[0])
    if not ops:
        return None

    eq = capital
    pico = capital
    dd_usd = dd_pct = 0.0
    racha = racha_max = 0
    abiertas = []
    max_sim = 0
    meses = {}
    forzados = 0
    total = 0.0
    ganadas = 0
    hechas = 0
    ruina = None
    bruto_pos = bruto_neg = 0.0

    for t, s, rr, t_sal in ops:
        if eq <= 0:
            ruina = t          # sin capital no hay operacion siguiente
            break
        hechas += 1
        abiertas = [x for x in abiertas if x > t]
        d = distancia_sl(s, sl_atr)
        if d is None:
            continue
        _, distancia, _ = d
        riesgo_i = (eq * riesgo_pct / 100.0) if riesgo_pct > 0 else riesgo_usd
        _, riesgo_real = lotes_para(riesgo_i, distancia, contrato, min_lote, lote_max)
        if riesgo_real > riesgo_i + 1e-9:
            forzados += 1
        pnl = rr * riesgo_real
        eq += pnl
        total += pnl
        if pnl > 0:
            ganadas += 1
            bruto_pos += pnl
            racha = 0
        else:
            bruto_neg += -pnl
            racha += 1
            racha_max = max(racha_max, racha)
        pico = max(pico, eq)
        caida = pico - eq
        if caida > dd_usd:
            dd_usd = caida
            dd_pct = 100.0 * caida / pico if pico > 0 else 0.0
        abiertas.append(t_sal)
        max_sim = max(max_sim, len(abiertas))
        mes = t[:7]
        meses.setdefault(mes, {"n": 0, "usd": 0.0})
        meses[mes]["n"] += 1
        meses[mes]["usd"] += pnl

    n = hechas
    return {"n": n, "win": 100.0 * ganadas / n if n else 0.0,
            "ruina": ruina,
            "esperanza": total / n if n else 0.0, "total": total,
            "pf": (bruto_pos / bruto_neg) if bruto_neg > 0 else float("inf"),
            "dd_usd": dd_usd, "dd_pct": dd_pct, "final": eq,
            "retorno": 100.0 * (eq - capital) / capital,
            "racha": racha_max, "max_sim": max_sim, "forzados": forzados,
            "meses": meses, "tl": tl}


def fmt_r(m, etiqueta):
    pf = "inf" if m["pf"] == float("inf") else f"{m['pf']:.2f}"
    return (f"| {etiqueta} | {m['n']} | {m.get('tp', 0.0):.1f} % | {m.get('sl', 0.0):.1f} % "
            f"| {m['esperanza']:+.3f} R | {m['total']:+.1f} R | {pf} | {m['dd']:.1f} R "
            f"| {m['velas']:.0f} |")


def fmt_usd(m, etiqueta):
    pf = "inf" if m["pf"] == float("inf") else f"{m['pf']:.2f}"
    return (f"| {etiqueta} | {m['n']} | {m['win']:.1f} % | {m['esperanza']:+.2f} $ "
            f"| {m['total']:+.2f} $ | {pf} | {m['dd_usd']:.2f} $ | {m['dd_pct']:.1f} % "
            f"| {m['final']:.2f} $ | {m['retorno']:+.1f} % |")


CAB_R = ("| grupo | n | TP | SL | E[R] | total | PF | DD máx | velas |\n"
         "|---|---:|---:|---:|---:|---:|---:|---:|---:|")
CAB_USD = ("| TL | n | acierto | E[$] | total | PF | DD $ | DD % | final | retorno |\n"
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--entrada", default="artefactos")
    ap.add_argument("--salida", default="reporte_bt.md")
    ap.add_argument("--cost-atr", type=float, default=0.10)
    ap.add_argument("--capital", type=float, default=200.0)
    ap.add_argument("--riesgo", type=float, default=3.0)
    ap.add_argument("--riesgo-pct", type=float, default=0.0,
                    help=">0 = riesgo como %% del capital actual (compuesto)")
    ap.add_argument("--contrato", type=float, default=1.0,
                    help="USD por punto de precio y lote")
    ap.add_argument("--min-lote", type=float, default=0.01)
    ap.add_argument("--lote-max", type=float, default=100.0)
    args = ap.parse_args()

    runs = cargar(args.entrada)
    if not runs:
        raise SystemExit(f"no hay senales.csv ni barras_*.csv en {args.entrada}")

    senales, vistos = [], set()
    cobertura = {}
    simbolos = set()
    rango = [None, None]
    barras_por_run_tf = defaultdict(dict)

    for raiz, run in runs.items():
        base = os.path.basename(raiz)
        for tf, barras in run["barras"].items():
            if barras:
                barras_por_run_tf[base][tf] = barras
                cobertura[f"{base}|{tf}"] = (barras[0][0], barras[-1][0], len(barras))
        for s in run["senales"]:
            if s.get("tipo") != "ENTRADA":
                continue
            clave = (s["symbol"], s["tf"], s["time"], s["code"], s["dir"])
            if clave in vistos:
                continue
            vistos.add(clave)
            s["_run"] = base
            barras = barras_por_run_tf[base].get(s["tf"])
            s["_barras"] = barras
            s["_horas"] = [b[0] for b in barras] if barras else None
            senales.append(s)
            simbolos.add(s["symbol"])
            if rango[0] is None or s["time"] < rango[0]:
                rango[0] = s["time"]
            if rango[1] is None or s["time"] > rango[1]:
                rango[1] = s["time"]

    print(f"{len(senales)} senales en {len(runs)} runs", file=sys.stderr)

    L = []
    L.append("# Backtest MT5 — señales, SL amplio, TP 1.5R y TL\n")
    L.append(f"- **Símbolos:** {', '.join(sorted(simbolos)) or '(ninguno)'}")
    L.append(f"- **Señales de entrada:** {len(senales)}")
    if rango[0]:
        L.append(f"- **Rango de señales:** {rango[0]} → {rango[1]}")
    L.append(f"- **Coste aplicado:** {args.cost_atr:.2f} ATR por operación")
    L.append(f"- **SL:** `max(distancia al stop estructural, {SL_ATR_BASE:.1f} ATR)` — "
             "amplio, no en la punta exacta")
    L.append(f"- **TP:** {TP_R_BASE:.1f}R · **TL:** barrido "
             f"{', '.join('sin límite' if t == 0 else str(t) for t in TLS)} velas")
    L.append("- Empate en la misma vela: **cuenta el SL** (conservador).\n")

    L.append("## Cobertura de historia\n")
    L.append("| run | TF | velas | primera | última |")
    L.append("|---|---|---:|---|---|")
    for clave in sorted(cobertura):
        run, tf = clave.split("|")
        a, b, n = cobertura[clave]
        L.append(f"| {run} | {tf} | {n} | {a} | {b} |")
    L.append("\n> Si la primera vela es muy posterior a la fecha pedida, el broker "
             "no tenía más historia: el tester no avisa de eso.\n")

    # ------------------------------------------------ R: SL x TL
    L.append(f"## R: TL × sensibilidad del SL (TP {TP_R_BASE:.1f}R)\n")
    for sl_atr in SL_SWEEP:
        filas = tabla_tl(senales, sl_atr, TP_R_BASE, args.cost_atr)
        if not filas:
            continue
        L.append(f"### SL = {sl_atr:.1f} ATR\n")
        L.append(CAB_R)
        for m in filas:
            L.append(fmt_r(m, "sin TL" if m["tl"] == 0 else f"{m['tl']} velas"))
        L.append("")
        print(f"  R SL={sl_atr} listo", file=sys.stderr)

    # ------------------------------------------------ dinero
    L.append(f"## Capital {args.capital:.0f} USD · riesgo {args.riesgo:.0f} USD por operación\n")
    modo = (f"riesgo {args.riesgo_pct:.1f} % del capital actual" if args.riesgo_pct > 0
            else f"riesgo fijo {args.riesgo:.0f} USD")
    L.append(f"- **{modo}** · TP {TP_R_BASE:.1f}R · SL {SL_ATR_BASE:.1f} ATR")
    L.append(f"- 1 lote = {args.contrato:g} USD por punto de precio · "
             f"lote mínimo {args.min_lote:g}")
    L.append("- Lotes **redondeados a la baja**: nunca se arriesga más de lo pedido "
             "(salvo cuando el lote mínimo obliga).\n")
    L.append(CAB_USD)
    dinero = []
    for tl in TLS:
        m = tabla_dinero(senales, SL_ATR_BASE, TP_R_BASE, tl, args.cost_atr,
                         args.capital, args.riesgo, args.contrato,
                         args.min_lote, args.lote_max, args.riesgo_pct)
        if not m:
            continue
        dinero.append(m)
        L.append(fmt_usd(m, "sin TL" if tl == 0 else f"{tl} velas"))
    L.append("")

    if dinero:
        mejor = max(dinero, key=lambda m: m["final"])
        et = "sin TL" if mejor["tl"] == 0 else f"{mejor['tl']} velas"
        if mejor.get("ruina"):
            L.append(f"> **Ruina el {mejor['ruina']}**: con {args.riesgo:.0f} USD por "
                     f"operación los {args.capital:.0f} USD no aguantan. La simulación se "
                     f"corta ahí ({mejor['n']} operaciones); después de ese punto no habría "
                     f"cuenta con la que operar.\n")
        L.append(f"### Mes a mes (mejor TL: {et})\n")
        L.append("| mes | ops | resultado | capital |")
        L.append("|---|---:|---:|---:|")
        eqm = args.capital
        tope = mejor["ruina"][:7] if mejor.get("ruina") else None
        for mes in sorted(mejor["meses"]):
            if tope and mes > tope:
                continue
            d = mejor["meses"][mes]
            eqm += d["usd"]
            L.append(f"| {mes} | {d['n']} | {d['usd']:+.2f} $ | {eqm:.2f} $ |")
        L.append("")
        L.append(f"- Racha perdedora máxima: **{mejor['racha']}** · posiciones "
                 f"simultáneas máx: **{mejor['max_sim']}** · operaciones forzadas al "
                 f"lote mínimo: **{mejor['forzados']}**")
        L.append(f"- Con {args.riesgo:.0f} USD por operación, una racha de "
                 f"{mejor['racha']} pérdidas son {mejor['racha'] * args.riesgo:.0f} USD "
                 f"({100.0 * mejor['racha'] * args.riesgo / args.capital:.1f} % del capital).")
        L.append(f"- Si se arriesga el {100.0 * args.riesgo / args.capital:.1f} % por "
                 f"operación, {mejor['n']} operaciones al año son "
                 f"{mejor['n'] / 12:.0f} al mes.\n")

    # ------------------------------------------------ por código
    grupos = defaultdict(list)
    for s in senales:
        grupos[s["code"]].append(s)

    L.append("## Por código (SL 2.0 ATR, TP 1.5R)\n")
    L.append("| código | n | mejor TL | acierto | E[R] | total | $ (mejor TL) |")
    L.append("|---|---:|---:|---:|---:|---:|---:|")
    resumen = []
    for code, ss in grupos.items():
        filas = tabla_tl(ss, SL_ATR_BASE, TP_R_BASE, args.cost_atr)
        if not filas:
            continue
        mejor_r = max(filas, key=lambda m: m["esperanza"])
        din = tabla_dinero(ss, SL_ATR_BASE, TP_R_BASE, mejor_r["tl"], args.cost_atr,
                           args.capital, args.riesgo, args.contrato,
                           args.min_lote, args.lote_max, args.riesgo_pct)
        resumen.append((code, mejor_r, din))
    for code, m, din in sorted(resumen, key=lambda x: -x[1]["n"]):
        et = "sin TL" if m["tl"] == 0 else f"{m['tl']}"
        usd = f"{din['total']:+.2f} $" if din else "—"
        L.append(f"| `{code}` | {m['n']} | {et} | {m['win']:.1f} % | "
                 f"{m['esperanza']:+.3f} R | {m['total']:+.1f} R | {usd} |")
    L.append("")
    print("  por codigo listo", file=sys.stderr)

    L.append("## Cómo leerlo\n")
    L.append("- **E[R]** es lo que se gana por operación en unidades de riesgo; "
             "**E[$]** es lo mismo en dinero con el riesgo pedido.")
    L.append("- Un buen **% de acierto** con E[R] negativo es una estrategia que pierde: "
             "el TP de 1.5R necesita acertar ~40 % para empatar.")
    L.append("- **TL**: si `sin TL` gana, cortar por reloj solo empeora.")
    L.append("- **DD %** es la peor caída desde un máximo de capital. Con 200 USD y 3 de "
             "riesgo, un 20 % son 40 USD.")
    L.append("- `n` menor de 30 no decide nada. El informe no modela spread variable ni "
             "swaps: descuenta un coste fijo en ATR (`--cost-atr`).")
    L.append("- El dinero se aplica **secuencialmente** (cada resultado al capital) sin "
             "comprobar margen; con 3 USD de riesgo y 200 de capital no hay peligro de "
             "quedarse sin margen, pero no es una simulación de cartera.")
    L.append("- El TL que gana se elige **después** de ver los resultados: es una pista, "
             "no una garantía.")

    with open(args.salida, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print(f"informe: {args.salida} ({len(senales)} senales)")


if __name__ == "__main__":
    main()
