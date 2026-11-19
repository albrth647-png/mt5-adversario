# Backtest del EA (MT5 Strategy Tester → CSV → Python)

Un pase de MT5, todos los cálculos después en Python. Así se barre SL, TP y TL
sin volver a correr el tester.

## Cómo se lanza

**GitHub Actions → «MT5 backtest» → Run workflow.**

| Campo | Ejemplo | Nota |
|---|---|---|
| `simbolos` | `SFX Vol 20` | una o varias separadas por coma |
| `periodos` | `M3` | basta uno: el EA escribe las 4 TF en el mismo pase |
| `desde` / `hasta` | `2026.08.01` | vacíos = últimos 90 días |

En local, con MT5 instalado y el EA compilado:

```powershell
$env:MT5_LOGIN='...'; $env:MT5_PASSWORD='...'; $env:MT5_SERVER='...'
.\mt5-ea\scripts\bt.ps1 -Simbolo 'SFX Vol 20' -Periodo M3 -Desde 2026.08.01 -Hasta 2026.11.19
python3 bt\analizar_bt.py --entrada bt_out --salida reporte_bt.md
```

## Qué produce

| Archivo | Contenido |
|---|---|
| `senales.csv` | `id;time;symbol;tf;code;dir;entry;stop;atr;tipo;h1` — una fila por señal emitida |
| `barras_<TF>.csv` | `time;open;high;low;close` — el camino del precio |
| `reporte_bt.md` | TL × SL, por código y por código/TF |

## Las tres reglas del análisis

- **SL amplio**: `max(distancia al stop estructural, 2.0 ATR)`. No en la punta exacta.
- **TP**: `1.5 R` (R = la distancia del SL).
- **TL**: barrido `sin límite, 8, 16, 24, 48, 96, 192` velas. El informe dice cuál aguanta.

Empate en la misma vela: cuenta el **SL** (conservador). Coste: `0.10 ATR` por
operación, ajustable con `--cost-atr`.

## Lo que hay que saber antes de creer el resultado

1. **El tester no avisa si le pides más historia de la que hay.** `bt.ps1` imprime
   la cobertura real y el informe la repite en «Cobertura de historia».
2. **`Model=1` (OHLC de M1)**: los índices sintéticos no tienen ticks reales.
   El EA solo usa velas cerradas, así que el modelo es suficiente — pero no
   modela el orden intra-vela, por eso el empate se resuelve contra nosotros.
3. **Ventana de cálculo `InpBtVentana = 600` velas** por vela cerrada. El EMA100
   ya está convergido ahí; con 3000 el pase sería ~5× más lento para nada.
4. **Sin spread variable ni swaps**: se descuenta un coste fijo en ATR.
5. `n < 30` no decide nada.

## Piezas

| Archivo | Qué hace |
|---|---|
| `mt5-ea/scripts/bt.ps1` | escribe `bt.ini`, lanza el tester, recoge los CSV |
| `bt/analizar_bt.py` | simula SL/TP/TL y escribe el informe |
| `.github/workflows/mt5-backtest.yml` | matriz símbolo × TF + informe |
| EA, bloque `BACKTEST` | escribe `senales.csv` y `barras_*.csv` con `FILE_COMMON` |
