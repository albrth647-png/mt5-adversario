"""Exporta velas de MT5 a CSV compatible con replay/replay.html.

Se ejecuta en el runner de Windows de GitHub Actions, con el terminal MT5 ya
instalado. Usa el paquete oficial MetaTrader5 (no necesita compilar nada).

Variables de entorno:
  SYM    simbolo (por defecto "FX Vol 20")
  TFS    temporalidades separadas por coma (M1,M3,M5,M15,M30,H1,H4)
  YEARS  anos hacia atras si no se dan fechas (por defecto 2)
  DESDE  fecha inicial YYYY.MM.DD (opcional)
  HASTA  fecha final YYYY.MM.DD (opcional, por defecto ahora)

Salida: datos_out/<SIMBOLO>_<TF>.csv con cabecera
Date;Open;High;Low;Close;Volume y fecha "YYYY.MM.DD HH:MM".
"""

import csv
import datetime as dt
import os
import sys
import time

try:
    import MetaTrader5 as mt5
except ImportError:
    print("Falta el paquete MetaTrader5 (pip install MetaTrader5)")
    sys.exit(1)

SYMBOL = os.environ.get("SYM", "FX Vol 20").strip()
TFS = [t.strip().upper() for t in os.environ.get("TFS", "M1,M3,M5,M15,M30,H1,H4").split(",") if t.strip()]
YEARS = float(os.environ.get("YEARS", "2") or 2)
DESDE = os.environ.get("DESDE", "").strip()
HASTA = os.environ.get("HASTA", "").strip()
OUT = "datos_out"

TF_MAP = {
    "M1": mt5.TIMEFRAME_M1,
    "M3": mt5.TIMEFRAME_M3,
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}


def parse_fecha(texto):
    for fmt in ("%Y.%m.%d", "%Y-%m-%d", "%d.%m.%Y", "%d/%m/%Y"):
        try:
            return dt.datetime.strptime(texto, fmt)
        except ValueError:
            continue
    raise SystemExit(f"Fecha no válida: {texto}")


def ruta_terminal():
    """El paquete no siempre encuentra el terminal: hay que darle la ruta."""
    candidatos = [
        os.environ.get("MT5_PATH", ""),
        os.path.join(os.environ.get("MT5_DIR", r"C:\Program Files\MetaTrader 5"), "terminal64.exe"),
        r"C:\Program Files\MetaTrader 5\terminal64.exe",
        r"C:\Program Files (x86)\MetaTrader 5\terminal64.exe",
    ]
    for base in (r"C:\Program Files", r"C:\Program Files (x86)"):
        if os.path.isdir(base):
            for name in os.listdir(base):
                if "metatrader" in name.lower():
                    candidatos.append(os.path.join(base, name, "terminal64.exe"))
            for exe in ("terminal64.exe",):
                p = os.path.join(base, exe)
                if os.path.exists(p):
                    candidatos.append(p)
    for c in candidatos:
        if c and os.path.exists(c):
            return c
    return ""


def conectar():
    login = os.environ.get("MT5_LOGIN", "").strip()
    password = os.environ.get("MT5_PASSWORD", "")
    server = os.environ.get("MT5_SERVER", "").strip()
    terminal = ruta_terminal()

    print(f"Terminal: {terminal or '(ruta por defecto del paquete)'}")
    args = {"login": int(login), "password": password, "server": server, "timeout": 180000} \
        if (login and password and server) else {"timeout": 180000}

    ok = False
    if terminal:
        ok = mt5.initialize(terminal, **args)
    if not ok:
        print("Reintento sin ruta explícita:", mt5.last_error())
        ok = mt5.initialize(**args)

    if not ok:
        print("No se pudo iniciar MT5:", mt5.last_error())
        print("terminal64.exe existe:", bool(terminal) and os.path.exists(terminal))
        sys.exit(1)

    info = mt5.account_info()
    if info:
        print(f"Cuenta {info.login} · {info.server} · {info.company}")
    else:
        print("Aviso: sin account_info (puede faltar login)")


