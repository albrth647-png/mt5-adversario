# Motor de reglas

Implementa el **Paso 1** del plan: `reglas.json` (contrato de 8 campos) + un
motor en Node que lee los 4 CSV M1, agrega al TF de cada regla, deduplica,
resta coste y devuelve **R medio con IC95%** y desglose por hora, régimen y
partición temporal.

## El contrato de 8 campos

Cada regla es un objeto con estos 8 campos. Si falta uno, no es una regla.

| # | Campo | Qué significa | Formato en `reglas.json` |
|---|---|---|---|
| 1 | `contexto` | Filtro de régimen en un TF mayor (solo se opera si se cumple) | expresión + `tf_contexto` (o `null`) |
| 2 | `disparador` | Condición que debe cumplir la vela cerrada para disparar | expresión sobre OHLC + indicadores |
| 3 | `direccion` | `"long"` o `"short"` | literal |
| 4 | `entrada` | Precio de entrada | `"next_open"` = apertura de la vela siguiente |
| 5 | `stop` | Precio de stop | expresión (puede usar `entrada`, `low`, `atr14`...) |
| 6 | `objetivo` | Precio de objetivo | expresión (puede usar `entrada`, `stop`) |
| 7 | `caducidad` | Velas máximas en posición; si no toca nada, salir a mercado | entero |
| 8 | `vetos` | Capas de "cuándo NO entrar" | lista de `{tipo, ...}` |

Extras operativos propios del motor (no son del contrato de 8, pero son
necesarios en backtest): `id`, `descripcion`, `tf_disparo`, `dedupe_velas`.

### Expresiones

Se evalúan **por vela cerrada** con estas variables:

- OHLC: `open, high, low, close, volume, range, body`
- Vela anterior: `prev_open, prev_high, prev_low, prev_close`
- Dos velas atrás: `prev2_*`
- Indicadores: `emaN`, `smaN`, `atrN` (N = periodo; p. ej. `ema30`, `atr14`)
- En `stop`/`objetivo`: `entrada`, `stop`
- Operadores: `+ - * / < <= > >= == != && ||` y `!`
- Funciones: `min, max, abs, sqrt, floor, ceil, round`

Los indicadores se calculan **sobre el TF de la regla**. El `contexto` se
calcula sobre `tf_contexto` y se alinea al último bar de contexto **cerrado**
antes de la apertura de la vela disparadora: sin lookahead.

### Vetos implementados

- `{ "tipo": "rango_atr", "mult": 2.5 }` → veta si `range >= mult*atr`
  (vela disparadora demasiado grande).
- `{ "tipo": "hora", "desde": 22, "hasta": 1 }` → veta esa franja en **UTC**
  (soporta cruce de medianoche).
- `{ "tipo": "spread", "mult": 1.5 }` → previsto, pero **inactivo**: los CSV
  M1 no traen spread por barra. El coste se aplica globalmente (ver abajo).

## Coste

Sin columnas de spread, el coste se modela como fracción del precio en
`config`:

```json
"spread_frac": 0.0002,
"slippage_frac": 0.0001
```

`coste = precio_entrada * (spread_frac + slippage_frac)` y se resta del PnL
bruto antes de dividir por el riesgo. **Sustituir por el spread real del
broker** cuando exista; ahora mismo es una hipótesis conservadora.

## Salidas

- `salida/disparos.csv` — un disparo por fila con `R_gross` y `R_net`
  (patrón de oro para el test de equivalencia con el EA).
- `salida/resumen.json` — estadística completa por activo/regla.
- `salida/resumen.md` — tabla legible: R medio, IC95%, acierto, partición
  60/20/20, desglose por hora y por régimen.

## Uso

```bash
node motor.mjs --reglas reglas.json --datos ../datos_m1 --salida salida
```

## Partición temporal

Sobre el rango temporal de cada activo: **60% descubrimiento / 20%
validación / 20% test**. El test no se toca hasta decidir.
