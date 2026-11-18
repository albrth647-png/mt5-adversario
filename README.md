# MT5 adversario — demo → Telegram

Motor de señales corriendo **dentro de MetaTrader 5**, en un runner Windows de
GitHub Actions: entra en la cuenta demo, escanea con la escalera del vídeo 03 y
la estrategia Estructura, y **el propio EA** manda cada señal a Telegram.

No hace falta tu PC ni tu teléfono. Lanzas el workflow y trabaja en la nube.

## Qué hay

```
mt5-ea/EstrategiaAdversaria.mq5      el EA (MQL5, se compila en el runner)
.github/workflows/mt5-adversario.yml instala MT5, compila, arranca y vigila
```

Nada más. No hay dependencias, ni Node, ni Python.

## Qué calcula

Escalera de Yoel (`1`, `2`, `3`, `2B`, `3B` y sus reset `1R/2R/3R/2RB/3RB`) y
estrategia Estructura (`1E`, `2E/3E` avisos, `2EB/3EB`, `2REB/3REB`), con los
mismos parámetros que el núcleo del motor: EMA30/50/100 y ATR14 con su semilla
y recursión, toque 0,30 ATR, cuerpo 50 % y 0,10 ATR, caducidad 3, separación 2,
enfriamiento 8, impulso 0,8 ATR y retroceso 1-3 ATR.

Si las dos estrategias dan código para la misma vela y el mismo lado, sale una
sola señal: gana la de mayor prioridad (entrada > aviso, tier A > B > C).

El mensaje es el de 7 campos de siempre, y el campo 4 lleva la tendencia mayor
del motor (`· H1 ALCISTA · en tendencia`), con pivotes por cierre k=5, margen
0,25 ATR y fase contra la EMA30 de H1.

## Secrets

*Settings → Secrets and variables → Actions*.

| Nombre | Tipo | Qué es |
|---|---|---|
| `MT5_LOGIN` | secret | número de la cuenta demo |
| `MT5_PASSWORD` | secret | contraseña de la demo |
| `MT5_SERVER` | secret | nombre exacto del servidor |
| `TELEGRAM_TOKEN` | secret | token del bot |
| `TELEGRAM_CHAT` | secret | chat destino (grupo: empieza por `-100`) |
| `MT5_SYMBOLS` | variable | `FX Vol 20,FX Vol 40,SFX Vol 20,SFX Vol 40` |

El servidor y los símbolos se copian tal cual aparecen en MT5 (Observación de
mercado y la barra inferior del terminal). Si un símbolo se escribe distinto, el
EA lo busca sin espacios/puntos y lo deja anotado en el log.

## Lanzarlo

Actions → *MT5 adversario (demo -> Telegram)* → **Run workflow**.

| Entrada | Por defecto | Qué es |
|---|---|---|
| `minutos` | 240 | cuánto queda abierto el terminal (tope 330) |
| `tf` | M5 | temporalidad a escanear (M1 / M5 / M15) |

**Primera vez, con `minutos=5`.** En 3-4 minutos debe llegar a Telegram
`EA ADVERSARIO ARRANCADO` con la cuenta, los activos resueltos y el horario del
servidor. Si ese mensaje llega, la cadena entera funciona.

## Si no llega nada

El run imprime el log del terminal a los 2 minutos si el EA no escribió nada.

| En el log | Causa | Arreglo |
|---|---|---|
| `invalid account` / `authorization failed` | servidor mal escrito o demo caducada | copiar el servidor exacto |
| el EA no arranca, no abre el gráfico | el primer símbolo de `MT5_SYMBOLS` no existe en el bróker | poner uno que sí exista como primero |
| `Telegram sin configurar` / `FALLO http=400` | token o chat mal | grupo = id negativo; el bot debe estar dentro |

## Límites

- **6 h por job**; aquí 330 min por seguridad. Al terminar, el runner se
  destruye y hay que relanzar el workflow.
- El terminal tarda 1-3 min en arrancar: las velas que cierren en ese hueco no
  existen.
- **No opera.** La demo solo aporta el feed del bróker; si el broker y el motor
  discrepan, el precio bueno es el de este terminal.

## Coste

Repo **público**: los runners estándar no consumen minutos facturables. El
workflow solo se dispara a mano (`workflow_dispatch`), así que nadie más puede
lanzarlo y los secrets no se pasan a los forks.

## Logs

Cada run deja el artifact `mt5-adversario-logs` con `adv.log` (señales y
latidos), `adv_enviados.txt` (antiduplicado) y los logs del terminal.
