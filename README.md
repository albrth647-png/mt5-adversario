# MT5 adversario — demo → Telegram

Motor de señales corriendo **dentro de MetaTrader 5**, en un runner Windows de
GitHub Actions: entra en la cuenta demo, escanea con la escalera del vídeo 03 y
la estrategia Estructura, y **el propio EA** manda cada señal a Telegram.

No hace falta tu PC ni tu teléfono. Lanzas el workflow y trabaja en la nube.

## Qué hay

```
mt5-ea/EstrategiaAdversaria.mq5          el EA (MQL5, se compila en el runner)
mt5-ea/scripts/instalar_mt5.ps1          instala el terminal y compila
mt5-ea/scripts/ejecutar_ea.ps1           configura la cuenta, arranca y vigila
mt5-ea/scripts/panel_web.ps1             arranca el panel y abre el túnel
panel/panel.mjs                          servidor del panel (Node, sin deps)
panel/index.html                         la web: velas, EMAs, señales y log
.github/workflows/mt5-adversario.yml     llama a los scripts
```

Toda la lógica está en los scripts: el workflow solo los ejecuta.

## Panel en vivo (móvil)

Al lanzar el workflow, además del EA arranca un panel web y un túnel rápido de
Cloudflare. **El enlace llega a tu Telegram** y se abre desde el móvil:

- **la gráfica real de MT5** (captura del terminal con `ChartScreenShot`, tal
  como la pinta MT5, no una reconstrucción);
- velas con EMA30/50/100 y la tendencia por símbolo y temporalidad (al tocar un
  par se pasa a la vista de datos de ese par);
- las señales que salieron;
- el `adv.log` completo en vivo (`[FILTRO]`, `[CONF]`, `[CAMBIO]`, `[EMBUDO]`)
  para ver **por qué** no saltó una señal.

### También en GitHub, sin túnel

Cada 5 minutos el script copia la captura real (`panel_chart.png`) y el estado a
una rama **`live`** del repo. Así puedes abrir en el móvil, sin depender del
túnel ni de que la corrida siga viva:

```
https://github.com/<usuario>/<repo>/blob/live/panel_chart.png?raw=true
```

El primer enlace de GitHub también llega a tu Telegram. La rama `live` se
reescribe en cada publicación (un solo commit).

El EA escribe `MQL5/Files/panel_estado.json` una vez por vela M3; el panel solo
lee ese archivo y el log, no calcula ni decide nada. La página se refresca por
polling cada 2 s porque el túnel rápido de Cloudflare no soporta SSE.

Límites: la URL (`algo-random.trycloudflare.com`) cambia en cada corrida y
muere cuando la corrida termina. El enlace lleva una clave aleatoria (`?k=`)
porque el túnel es público. Con `panel: no` el workflow corre sin panel.

## Cómo sale el mensaje

Dos capas, para que una señal no se pierda nunca:

1. **El EA envía** con `WebRequest` a `api.telegram.org`.
2. Si MetaTrader bloquea la salida (`http=-1 error=4014`, la URL no está en su
   lista blanca y en modo headless no hay forma fiable de meterla), el EA deja
   el mensaje en `MQL5/Files/adv_pendientes.txt` y `ejecutar_ea.ps1` lo entrega
   con `Invoke-RestMethod` al mismo bot y mismo chat. El log del run muestra
   `Telegram ok: msg <id> -> chat <id>`.

El texto que llega es el mismo en los dos caminos, y el antiduplicado no cambia.

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
| `FALLO http=-1 error=4014` | MT5 no deja salir a `WebRequest` | no es un fallo: el script entrega el mensaje; mira `Telegram ok: msg …` en el log |

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