def elegir_simbolo():
    if mt5.symbol_info(SYMBOL) is None:
        print(f"El símbolo '{SYMBOL}' no existe en este broker.")
        print("Símbolos que contienen 'vol':")
        for s in mt5.symbols_get() or []:
            if "vol" in s.name.lower():
                print("  ", s.name, "|", s.description)
        sys.exit(2)

    if not mt5.symbol_select(SYMBOL, True):
        print(f"No se pudo seleccionar {SYMBOL}:", mt5.last_error())
        sys.exit(2)
    print(f"Símbolo listo: {SYMBOL}")


def velas(tf, desde, hasta):
    """Pide el rango y reintenta: MT5 descarga el histórico del servidor.

    Devuelve (rates, desde_real). Las temporalidades finas (M1/M3/M5) necesitan
    más tiempo de descarga; si el bróker no guarda tanto histórico, se recorta
    la ventana y se informa del rango realmente cubierto.
    """
    for intento in range(1, 13):
        rates = mt5.copy_rates_range(SYMBOL, tf, desde, hasta)
        if rates is not None and len(rates) > 0:
            return rates, desde
        print(f"    sin datos todavía (intento {intento}/12), esperando descarga...")
        time.sleep(15)

    for meses in (18, 12, 6, 3):
        recorte = hasta - dt.timedelta(days=int(30.5 * meses))
        print(f"    reintento con ventana de {meses} meses...")
        for _ in range(4):
            rates = mt5.copy_rates_range(SYMBOL, tf, recorte, hasta)
            if rates is not None and len(rates) > 0:
                print(f"    el bróker solo entregó desde {recorte:%Y.%m.%d}")
                return rates, recorte
            time.sleep(15)
    return None, None


def escribir(nombre_tf, rates):
    ruta = os.path.join(OUT, f"{SYMBOL.replace(' ', '_')}_{nombre_tf}.csv")
    with open(ruta, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["Date", "Open", "High", "Low", "Close", "Volume"])
        for r in rates:
            fecha = dt.datetime.utcfromtimestamp(int(r["time"])).strftime("%Y.%m.%d %H:%M")
            w.writerow([fecha, f"{r['open']:.5f}", f"{r['high']:.5f}",
                        f"{r['low']:.5f}", f"{r['close']:.5f}", int(r["tick_volume"])])
    mb = os.path.getsize(ruta) / (1024 * 1024)
    print(f"{nombre_tf}: {len(rates)} velas -> {ruta} ({mb:.1f} MB)")
    return len(rates), mb


def main():
    os.makedirs(OUT, exist_ok=True)
    conectar()
    elegir_simbolo()

    hasta = parse_fecha(HASTA) if HASTA else dt.datetime.now()
    desde = parse_fecha(DESDE) if DESDE else hasta - dt.timedelta(days=int(365.25 * YEARS))

    print(f"Rango: {desde:%Y.%m.%d} -> {hasta:%Y.%m.%d} | TFs: {', '.join(TFS)}")

    resumen = [f"símbolo: {SYMBOL}", f"rango: {desde:%Y.%m.%d} .. {hasta:%Y.%m.%d}", ""]
    total = 0
    for nombre in TFS:
        tf = TF_MAP.get(nombre)
        if tf is None:
            print(f"{nombre}: temporalidad desconocida, se omite")
            resumen.append(f"{nombre}: omitida (no soportada)")
            continue
        print(f"Descargando {nombre}...")
        rates, desde_real = velas(tf, desde, hasta)
        if rates is None:
            print(f"{nombre}: sin datos")
            resumen.append(f"{nombre}: sin datos")
            continue
        n, mb = escribir(nombre, rates)
        total += n
        cobertura = "" if desde_real == desde else f" (desde {desde_real:%Y.%m.%d})"
        resumen.append(f"{nombre}: {n} velas ({mb:.1f} MB){cobertura}")

    resumen.append(f"total velas: {total}")
    with open(os.path.join(OUT, "resumen.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(resumen) + "\n")
    print("\n".join(resumen))

    mt5.shutdown()


if __name__ == "__main__":
    main()
