//+------------------------------------------------------------------+
//| EstrategiaAdversaria.mq5                                         |
//| EA adversario para cuenta DEMO en MT5 (Windows / GitHub Actions) |
//|                                                                  |
//| Dos estrategias independientes: cada una manda su propia senal     |
//| por vela y lado (pueden coincidir en la misma vela):               |
//|   HCH   hombro-cabeza-hombro bajista  (VENTA)                    |
//|   HCHi  hombro-cabeza-hombro invertido (COMPRA)                  |
//|   LIQ   barrido de liquidez: la mecha perfora un swing, vuelve a |
//|         cerrar dentro y el precio rebota 1,5 ATR                 |
//|                                                                  |
//| Temporalidades por defecto: M1, M3, M5, M15 y H1 (adv.cfg: tfs=).  |
//| No opera: lee velas y manda la senal a Telegram por WebRequest.  |
//| La cuenta demo solo se usa para tener el feed del broker real.   |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "HCH + barrido de liquidez sobre la cuenta DEMO; senal a Telegram."

//--------------------------------------------------------------------
//  Configuracion: se lee de  <datos>/MQL5/Files/adv.cfg
//--------------------------------------------------------------------
string g_tgToken   = "";
string g_tgChat    = "";
string g_simbolos  = "FX Vol 20,FX Vol 40,SFX Vol 20,SFX Vol 40";
string g_tfTxt     = "M5";
string g_tfs       = "M1,M3,M5,M15,H1";   // temporalidades que escanea el EA
int    g_velas     = 3000;
int    g_latidoMin = 15;
int    g_enviarPrecios = 0;   // 1 = enviar snapshot de precios a Telegram en cada latido

// Multi-TF: el EA procesa estas temporalidades en un solo terminal
string           g_tfTxtArr[];
ENUM_TIMEFRAMES  g_tfArr[];
int              g_nTf      = 5;
int              g_iRef     = 0;   // indice de la TF de referencia (M5 si esta)
ENUM_TIMEFRAMES  g_tf      = PERIOD_M5;

//--------------------------------------------------------------------
//  Parametros base: EMAs y ATR (las EMAs solo etiquetan la tendencia)
//--------------------------------------------------------------------
int    P_emaContacto       = 30;
int    P_emaTecho          = 50;
int    P_emaFondo          = 100;
int    P_atrPeriodo        = 14;
//--------------------------------------------------------------------
//  Estrategia HCH (Hombro-Cabeza-Hombro): parametros del indicador
//  HombroCabezaHombro.mq5, con sus mismos valores por defecto.
//--------------------------------------------------------------------
int    P_hchAtrPeriodo    = 14;     // periodo del ATR
double P_hchZZAtr         = 2.0;    // umbral del zigzag (x ATR)
int    P_hchLookback      = 1500;   // velas analizadas
double P_hchMinScore      = 75.0;   // puntuacion minima (0-100)
double P_hchMinPatronAtr  = 2.5;    // altura minima del patron (x ATR)
double P_hchMinCabeza     = 0.10;   // cabeza sobre hombros (fraccion)
double P_hchTolHombros    = 0.40;   // asimetria maxima de hombros
double P_hchMinTiempo     = 0.35;   // simetria temporal minima
double P_hchTolCuello     = 0.60;   // inclinacion maxima del cuello
double P_hchMinHombroFrac = 0.20;   // hombro minimo / cabeza
int    P_hchMinVelas      = 12;     // velas minimas del patron
int    P_hchMaxVelas      = 250;    // velas maximas del patron
int    P_hchVelasTend     = 30;     // velas para la tendencia previa
double P_hchTendAtr       = 4.0;    // tendencia previa ideal (x ATR)
double P_hchBufRuptura    = 0.15;   // margen de ruptura del cuello (x ATR)
int    P_hchMaxEspera     = 40;     // velas maximas para romper el cuello
bool   P_hchStopCabeza    = false;  // false = stop tras el hombro derecho
double P_hchBufStop       = 0.25;   // margen del stop (x ATR)

//--------------------------------------------------------------------
//  Estrategia BARRIDO DE LIQUIDEZ: parametros del indicador
//  BarridoLiquidez.mq5, con sus mismos valores por defecto.
//--------------------------------------------------------------------
int    P_liqSwing         = 5;      // velas a cada lado de un swing
int    P_liqAtrPeriodo    = 14;     // periodo del ATR
double P_liqAtrTope       = 3.00;   // tope de un TR anomalo (x ATR); 0 = sin tope
int    P_liqMaxEdadNivel  = 400;    // antiguedad maxima de un nivel (velas)
double P_liqMinPerfora    = 0.10;   // perforacion minima del nivel (x ATR)
double P_liqMaxPerfora    = 3.00;   // perforacion maxima; mas es ruptura (x ATR)
int    P_liqMaxBarrido    = 4;      // velas maximas del barrido
double P_liqMechaMin      = 0.40;   // mecha minima / rango de la vela
double P_liqMechaAtr      = 0.30;   // mecha minima (x ATR)
double P_liqReboteAtr     = 1.50;   // rebote minimo desde el extremo (x ATR)
int    P_liqReboteVelas   = 10;     // velas maximas para el rebote
double P_liqBufRuptura    = 0.10;   // margen para dar la zona por rota (x ATR)
bool   P_liqColorContra   = true;   // la vela del extremo debe ser de color contrario
bool   P_liqAlcista       = true;   // barrido de minimos (esperando subida)
bool   P_liqBajista       = true;   // barrido de maximos (esperando bajada)

//--------------------------------------------------------------------
//  Modo backtest (Strategy Tester / GitHub Actions)
//  En el tester no hay timer ni Telegram. El EA recorre las velas con
//  OnTick, escribe la senal de cada vela cerrada y las barras usadas, y
//  el analisis (SL amplio / TP 1.5R / TL) lo hace Python sobre esos CSV.
//  Asi UN pase de MT5 sirve para barrer todos los TP y TL sin repetir
//  la prueba: el camino del precio ya esta en el archivo.
//--------------------------------------------------------------------
bool   InpBacktest   = false;   // forzar modo backtest (el tester lo activa solo)
string InpBtCarpeta  = "bt";    // subcarpeta en la carpeta COMUN de MT5
bool   InpBtBarras   = true;    // exportar barras (necesario para simular SL/TP)
int    InpBtVentana  = 1600;    // velas de calculo por vela cerrada (HCH mira 1500)
bool   InpBtLog      = false;   // escribir el log completo (muy lento en backtest)

bool     g_bt = false;
int      g_btHsen = INVALID_HANDLE;
int      g_btHbar[8];
datetime g_btUltBarra[8];
int      g_btEventos = 0;

datetime g_ultimoLatido = 0;
int      g_barraActual   = -1;   // solo se loguean los bloqueos de la vela actual
int      g_tfIdx         = 0;    // temporalidad en curso (0..3), para el embudo

//--------------------------------------------------------------------
//  Embudo por temporalidad: cuantos candidatos mueren en cada puerta de
//  la vela cerrada. Se acumula y se imprime una vez por vela M3 cerrada.
//  Sin esto el log solo enseña los patrones que llegaron a la ultima
//  puerta; el resto desaparece sin rastro.
//     patrones = completos + invalidados + expirados + rotos + emite
//--------------------------------------------------------------------
struct Emb
  {
   int patrones;     // ventanas de 5 pivotes evaluadas
   int completos;    // candidatos que pasan reglas duras + score
   int rotos;        // ruptura en una vela anterior (no se emite)
   int invalidados;  // superaron la cabeza antes de romper
   int expirados;    // no rompieron el cuello a tiempo
   int emitidos;     // senales HCH emitidas en la vela cerrada
   int liqNiveles;   // swings evaluados como nivel de liquidez
   int liqEmite;     // barridos con rebote confirmado en la vela cerrada
  };
Emb      g_emb[8];
datetime g_embBar = 0;
datetime g_panelBar = 0;   // ultima vela M3 volcada al panel web

void EmbLog()
  {
   int nt = ArraySize(g_tfTxtArr);
   if(nt > 8)
      nt = 8;
   for(int k = 0; k < nt; k++)
     {
      Emb e = g_emb[k];
      if(e.patrones + e.completos + e.rotos + e.invalidados + e.expirados + e.emitidos
         + e.liqNiveles + e.liqEmite == 0)
         continue;
      string tf = IntegerToString(k);
      if(k < nt)
         tf = g_tfTxtArr[k];
      Log("[EMBUDO] " + tf
          + " HCH{patrones=" + IntegerToString(e.patrones)
          + " completos=" + IntegerToString(e.completos)
          + " rotos=" + IntegerToString(e.rotos)
          + " invalidados=" + IntegerToString(e.invalidados)
          + " expirados=" + IntegerToString(e.expirados)
          + " emite=" + IntegerToString(e.emitidos) + "}"
          + " LIQ{niveles=" + IntegerToString(e.liqNiveles)
          + " emite=" + IntegerToString(e.liqEmite) + "}");
     }
   for(int k = 0; k < 8; k++)
      ZeroMemory(g_emb[k]);
  }

//--------------------------------------------------------------------
//  Estructuras
//--------------------------------------------------------------------
struct Evento
  {
   int    bar;
   string lado;
   string patron;
   double precio;
   double invalida;
   double nivel;
   double score;
   int    prio;      // 2 = barrido de liquidez, 1 = HCH
   string tendencia;
  };

//--------------------------------------------------------------------
//  Utilidades
//--------------------------------------------------------------------
void Log(const string msg)
  {
   // en backtest cada vela escribiria 4 lineas: 86k velas x 4 TF = cientos de
   // MB de log y la prueba se va en disco. Se apaga salvo InpBtLog.
   if(g_bt && !InpBtLog)
      return;
   string linea = TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS) + " " + msg;
   Print(linea);
   int h = FileOpen("adv.log", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h != INVALID_HANDLE)
     {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, linea);
      FileClose(h);
     }
  }

string Normalizar(const string s)
  {
   string o = "";
   int n = StringLen(s);
   for(int i=0; i<n; i++)
     {
      ushort ch = StringGetCharacter(s, i);
      if(ch==' ' || ch=='.' || ch=='-' || ch=='_' || ch=='/' || ch=='*')
         continue;
      if(ch>='A' && ch<='Z')
         ch = (ushort)(ch + 32);
      o = o + ShortToString(ch);
     }
   return o;
  }

// El nombre del simbolo en este broker puede no coincidir letra a letra
// con el del catalogo: se prueba exacto y, si falla, por nombre normalizado.
string ResolverSimbolo(const string pedido)
  {
   if(StringLen(pedido) == 0)
      return "";
   if(SymbolSelect(pedido, true) && SymbolInfoDouble(pedido, SYMBOL_BID) > 0)
      return pedido;
   string objetivo = Normalizar(pedido);
   int total = SymbolsTotal(false);
   for(int i=0; i<total; i++)
     {
      string s = SymbolName(i, false);
      if(Normalizar(s) == objetivo)
        {
         if(SymbolSelect(s, true))
            return s;
        }
     }
   for(int i=0; i<total; i++)
     {
      string s = SymbolName(i, false);
      if(StringFind(Normalizar(s), objetivo) >= 0)
        {
         if(SymbolSelect(s, true))
            return s;
        }
     }
   return "";
  }

string FmtPrecio(const double v)
  {
   if(!(v > 0))
      return "-";
   string s = DoubleToString(v, 5);
   int n = StringLen(s);
   while(n > 0 && StringGetCharacter(s, n-1) == '0')
     {
      s = StringSubstr(s, 0, n-1);
      n--;
     }
   if(n > 0 && StringGetCharacter(s, n-1) == '.')
      s = StringSubstr(s, 0, n-1);
   return s;
  }

// 🟢 y 🔴 sin depender de la codificacion del fuente
string Icono(const bool compra)
  {
   return ShortToString((ushort)0xD83D) + ShortToString((ushort)(compra ? 0xDFE2 : 0xDD34));
  }

string TendenciaTxt(const string t)
  {
   if(t == "ALCISTA")
      return "ALCISTA (EMA30 &gt; EMA50 &gt; EMA100)";
   if(t == "BAJISTA")
      return "BAJISTA (EMA30 &lt; EMA50 &lt; EMA100)";
   return "LATERAL (precio y EMAs no alineados)";
  }

//--------------------------------------------------------------------
//  Hora de La Habana  (UTC-5, UTC-4 en horario de verano)
//--------------------------------------------------------------------
datetime PrimerDomingo(const int anio, const int mes)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = anio;
   s.mon  = mes;
   s.day  = 1;
   datetime t = StructToTime(s);
   MqlDateTime c;
   TimeToStruct(t, c);
   s.day = 1 + ((7 - c.day_of_week) % 7);
   return StructToTime(s);
  }

int OffsetHabana(const datetime tUTC)
  {
   MqlDateTime c;
   TimeToStruct(tUTC, c);
   // empieza el 2o domingo de marzo a las 00:00 locales (05:00 UTC) y acaba
   // el 1er domingo de noviembre a la 01:00 local (05:00 UTC)
   datetime ini = PrimerDomingo(c.year, 3)  + 7 * 86400 + 5 * 3600;
   datetime fin = PrimerDomingo(c.year, 11) + 5 * 3600;
   return (tUTC >= ini && tUTC < fin) ? -4 : -5;
  }

string HoraHabana(const datetime tUTC)
  {
   datetime h = (datetime)((long)tUTC + (long)OffsetHabana(tUTC) * 3600);
   return TimeToString(h, TIME_DATE|TIME_MINUTES);
  }

//--------------------------------------------------------------------
//  Telegram
//--------------------------------------------------------------------
string EscJson(const string s)
  {
   string o = "";
   int n = StringLen(s);
   for(int i=0; i<n; i++)
     {
      ushort ch = StringGetCharacter(s, i);
      if(ch == '"')
         o = o + "\\\"";
      else if(ch == '\\')
         o = o + "\\\\";
      else if(ch == '\n')
         o = o + "\\n";
      else if(ch == '\r')
         continue;
      else
         o = o + ShortToString(ch);
     }
   return o;
  }

bool EnviarTelegram(const string texto)
  {
   if(g_tgToken == "" || g_tgChat == "")
     {
      Log("Telegram sin configurar (.cfg sin token/chat): no se envia");
      return false;
     }
   string url = "https://api.telegram.org/bot" + g_tgToken + "/sendMessage";
   string cuerpo = "{\"chat_id\":\"" + EscJson(g_tgChat)
                   + "\",\"text\":\"" + EscJson(texto)
                   + "\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}";
   char utf8[];
   // WHOLE_ARRAY: count es bytes en el array destino, no caracteres del origen;
   // con StringLen(cuerpo) se truncaba el JSON cuando el texto lleva ó/emoji/·.
   StringToCharArray(cuerpo, utf8, 0, WHOLE_ARRAY, CP_UTF8);
   int largo = ArraySize(utf8) - 1;    // sin el 0 final
   if(largo <= 0)
      return false;
   // WebRequest pide uchar[], no char[]
   uchar datos[], respuesta[];
   ArrayResize(datos, largo);
   for(int i = 0; i < largo; i++)
      datos[i] = (uchar)utf8[i];
   string cabeceras = "";
   ResetLastError();
   int code = WebRequest("POST", url, "", "", 8000, datos, largo, respuesta, cabeceras);
   if(code == 200)
     {
      Log("Telegram: enviado (" + IntegerToString(largo) + " bytes)");
      return true;
     }
   int fallo = GetLastError();
   string respTxt = "";
   if(ArraySize(respuesta) > 0)
      respTxt = CharArrayToString(respuesta, 0, WHOLE_ARRAY, CP_UTF8);
   Log(StringFormat("Telegram: FALLO http=%d error=%d -> queda en pend_*.txt | resp: %s", code, fallo, respTxt));
   // Si el mensaje queda encolado, el runner lo entrega en <=15 s: para el EA
   // cuenta como enviado. Antes se devolvia false y, con el terminal bloqueado
   // (4014 en el 100% de los envios), el contador del latido nunca sumaba y el
   // antiduplicado no se marcaba aunque la senal si llegaba a Telegram.
   return GuardarPendiente(texto);
  }

// Si MT5 no deja salir a WebRequest (error 4014: URL no autorizada), el mensaje
// se guarda en un archivo propio (uno por mensaje) y el runner del workflow lo
// manda tal cual. Un archivo por mensaje evita carreras de lectura/escritura
// y hace la entrega fiable.
int g_pendienteSeq = 0;
bool GuardarPendiente(const string texto)
  {
   g_pendienteSeq++;
   // Nombre unico: tickcount ms + contador, para que dos mensajes nunca
   // sobrescriban el mismo archivo (evita perdida de senales).
   string nombre = "pend_" + IntegerToString(GetTickCount()) + "_" + IntegerToString(g_pendienteSeq) + ".txt";
   int h = FileOpen(nombre, FILE_WRITE|FILE_TXT|FILE_UNICODE);
   if(h == INVALID_HANDLE)
     {
      Log("no puedo abrir " + nombre + " (error " + IntegerToString(GetLastError()) + ")");
      return false;
     }
   FileWrite(h, texto);
   FileClose(h);
   Log("mensaje guardado en " + nombre + " (pendiente de entrega)");
   return true;
  }

//--------------------------------------------------------------------
//  Configuracion
//--------------------------------------------------------------------
ENUM_TIMEFRAMES TfDeTexto(const string txt)
  {
   string u = txt;
   StringToUpper(u);
   if(u == "M1")  return PERIOD_M1;
   if(u == "M3")  return PERIOD_M3;
   if(u == "M5")  return PERIOD_M5;
   if(u == "M15") return PERIOD_M15;
   if(u == "M30") return PERIOD_M30;
   if(u == "H1")  return PERIOD_H1;
   if(u == "H4")  return PERIOD_H4;
   if(u == "D1")  return PERIOD_D1;
   return PERIOD_M5;
  }

bool CargarCfg(const string archivo)
  {
   int h = FileOpen(archivo, FILE_READ|FILE_TXT|FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      Log("No puedo abrir MQL5/Files/" + archivo + " (error " + IntegerToString(GetLastError()) + ")");
      return false;
     }
   while(!FileIsEnding(h))
     {
      string l = FileReadString(h);
      int p = StringFind(l, "=");
      if(p <= 0)
         continue;
      string k = StringSubstr(l, 0, p);
      string v = StringSubstr(l, p + 1);
      StringTrimLeft(k);
      StringTrimRight(k);
      StringTrimLeft(v);
      StringTrimRight(v);
      if(k == "token")
         g_tgToken = v;
      else if(k == "chat")
         g_tgChat = v;
      else if(k == "simbolos")
         g_simbolos = v;
      else if(k == "velas")
         g_velas = (int)StringToInteger(v);
      else if(k == "latido")
         g_latidoMin = (int)StringToInteger(v);
      else if(k == "precios")
         g_enviarPrecios = (int)StringToInteger(v);
      else if(k == "tfs")
         g_tfs = v;
     }
   FileClose(h);
   return true;
  }

//--------------------------------------------------------------------
//  Indicadores (misma semilla y recursion que nucleo.js)
//--------------------------------------------------------------------
void CalcEma(const double &src[], const int periodo, double &out[])
  {
   int n = ArraySize(src);
   ArrayResize(out, n);
   ArrayInitialize(out, 0.0);
   if(n < periodo)
      return;
   double suma = 0;
   for(int i=0; i<periodo; i++)
      suma += src[i];
   out[periodo-1] = suma / periodo;
   double k = 2.0 / (periodo + 1);
   for(int i=periodo; i<n; i++)
      out[i] = src[i] * k + out[i-1] * (1 - k);
  }

void CalcAtr(const MqlRates &r[], const int periodo, double &out[])
  {
   int n = ArraySize(r);
   ArrayResize(out, n);
   ArrayInitialize(out, 0.0);
   if(n < periodo + 1)
      return;
   double tr[];
   ArrayResize(tr, n);
   for(int i=0; i<n; i++)
     {
      if(i == 0)
        {
         tr[i] = r[i].high - r[i].low;
         continue;
        }
      double pc = r[i-1].close;
      double a  = r[i].high - r[i].low;
      double b  = MathAbs(r[i].high - pc);
      double c  = MathAbs(r[i].low  - pc);
      tr[i] = MathMax(a, MathMax(b, c));
     }
   double suma = 0;
   for(int i=1; i<=periodo; i++)
      suma += tr[i];
   out[periodo] = suma / periodo;
   for(int i=periodo+1; i<n; i++)
      out[i] = (out[i-1] * (periodo - 1) + tr[i]) / periodo;
  }

string Tendencia(const double cierre, const double e30, const double e50, const double e100)
  {
   if(!(e30 > 0) || !(e50 > 0) || !(e100 > 0))
      return "LATERAL";
   if(cierre > e30 && e30 >= e50 && e50 >= e100)
      return "ALCISTA";
   if(cierre < e30 && e30 <= e50 && e50 <= e100)
      return "BAJISTA";
   return "LATERAL";
  }

//--------------------------------------------------------------------
//  Estrategia HCH (Hombro-Cabeza-Hombro)
//  Port del indicador HombroCabezaHombro.mq5: pivotes zigzag 2xATR,
//  reglas duras, puntuacion difusa 0..100 y ruptura del cuello.
//  Todo se evalua sobre velas CERRADAS (r[] es historico cerrado).
//--------------------------------------------------------------------
#define HCH_TMPL 40

struct HPivote
  {
   int    idx;      // indice en r[]
   double precio;
   int    tipo;     // +1 techo, -1 suelo
  };

struct HPatron
  {
   int    dir;        // +1 bajista (techos), -1 invertido (suelos)
   int    ix[5];      // HI, valle1, cabeza, valle2, HD
   double px[5];
   double score;
   double cabezaH;    // altura cabeza-cuello
  };

double HchClamp(const double x)
  {
   if(x < 0.0)
      return 0.0;
   if(x > 1.0)
      return 1.0;
   return x;
  }

double HchAtrAt(const double &atr[], const int desde, const int hasta, const int j)
  {
   int k = j;
   if(k < desde)
      k = desde;
   if(k > hasta)
      k = hasta;
   return MathMax(atr[k], _Point);
  }

// Misma semilla y recursion que ComputeATR del indicador.
void HchAtr(const MqlRates &r[], const int desde, const int hasta, double &atr[])
  {
   ArrayResize(atr, hasta + 1);
   ArrayInitialize(atr, 0.0);
   double a = 0.0;
   for(int k = desde; k <= hasta; k++)
     {
      double tr = r[k].high - r[k].low;
      if(k > 0)
         tr = MathMax(tr, MathMax(MathAbs(r[k].high - r[k-1].close),
                                  MathAbs(r[k].low  - r[k-1].close)));
      int n = k - desde;
      if(n == 0)
         a = tr;
      else if(n < P_hchAtrPeriodo)
         a = (a * n + tr) / (n + 1);
      else
         a = (a * (P_hchAtrPeriodo - 1) + tr) / P_hchAtrPeriodo;
      atr[k] = a;
     }
  }

void HchAddPivote(HPivote &piv[], int &n, const int idx, const double precio, const int tipo)
  {
   if(n > 0 && piv[n-1].tipo == tipo)
      return;
   ArrayResize(piv, n + 1, 256);
   piv[n].idx    = idx;
   piv[n].precio = precio;
   piv[n].tipo   = tipo;
   n++;
  }

// Zigzag con umbral en ATR (igual que BuildPivots).
void HchPivotes(const MqlRates &r[], const int s, const int e,
                const double &atr[], const int atrDesde, const int atrHasta,
                HPivote &piv[], int &nPiv)
  {
   nPiv = 0;
   ArrayResize(piv, 0);
   int    dir  = 0;
   double hiP  = r[s].high, loP = r[s].low;
   int    hiI  = s, loI = s;
   double extP = 0.0;
   int    extI = s;

   for(int i = s + 1; i <= e; i++)
     {
      double thr = P_hchZZAtr * HchAtrAt(atr, atrDesde, atrHasta, i);

      if(dir == 0)
        {
         if(r[i].high > hiP) { hiP = r[i].high; hiI = i; }
         if(r[i].low  < loP) { loP = r[i].low;  loI = i; }
         if(hiP - loP >= thr)
           {
            if(loI < hiI)      { HchAddPivote(piv, nPiv, loI, loP, -1); dir = 1;  extP = hiP; extI = hiI; }
            else if(hiI < loI) { HchAddPivote(piv, nPiv, hiI, hiP, +1); dir = -1; extP = loP; extI = loI; }
           }
        }
      else if(dir == 1)
        {
         if(r[i].high > extP)
           { extP = r[i].high; extI = i; }
         else if(extP - r[i].low >= thr)
           { HchAddPivote(piv, nPiv, extI, extP, +1); dir = -1; extP = r[i].low; extI = i; }
        }
      else
        {
         if(r[i].low < extP)
           { extP = r[i].low; extI = i; }
         else if(r[i].high - extP >= thr)
           { HchAddPivote(piv, nPiv, extI, extP, -1); dir = 1; extP = r[i].high; extI = i; }
        }
     }
  }

// Precio del cuello (recta valle1-valle2) en la vela x.
double HchCuello(const HPatron &p, const int x)
  {
   double dx = (double)(p.ix[3] - p.ix[1]);
   if(dx <= 0.0)
      return p.px[3];
   return p.px[1] + (p.px[3] - p.px[1]) * ((double)(x - p.ix[1])) / dx;
  }

// Forma ideal normalizada: HI 0.55 - valle 0 - cabeza 1 - valle 0 - HD 0.55
double HchPlantilla(const double t)
  {
   if(t <= 0.25)
      return 0.55 * (1.0 - t / 0.25);
   if(t <= 0.50)
      return (t - 0.25) / 0.25;
   if(t <= 0.75)
      return 1.0 - (t - 0.50) / 0.25;
   return 0.55 * (t - 0.75) / 0.25;
  }

// Correlacion de Pearson entre el recorrido real y la plantilla.
double HchScorePlantilla(const MqlRates &r[], const int dir, const int i0, const int i4)
  {
   double x[HCH_TMPL], y[HCH_TMPL];
   double mx = 0.0, my = 0.0;

   for(int k = 0; k < HCH_TMPL; k++)
     {
      double t   = (double)k / (double)(HCH_TMPL - 1);
      int    idx = i0 + (int)MathRound(t * (double)(i4 - i0));
      if(idx < i0) idx = i0;
      if(idx > i4) idx = i4;
      x[k] = dir * r[idx].close;
      y[k] = HchPlantilla(t);
      mx += x[k];
      my += y[k];
     }
   mx /= HCH_TMPL;
   my /= HCH_TMPL;

   double sxx = 0.0, syy = 0.0, sxy = 0.0;
   for(int k = 0; k < HCH_TMPL; k++)
     {
      double dx = x[k] - mx;
      double dy = y[k] - my;
      sxx += dx * dx;
      syy += dy * dy;
      sxy += dx * dy;
     }
   if(sxx <= 0.0 || syy <= 0.0)
      return 0.0;
   double corr = sxy / MathSqrt(sxx * syy);
   return HchClamp((corr - 0.30) / 0.60);
  }

// Movimiento previo al hombro izquierdo, en ATR (igual que PriorMoveATR).
double HchTendenciaAtr(const MqlRates &r[], const int dir, const int i0,
                       const double precioPivote, const double &atr[],
                       const int atrDesde, const int atrHasta)
  {
   int    desde = MathMax(0, i0 - P_hchVelasTend);
   double a     = HchAtrAt(atr, atrDesde, atrHasta, i0);
   if(dir > 0)
     {
      double lo = r[desde].low;
      for(int k = desde + 1; k <= i0; k++)
         if(r[k].low < lo)
            lo = r[k].low;
      return (precioPivote - lo) / a;
     }
   double hi = r[desde].high;
   for(int k = desde + 1; k <= i0; k++)
      if(r[k].high > hi)
         hi = r[k].high;
   return (hi - precioPivote) / a;
  }

// Evalua 5 pivotes consecutivos como candidato a HCH (igual que EvalCandidate).
bool HchEvaluar(const MqlRates &r[], const HPivote &piv[], const int k, const int dir,
                const double &atr[], const int atrDesde, const int atrHasta,
                HPatron &c)
  {
   double v[5];
   int    ix[5];
   for(int j = 0; j < 5; j++)
     {
      ix[j] = piv[k + j].idx;
      v[j]  = dir * piv[k + j].precio;
     }

   // --- reglas duras
   if(!(v[2] > v[0] && v[2] > v[4]))
      return false;
   if(!(v[1] < v[0] && v[1] < v[2] && v[3] < v[2] && v[3] < v[4]))
      return false;

   int total = ix[4] - ix[0];
   if(total < P_hchMinVelas || total > P_hchMaxVelas)
      return false;

   int tL = ix[2] - ix[0];
   int tR = ix[4] - ix[2];
   if(tL < 2 || tR < 2)
      return false;
   double ratio = (double)MathMin(tL, tR) / (double)MathMax(tL, tR);
   if(ratio < P_hchMinTiempo)
      return false;

   double dxn = (double)(ix[3] - ix[1]);
   if(dxn <= 0.0)
      return false;
   double pendiente     = (v[3] - v[1]) / dxn;
   double cuelloCabeza  = v[1] + pendiente * (double)(ix[2] - ix[1]);
   double altura        = v[2] - cuelloCabeza;
   if(altura <= 0.0)
      return false;

   double a = HchAtrAt(atr, atrDesde, atrHasta, ix[2]);
   if(altura < P_hchMinPatronAtr * a)
      return false;

   double lsH = v[0] - (v[1] + pendiente * (double)(ix[0] - ix[1]));
   double rsH = v[4] - (v[1] + pendiente * (double)(ix[4] - ix[1]));
   if(lsH < P_hchMinHombroFrac * altura || rsH < P_hchMinHombroFrac * altura)
      return false;

   double prom = (v[2] - MathMax(v[0], v[4])) / altura;
   if(prom < P_hchMinCabeza)
      return false;

   double deltaCuello = MathAbs(v[3] - v[1]) / altura;
   if(deltaCuello >= P_hchTolCuello)
      return false;

   double difHombros = MathAbs(v[0] - v[4]) / altura;
   if(difHombros >= P_hchTolHombros)
      return false;

   // --- puntuacion difusa
   double sSh    = HchClamp(1.0 - difHombros / P_hchTolHombros);
   double sTime  = HchClamp((ratio - P_hchMinTiempo) / (0.75 - P_hchMinTiempo));
   double sNeck  = HchClamp(1.0 - deltaCuello / P_hchTolCuello);
   double sHead  = HchClamp(prom / 0.30);
   double sSize  = HchClamp((altura / a) / (2.0 * P_hchMinPatronAtr));
   double sTrend = HchClamp(HchTendenciaAtr(r, dir, ix[0], piv[k].precio,
                                            atr, atrDesde, atrHasta) / P_hchTendAtr);
   double sTmpl  = HchScorePlantilla(r, dir, ix[0], ix[4]);

   double score = 100.0 * (0.20 * sSh + 0.15 * sTime + 0.15 * sNeck + 0.10 * sHead +
                           0.05 * sSize + 0.10 * sTrend + 0.25 * sTmpl);
   if(score < P_hchMinScore)
      return false;

   c.dir = dir;
   for(int j = 0; j < 5; j++)
     {
      c.ix[j] = ix[j];
      c.px[j] = piv[k + j].precio;
     }
   c.score   = score;
   c.cabezaH = altura;
   return true;
  }

// 0 = aun sin ruptura, 1 = cuello roto, 2 = invalidado, 3 = expirado.
int HchEstado(const HPatron &p, const MqlRates &r[], const int e,
              const double &atr[], const int atrDesde, const int atrHasta,
              int &idxRuptura, double &entrada, double &stop)
  {
   idxRuptura = -1;
   entrada    = 0.0;
   stop       = 0.0;

   for(int j = p.ix[4] + 1; j <= e; j++)
     {
      double a = HchAtrAt(atr, atrDesde, atrHasta, j);

      // invalidado: el precio supera la cabeza antes de romper el cuello
      if((p.dir > 0 && r[j].high > p.px[2]) || (p.dir < 0 && r[j].low < p.px[2]))
         return 2;

      double cuello = HchCuello(p, j);
      double buf    = P_hchBufRuptura * a;
      bool   rompe  = (p.dir > 0) ? (r[j].close < cuello - buf)
                                  : (r[j].close > cuello + buf);
      if(rompe)
        {
         idxRuptura = j;
         entrada    = r[j].close;
         double base = P_hchStopCabeza ? p.px[2] : p.px[4];
         stop        = base + p.dir * P_hchBufStop * a;
         return 1;
        }

      if(j - p.ix[4] > P_hchMaxEspera)
         return 3;
     }
   return 0;
  }

// EMAs solo para la etiqueta de tendencia del mensaje (campo 4).
string TendenciaEmas(const MqlRates &r[])
  {
   int n = ArraySize(r);
   double cierres[], e30[], e50[], e100[];
   ArrayResize(cierres, n);
   for(int i = 0; i < n; i++)
      cierres[i] = r[i].close;
   CalcEma(cierres, P_emaContacto, e30);
   CalcEma(cierres, P_emaTecho, e50);
   CalcEma(cierres, P_emaFondo, e100);
   return Tendencia(r[n-1].close, e30[n-1], e50[n-1], e100[n-1]);
  }

//--------------------------------------------------------------------
//  Escaneo de la serie: solo la vela recien cerrada puede emitir.
//--------------------------------------------------------------------
void Escanear(const MqlRates &r[], Evento &eventos[])
  {
   ArrayResize(eventos, 0);
   int n = ArraySize(r);
   if(n < P_hchAtrPeriodo * 5 + 60)
      return;
   g_barraActual = n - 1;   // solo la vela recien cerrada escribe log

   int e     = n - 1;
   int s     = MathMax(0, e - P_hchLookback + 1);
   int desde = MathMax(0, s - 5 * P_hchAtrPeriodo);

   double atr[];
   HchAtr(r, desde, e, atr);

   HPivote piv[];
   int nPiv = 0;
   HchPivotes(r, s, e, atr, desde, e, piv, nPiv);

   string tend = TendenciaEmas(r);

   Evento mejor[2];          // 0 = VENTA (HCH), 1 = COMPRA (HCH invertido)
   double scoreMax[2];
   scoreMax[0] = -1.0;
   scoreMax[1] = -1.0;

   for(int k = 0; k + 4 < nPiv; k++)
     {
      int dir = piv[k].tipo;
      g_emb[g_tfIdx].patrones++;

      HPatron p;
      if(!HchEvaluar(r, piv, k, dir, atr, desde, e, p))
         continue;
      g_emb[g_tfIdx].completos++;

      int    idxR    = -1;
      double entrada = 0.0, stop = 0.0;
      int    st = HchEstado(p, r, e, atr, desde, e, idxR, entrada, stop);
      if(st == 2) { g_emb[g_tfIdx].invalidados++; continue; }
      if(st == 3) { g_emb[g_tfIdx].expirados++;   continue; }
      if(st == 0)
         continue;
      if(idxR != e)
        {
         g_emb[g_tfIdx].rotos++;   // rompio en una vela anterior: ya paso
         continue;
        }

      int lado = (dir > 0) ? 0 : 1;
      if(p.score <= scoreMax[lado])
         continue;
      scoreMax[lado] = p.score;

      Evento ev;
      ev.bar       = e;
      ev.lado      = (lado == 0) ? "VENTA" : "COMPRA";
      ev.patron    = (dir > 0) ? "HCH" : "HCHi";
      ev.precio    = entrada;
      ev.invalida  = stop;
      ev.nivel     = HchCuello(p, e);
      ev.tendencia = tend;
      ev.score     = p.score;
      ev.prio      = 1;
      mejor[lado]  = ev;
     }

   for(int lado = 0; lado < 2; lado++)
     {
      if(scoreMax[lado] < 0.0)
         continue;
      int k = ArraySize(eventos);
      ArrayResize(eventos, k + 1);
      eventos[k] = mejor[lado];
      g_emb[g_tfIdx].emitidos++;
     }
  }

//--------------------------------------------------------------------
//  Estrategia BARRIDO DE LIQUIDEZ
//  Port del indicador BarridoLiquidez.mq5: swing confirmado, mecha que
//  perfora el nivel y vuelve a cerrar dentro, y rebote confirmado.
//  La senal es el REBOTE (no el barrido): entrada al cierre de la vela
//  que se aleja 1,5 ATR de la punta de la mecha.
//  Se recalcula sobre la ventana reciente: un barrido que pudiera
//  confirmar en esta vela nacio como mucho MaxBarrido+Rebote velas atras.
//--------------------------------------------------------------------
void LiqAtr(const MqlRates &r[], const int desde, const int hasta, double &atr[])
  {
   ArrayResize(atr, hasta + 1);
   ArrayInitialize(atr, 0.0);
   double a = 0.0;
   for(int k = desde; k <= hasta; k++)
     {
      double tr = r[k].high - r[k].low;
      if(k > 0)
         tr = MathMax(tr, MathMax(MathAbs(r[k].high - r[k-1].close),
                                  MathAbs(r[k].low  - r[k-1].close)));
      int nn = k - desde;
      if(nn <= 0)
         a = tr;
      else
        {
         if(P_liqAtrTope > 0.0)
            tr = MathMin(tr, P_liqAtrTope * a);
         if(nn < P_liqAtrPeriodo)
            a = (a * nn + tr) / (nn + 1);
         else
            a = (a * (P_liqAtrPeriodo - 1) + tr) / P_liqAtrPeriodo;
        }
      atr[k] = a;
     }
  }

// Swing confirmado en i (necesita P_liqSwing velas a cada lado).
bool LiqSwing(const MqlRates &r[], const int i, const int dir)
  {
   double v = (dir > 0) ? r[i].low : -r[i].high;
   for(int k = 1; k <= P_liqSwing; k++)
     {
      double izq = (dir > 0) ? r[i-k].low : -r[i-k].high;
      double der = (dir > 0) ? r[i+k].low : -r[i+k].high;
      if(izq <= v)
         return false;
      if(der <  v)
         return false;
     }
   return true;
  }

// La vela del extremo debe mostrar rechazo: color contrario y mecha larga.
bool LiqMechaOk(const MqlRates &r[], const double &atr[], const int x, const int d,
                const double nivel, const double extremo)
  {
   double rng = r[x].high - r[x].low;
   if(rng <= 0.0)
      return false;
   if(P_liqColorContra && d * (r[x].close - r[x].open) <= 0.0)
      return false;
   double a = MathMax(atr[x], _Point);
   if(d * (nivel - extremo) < P_liqMinPerfora * a)
      return false;
   double mecha = (d > 0) ? (MathMin(r[x].open, r[x].close) - r[x].low)
                          : (r[x].high - MathMax(r[x].open, r[x].close));
   if(mecha < P_liqMechaAtr * a)
      return false;
   if(mecha / rng < P_liqMechaMin)
      return false;
   return true;
  }

// Devuelve la vela en la que el rebote queda confirmado, o -1.
int LiqConfirmacion(const MqlRates &r[], const double &atr[], const int e,
                    const int nivelIdx, const int d, const double nivel,
                    double &extremo, int &extremoIdx)
  {
   int desde = MathMax(nivelIdx + 1, e - (P_liqMaxBarrido + P_liqReboteVelas + 1));
   int primero = -1;
   for(int j = desde; j <= e; j++)
     {
      if((d > 0 && r[j].low < nivel) || (d < 0 && r[j].high > nivel))
        {
         primero = j;
         break;
        }
     }
   if(primero < 0)
      return -1;

   extremo    = (d > 0) ? r[primero].low : r[primero].high;
   extremoIdx = primero;
   int fin = MathMin(primero + P_liqMaxBarrido - 1, e);
   int reclaim = -1;
   for(int j = primero; j <= fin; j++)
     {
      if(d > 0) { if(r[j].low  < extremo) { extremo = r[j].low;  extremoIdx = j; } }
      else      { if(r[j].high > extremo) { extremo = r[j].high; extremoIdx = j; } }
      double a = MathMax(atr[j], _Point);
      if(d * (nivel - extremo) > P_liqMaxPerfora * a)
         return -1;                        // ruptura, no barrido
      if(d * (r[j].close - nivel) > 0.0)  // cierre de vuelta dentro del nivel
        {
         reclaim = j;
         break;
        }
     }
   if(reclaim < 0)
      return -1;
   if(!LiqMechaOk(r, atr, extremoIdx, d, nivel, extremo))
      return -1;

   for(int j = reclaim + 1; j <= e; j++)
     {
      double a = MathMax(atr[j], _Point);
      double avance = d * (r[j].close - extremo);
      if(avance < -P_liqBufRuptura * a)
         return -1;                        // zona rota
      if(avance >= P_liqReboteAtr * a)
         return j;                         // rebote confirmado
      if(j - reclaim >= P_liqReboteVelas)
         return -1;                        // expirada
     }
   return -1;
  }

void EscanearLiquidez(const MqlRates &r[], Evento &eventos[])
  {
   ArrayResize(eventos, 0);
   int n = ArraySize(r);
   if(n < P_liqAtrPeriodo * 5 + 2 * P_liqSwing + 60)
      return;
   int e = n - 1;

   int desdeAtr = MathMax(0, e - (P_liqMaxEdadNivel + 2 * P_liqSwing + 5 * P_liqAtrPeriodo));
   double atr[];
   LiqAtr(r, desdeAtr, e, atr);

   // Un nivel barrido en la ventana de rebote puede tener hasta MaxEdadNivel
   // velas de antiguedad en el momento del barrido.
   int desde = MathMax(P_liqSwing, e - P_liqMaxEdadNivel - P_liqMaxBarrido - P_liqReboteVelas - 2);
   string tend = TendenciaEmas(r);

   Evento mejor[2];
   int    mejorExt[2];
   mejorExt[0] = -1;
   mejorExt[1] = -1;

   for(int i = desde; i + P_liqSwing <= e; i++)
     {
      for(int s = 0; s < 2; s++)
        {
         int d = (s == 0) ? +1 : -1;
         if(d > 0 && !P_liqAlcista)
            continue;
         if(d < 0 && !P_liqBajista)
            continue;
         if(!LiqSwing(r, i, d))
            continue;
         g_emb[g_tfIdx].liqNiveles++;

         double nivel = (d > 0) ? r[i].low : r[i].high;
         double ext   = 0.0;
         int    extIdx = -1;
         int    conf = LiqConfirmacion(r, atr, e, i, d, nivel, ext, extIdx);
         if(conf != e)
            continue;

         int lado = (d > 0) ? 1 : 0;          // barrido de minimos -> COMPRA
         if(extIdx <= mejorExt[lado])
            continue;
         mejorExt[lado] = extIdx;

         Evento ev;
         ev.bar       = e;
         ev.lado      = (lado == 0) ? "VENTA" : "COMPRA";
         ev.patron    = "LIQ";
         ev.precio    = r[e].close;
         ev.invalida  = ext - d * P_liqBufRuptura * MathMax(atr[e], _Point);
         ev.nivel     = nivel;
         ev.score     = d * (r[e].close - ext) / MathMax(atr[e], _Point);
         ev.prio      = 2;
         ev.tendencia = tend;
         mejor[lado]  = ev;
        }
     }

   for(int lado = 0; lado < 2; lado++)
     {
      if(mejorExt[lado] < 0)
         continue;
      int k = ArraySize(eventos);
      ArrayResize(eventos, k + 1);
      eventos[k] = mejor[lado];
      g_emb[g_tfIdx].liqEmite++;
     }
  }

//--------------------------------------------------------------------
//  Mensaje: mismo formato de 7 campos que formatearSenal (telegram.js)
//--------------------------------------------------------------------
string MensajeSenal(const string simbolo, const string tf, const Evento &ev,
                    const datetime tVelaUTC, const string extraTend)
  {
   bool compra = (ev.lado == "COMPRA");
   string patron = ev.patron;
   string texto = "";
   // La estrategia va en el encabezado para que HCH y LIQ se distingan de
   // un vistazo en el movil, ademas del campo 3 del formato de 7 campos.
   texto += Icono(compra) + " <b>" + ev.lado + "</b> | <b>" + patron + "</b>\n";
   texto += "<b>1. Activo:</b> " + simbolo + "\n";
   texto += "<b>2. Temporalidad:</b> " + tf + "\n";
   string estrategia = "Hombro-Cabeza-Hombro";
   if(ev.patron == "HCHi")
      estrategia = "Hombro-Cabeza-Hombro invertido";
   else if(ev.patron == "LIQ")
      estrategia = "Barrido de liquidez";
   texto += "<b>3. Estrategia:</b> " + patron + " - " + estrategia + "\n";
   texto += "<b>4. Tendencia:</b> " + TendenciaTxt(ev.tendencia) + extraTend + "\n";
   texto += "<b>5. Precio entrada:</b> " + FmtPrecio(ev.precio) + " (vela cerrada)\n";
   texto += "<b>6. Invalidación:</b> " + FmtPrecio(ev.invalida) + "\n";
   texto += "<b>7. Hora:</b> " + HoraHabana(tVelaUTC) + " (Habana)";
   return texto;
  }

//--------------------------------------------------------------------
//  Antiduplicado entre reinicios del EA
//--------------------------------------------------------------------
string g_enviadas[];

bool YaEnviada(const string clave)
  {
   int n = ArraySize(g_enviadas);
   for(int i=0; i<n; i++)
      if(g_enviadas[i] == clave)
         return true;
   return false;
  }

void MarcarEnviada(const string clave)
  {
   int n = ArraySize(g_enviadas);
   ArrayResize(g_enviadas, n + 1);
   g_enviadas[n] = clave;
   if(n >= 2000)
     {
      // Topar la lista EN MEMORIA tambien: antes solo se recortaba el archivo
      // y g_enviadas crecia sin limite (YaEnviada es una busqueda lineal).
      ArrayRemove(g_enviadas, 0, n - 999);   // deja las 1000 ultimas + esta
      int h0 = FileOpen("adv_enviados.txt", FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h0 != INVALID_HANDLE)
        {
         int m = ArraySize(g_enviadas);
         for(int i = 0; i < m; i++)
            FileWrite(h0, g_enviadas[i]);
         FileClose(h0);
        }
      return;
     }
   int h = FileOpen("adv_enviados.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, clave);
   FileClose(h);
  }

void CargarEnviadas()
  {
   int h = FileOpen("adv_enviados.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return;
   while(!FileIsEnding(h))
     {
      string l = FileReadString(h);
      StringTrimLeft(l);
      StringTrimRight(l);
      if(StringLen(l) > 0)
        {
         int n = ArraySize(g_enviadas);
         ArrayResize(g_enviadas, n + 1);
         g_enviadas[n] = l;
        }
     }
   FileClose(h);
   Log("Antiduplicado: " + IntegerToString(ArraySize(g_enviadas)) + " senales previas recordadas");
  }

//--------------------------------------------------------------------
//  Estado por simbolo
//--------------------------------------------------------------------
struct EstadoSim
  {
   string   nombre;
   datetime ultimaBarra[8];   // por cada TF (M1,M3,M5,M15,H1...)
   int      senales[8];       // por cada TF
   bool     avisado;
  };

EstadoSim g_est[];

void Revisar(const int idx)
  {
   if(StringLen(g_est[idx].nombre) == 0)
      return;

   for(int tfi = 0; tfi < g_nTf; tfi++)
     {
      g_tf    = g_tfArr[tfi];
      g_tfTxt = g_tfTxtArr[tfi];
      g_tfIdx = tfi;

      // Chequeo barato antes de copiar: si la vela en formacion no cambio, no
      // cerro nada nuevo. Antes se copiaban 3000 velas x 4 TF x 4 simbolos
      // cada 10 s aunque no hubiera barra nueva.
      datetime formando = iTime(g_est[idx].nombre, g_tf, 0);
      if(formando > 0 && formando == g_est[idx].ultimaBarra[tfi])
         continue;

      MqlRates r[];
      int n = CopyRates(g_est[idx].nombre, g_tf, 1, g_velas, r);
      if(n < P_emaFondo + 30)
        {
         if(!g_est[idx].avisado)
           {
            Log(g_est[idx].nombre + ": solo " + IntegerToString(n) + " velas " + g_tfTxt
                + " (necesito " + IntegerToString(P_emaFondo + 30) + "). Espero.");
            g_est[idx].avisado = true;
           }
         continue;
        }
      g_est[idx].avisado = false;
      // se guarda la vela en formacion: si sigue igual, no hay nada nuevo
      if(formando > 0)
         g_est[idx].ultimaBarra[tfi] = formando;
      datetime ultima = r[n-1].time;

      // HCH y barrido de liquidez: cada uno devuelve solo la vela cerrada.
      Evento evsH[], evsL[], cand[];
      Escanear(r, evsH);
      EscanearLiquidez(r, evsL);
      int nh = ArraySize(evsH), nl = ArraySize(evsL);
      ArrayResize(cand, nh + nl);
      for(int i = 0; i < nh; i++)
         cand[i] = evsH[i];
      for(int i = 0; i < nl; i++)
         cand[nh + i] = evsL[i];

      long offServidor = (long)TimeTradeServer() - (long)TimeGMT();
      datetime tCierre  = (datetime)((long)ultima + (long)PeriodSeconds(g_tf));
      datetime tCierreUTC = (datetime)((long)tCierre - offServidor);

      // HCH y LIQ son estrategias independientes: cada una manda su propia
      // senal por vela y lado. Dentro de la misma estrategia gana el mayor
      // score (HCH compite HCH/HCHi, LIQ compite consigo misma).
      for(int fam = 0; fam < 2; fam++)
       for(int lado = 0; lado < 2; lado++)
        {
         string cual = (lado == 0) ? "VENTA" : "COMPRA";
         bool   esHch = (fam == 0);
         int mejor = -1;
         int nc = ArraySize(cand);
         for(int i = 0; i < nc; i++)
           {
            if(cand[i].lado != cual)
               continue;
            if((StringFind(cand[i].patron, "HCH") == 0) != esHch)
               continue;
            if(mejor < 0 || cand[i].score > cand[mejor].score)
               mejor = i;
           }
         if(mejor < 0)
            continue;

         Evento ev = cand[mejor];
         string clave = g_est[idx].nombre + "|" + g_tfTxt + "|" + IntegerToString((long)ultima)
                        + "|" + ev.lado + "|" + ev.patron;
         if(YaEnviada(clave))
            continue;

         TendMayor tm = TendenciaMayor(g_est[idx].nombre, tCierre);
         string extra = SufijoTendencia(tm, g_tfTxt);
         // El H1 NO es un filtro de la estrategia: el estado de H1 se escribe
         // en la senal y en el log, pero no veta ninguna temporalidad.
         if(tm.ok && tm.tendencia != "RANGO")
           {
            bool contra = (ev.lado == "VENTA"  && tm.tendencia == "ALCISTA")
                       || (ev.lado == "COMPRA" && tm.tendencia == "BAJISTA");
            if(contra)
               Log("[AVISO H1] " + ev.lado + " " + g_est[idx].nombre + " " + g_tfTxt + " contra H1 "
                   + tm.tendencia + " (" + tm.fase + ", rotura hace "
                   + IntegerToString(tm.velasRotura) + " velas H1): sale avisada");
           }
         string texto = MensajeSenal(g_est[idx].nombre, g_tfTxt, ev, tCierreUTC, extra);
         Log("[SENAL] " + ev.lado + " " + g_est[idx].nombre + " " + g_tfTxt + " "
             + ev.patron + " precio=" + FmtPrecio(ev.precio) + extra);
         if(EnviarTelegram(texto))
           {
            MarcarEnviada(clave);
            g_est[idx].senales[tfi]++;
           }
        }
     }
  }

//--------------------------------------------------------------------
//  BACKTEST: CSV de senales y de barras
//  Se usa FILE_COMMON para que el runner los recoja siempre del mismo
//  sitio: en el tester los archivos normales caen en el sandbox del
//  agente (Tester\Agent-xxx\MQL5\Files) y es un lio encontrarlos.
//--------------------------------------------------------------------
string BtRuta(const string archivo)
  {
   return InpBtCarpeta + "\\" + archivo;
  }

void BtInit()
  {
   g_bt = true;
   FolderCreate(InpBtCarpeta, FILE_COMMON);
   g_btHsen = FileOpen(BtRuta("senales.csv"), FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(g_btHsen != INVALID_HANDLE)
      FileWrite(g_btHsen, "id;time;symbol;tf;code;dir;entry;stop;atr;tipo;h1");
   for(int tfi = 0; tfi < g_nTf; tfi++)
     {
      g_btUltBarra[tfi] = 0;
      g_btHbar[tfi]     = INVALID_HANDLE;
      if(!InpBtBarras)
         continue;
      g_btHbar[tfi] = FileOpen(BtRuta("barras_" + g_tfTxtArr[tfi] + ".csv"),
                               FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(g_btHbar[tfi] != INVALID_HANDLE)
         FileWrite(g_btHbar[tfi], "time;open;high;low;close");
     }
   Print("BT: simbolo=", _Symbol, " ventana=", InpBtVentana,
         " barras=", (InpBtBarras ? "si" : "no"), " -> ", BtRuta("senales.csv"));
  }

void BtCerrar()
  {
   if(g_btHsen != INVALID_HANDLE)
     {
      FileClose(g_btHsen);
      g_btHsen = INVALID_HANDLE;
     }
   for(int tfi = 0; tfi < g_nTf; tfi++)
      if(g_btHbar[tfi] != INVALID_HANDLE)
        {
         FileClose(g_btHbar[tfi]);
         g_btHbar[tfi] = INVALID_HANDLE;
        }
  }

void BtSenal(const string tf, const Evento &ev, const datetime tBarra,
             const double atr, const string h1)
  {
   if(g_btHsen == INVALID_HANDLE)
      return;
   g_btEventos++;
   FileWrite(g_btHsen,
             IntegerToString(g_btEventos) + ";" +
             TimeToString(tBarra, TIME_DATE|TIME_MINUTES) + ";" +
             _Symbol + ";" + tf + ";" + ev.patron + ";" + ev.lado + ";" +
             DoubleToString(ev.precio, _Digits) + ";" +
             DoubleToString(ev.invalida, _Digits) + ";" +
             DoubleToString(atr, _Digits) + ";" +
             "ENTRADA;" + h1);
  }

// Un paso del tester: por cada TF mira si cerro una vela nueva, guarda la
// barra y escribe las senales de ESA vela (misma logica que Revisar en vivo).
void BtPaso()
  {
   for(int tfi = 0; tfi < g_nTf; tfi++)
     {
      g_tf    = g_tfArr[tfi];
      g_tfTxt = g_tfTxtArr[tfi];
      g_tfIdx = tfi;

      MqlRates r[];
      int n = CopyRates(_Symbol, g_tf, 1, InpBtVentana, r);   // 1 = ultima CERRADA
      if(n < P_emaFondo + 30)
         continue;
      datetime tBarra = r[n-1].time;
      if(tBarra == g_btUltBarra[tfi])
         continue;
      g_btUltBarra[tfi] = tBarra;

      if(g_btHbar[tfi] != INVALID_HANDLE)
         FileWrite(g_btHbar[tfi],
                   TimeToString(tBarra, TIME_DATE|TIME_MINUTES) + ";" +
                   DoubleToString(r[n-1].open,  _Digits) + ";" +
                   DoubleToString(r[n-1].high,  _Digits) + ";" +
                   DoubleToString(r[n-1].low,   _Digits) + ";" +
                   DoubleToString(r[n-1].close, _Digits));

      Evento evsH[], evsL[], cand[];
      Escanear(r, evsH);
      EscanearLiquidez(r, evsL);
      int nh = ArraySize(evsH), nl = ArraySize(evsL);
      ArrayResize(cand, nh + nl);
      for(int i = 0; i < nh; i++)
         cand[i] = evsH[i];
      for(int i = 0; i < nl; i++)
         cand[nh + i] = evsL[i];
      if(ArraySize(cand) == 0)
         continue;

      double atr[];
      CalcAtr(r, P_atrPeriodo, atr);
      double atrS = atr[n-1];

      datetime tCierre = (datetime)((long)tBarra + (long)PeriodSeconds(g_tf));
      TendMayor tm = TendenciaMayor(_Symbol, tCierre);
      string h1 = SufijoTendencia(tm, g_tfTxt);

      // HCH y LIQ son independientes: una senal de cada una por vela y lado
      for(int fam = 0; fam < 2; fam++)
       for(int lado = 0; lado < 2; lado++)
        {
         string cual = (lado == 0) ? "VENTA" : "COMPRA";
         bool   esHch = (fam == 0);
         int mejor = -1;
         int nc = ArraySize(cand);
         for(int i = 0; i < nc; i++)
           {
            if(cand[i].lado != cual)
               continue;
            if((StringFind(cand[i].patron, "HCH") == 0) != esHch)
               continue;
            if(mejor < 0 || cand[i].score > cand[mejor].score)
               mejor = i;
           }
         if(mejor < 0)
            continue;
         Evento ev = cand[mejor];
         // mismo criterio que en vivo: el H1 se anota en la senal, no veta
         BtSenal(g_tfTxt, ev, tBarra, atrS, h1);
        }
     }
  }

//--------------------------------------------------------------------
//  Arranque
//--------------------------------------------------------------------
int OnInit()
  {
   Log("=== EstrategiaAdversaria 1.00 ===");
   CargarCfg("adv.cfg");
   CargarEnviadas();

   // Multi-TF: la lista sale de adv.cfg (tfs=M1,M3,M5,M15,H1).
   // Si viene vacia o con mas de 8 entradas se usa la lista por defecto.
   string parTf[];
   int    npTf = StringSplit(g_tfs, StringGetCharacter(",", 0), parTf);
   int    nVal = 0;
   ArrayResize(g_tfTxtArr, 8);
   ArrayResize(g_tfArr, 8);
   for(int i = 0; i < npTf && nVal < 8; i++)
     {
      string u = parTf[i];
      StringTrimLeft(u);
      StringTrimRight(u);
      if(StringLen(u) == 0)
         continue;
      g_tfTxtArr[nVal] = u;
      g_tfArr[nVal]   = TfDeTexto(u);
      nVal++;
     }
   if(nVal == 0)
     {
      g_tfTxtArr[0] = "M5";  g_tfArr[0] = PERIOD_M5;
      nVal = 1;
     }
   ArrayResize(g_tfTxtArr, nVal);
   ArrayResize(g_tfArr, nVal);
   g_nTf   = nVal;
   g_iRef  = 0;
   for(int i = 0; i < g_nTf; i++)
      if(g_tfTxtArr[i] == "M5")
         g_iRef = i;
   g_tfTxt = g_tfTxtArr[g_iRef];   // default para logs
   g_tf    = g_tfArr[g_iRef];

   // Modo backtest: no hay cuenta, ni Telegram, ni timer. El tester empuja
   // vela a vela por OnTick y todo sale a CSV.
   if(InpBacktest || MQLInfoInteger(MQL_TESTER) != 0)
     {
      BtInit();
      return(INIT_SUCCEEDED);
     }

   long login     = AccountInfoInteger(ACCOUNT_LOGIN);
   string servidor = AccountInfoString(ACCOUNT_SERVER);
   // ENUM_ACCOUNT_TRADE_MODE: 0 = demo, 1 = concurso, 2 = real
   long modo      = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   string modoTxt = (modo == 0) ? "demo" : ((modo == 1) ? "concurso" : "REAL");
   Log("Cuenta " + IntegerToString(login) + " en " + servidor + " (" + modoTxt + ")");
   if(modo != 0)
      Log("OJO: ACCOUNT_TRADE_MODE no es demo. Revisa con que cuenta estas entrando.");

   string partes[];
   int np = StringSplit(g_simbolos, StringGetCharacter(",", 0), partes);
   string listaOk = "";
   for(int i=0; i<np; i++)
     {
      string pedido = partes[i];
      StringTrimLeft(pedido);
      StringTrimRight(pedido);
      if(StringLen(pedido) == 0)
         continue;
      string real = ResolverSimbolo(pedido);
      int k = ArraySize(g_est);
      ArrayResize(g_est, k + 1);
      g_est[k].nombre = real;
      for(int tfi = 0; tfi < g_nTf; tfi++)
        {
         g_est[k].ultimaBarra[tfi] = 0;
         g_est[k].senales[tfi]     = 0;
        }
      g_est[k].avisado = false;
      if(StringLen(real) == 0)
        {
         Log("SIMBOLO NO ENCONTRADO: '" + pedido + "' (revisa el nombre en Market Watch)");
         continue;
        }
      if(real != pedido)
         Log("Simbolo '" + pedido + "' resuelto como '" + real + "'");
      listaOk += (StringLen(listaOk) > 0 ? ", " : "") + real;
     }

   string tfLista = "";
   for(int tfi = 0; tfi < g_nTf; tfi++)
      tfLista += (tfi > 0 ? "," : "") + g_tfTxtArr[tfi];
   Log("Vigilando " + IntegerToString(ArraySize(g_est)) + " simbolos en [" + tfLista + "]"
       + " (" + IntegerToString(g_velas) + " velas)" + " | Telegram: "
       + ((g_tgToken != "" && g_tgChat != "") ? "configurado" : "SIN CONFIGURAR"));
   EcoParametros();

   long offServidor = (long)TimeTradeServer() - (long)TimeGMT();
   Log("Desfase del servidor respecto a UTC: " + IntegerToString((int)(offServidor / 3600)) + " h");

   // Snapshot de precios al arrancar (para verificar que los activos coinciden con MT5)
   string snap = "Precios al arrancar:";
   for(int i=0; i<ArraySize(g_est); i++)
     {
      if(StringLen(g_est[i].nombre) == 0)
         continue;
      MqlRates r[];
      int m = CopyRates(g_est[i].nombre, g_tfArr[g_iRef], 0, 2, r);
      string precio = (m > 0) ? FmtPrecio(r[m-1].close) : "sin datos";
      snap = snap + "\n  " + g_est[i].nombre + " = " + precio;
     }

   string msg = "EA ADVERSARIO ARRANCADO";
   msg = msg + "\n" + "Cuenta: " + IntegerToString(login) + " - " + servidor + " (" + modoTxt + ")";
   msg = msg + "\n" + "Activos: " + (StringLen(listaOk) ? listaOk : "(ninguno resuelto)");
   msg = msg + "\n" + "Temporalidades: " + tfLista;
   msg = msg + "\n" + "Horario del servidor: UTC" + (offServidor >= 0 ? "+" : "")
         + IntegerToString((int)(offServidor / 3600));
   msg = msg + "\n" + snap;
   EnviarTelegram(msg);

   EventSetTimer(10);
   Log("Timer cada 10 s. Esperando cierres de vela.");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_bt)
     {
      BtCerrar();
      Print("BT: fin, ", g_btEventos, " senales escritas");
     }
   Log("EA detenido (reason " + IntegerToString(reason) + ")");
  }

//--------------------------------------------------------------------
//  Panel web: snapshot de lo que ve el EA
//--------------------------------------------------------------------
// Escribe MQL5/Files/panel_estado.json con las ultimas P_panelVelas velas de
// cada simbolo y temporalidad, las EMAs y el ATR. NO decide nada: solo copia
// los mismos datos que usa Revisar(). El servidor del panel (panel/panel.mjs)
// lo sirve tal cual y el navegador dibuja. Se escribe una vez por vela M3.
#define P_panelVelas 200

void PanelEstado()
  {
   string j = "{";
   j += "\"generado\":\"" + TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS) + "\"";
   j += ",\"servidor\":\"" + EscJson(AccountInfoString(ACCOUNT_SERVER)) + "\"";
   j += ",\"login\":" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN));
   j += ",\"modo\":\"" + ((AccountInfoInteger(ACCOUNT_TRADE_MODE) == 0) ? "demo" : "real") + "\"";
   j += ",\"velas\":" + IntegerToString(P_panelVelas);

   string tfs = "";
   for(int tfi = 0; tfi < g_nTf; tfi++)
      tfs += (tfi > 0 ? "," : "") + "\"" + EscJson(g_tfTxtArr[tfi]) + "\"";
   j += ",\"tfs\":[" + tfs + "]";

   j += ",\"simbolos\":[";
   int ns = ArraySize(g_est);
   bool primero = true;
   for(int i = 0; i < ns; i++)
     {
      if(StringLen(g_est[i].nombre) == 0)
         continue;
      if(!primero)
         j += ",";
      primero = false;

      double precio = 0.0, spread = 0.0;
      MqlRates rp[];
      int mp = CopyRates(g_est[i].nombre, g_tfArr[g_iRef], 0, 1, rp);
      if(mp > 0)
        {
         precio = rp[0].close;
         if(rp[0].spread > 0)
            spread = rp[0].spread * SymbolInfoDouble(g_est[i].nombre, SYMBOL_POINT);
        }

      j += "{\"simbolo\":\"" + EscJson(g_est[i].nombre) + "\"";
      j += ",\"precio\":" + DoubleToString(precio, 2);
      j += ",\"spread\":" + DoubleToString(spread, 2);
      j += ",\"tf\":[";

      for(int tfi = 0; tfi < g_nTf; tfi++)
        {
         if(tfi > 0)
            j += ",";
         j += "{\"tf\":\"" + EscJson(g_tfTxtArr[tfi]) + "\"";

         MqlRates r[];
         int n = CopyRates(g_est[i].nombre, g_tfArr[tfi], 1, P_panelVelas + P_emaFondo + 5, r);
         if(n < P_emaFondo + 5)
           {
            j += ",\"tend\":\"SIN DATOS\",\"velas\":[]}";
            continue;
           }

         double c[];
         ArrayResize(c, n);
         for(int k = 0; k < n; k++)
            c[k] = r[k].close;
         double e30[], e50[], e100[], atr[];
         CalcEma(c, P_emaContacto, e30);
         CalcEma(c, P_emaTecho, e50);
         CalcEma(c, P_emaFondo, e100);
         CalcAtr(r, P_atrPeriodo, atr);
         int li = n - 1;

         j += ",\"tend\":\"" + Tendencia(c[li], e30[li], e50[li], e100[li]) + "\"";
         j += ",\"e30\":" + DoubleToString(e30[li], 2);
         j += ",\"e50\":" + DoubleToString(e50[li], 2);
         j += ",\"e100\":" + DoubleToString(e100[li], 2);
         j += ",\"atr\":" + DoubleToString(atr[li], 2);

         // [tiempo, apertura, maximo, minimo, cierre] y las tres EMAs alineadas
         // con esas mismas velas, para que el navegador dibuje la curva real.
         j += ",\"velas\":[";
         int desde = n - P_panelVelas;
         if(desde < 0)
            desde = 0;
         for(int k = desde; k < n; k++)
           {
            if(k > desde)
               j += ",";
            j += "[" + IntegerToString((long)r[k].time) + ","
               + DoubleToString(r[k].open, 2) + ","
               + DoubleToString(r[k].high, 2) + ","
               + DoubleToString(r[k].low, 2) + ","
               + DoubleToString(r[k].close, 2) + "]";
           }
         j += "],\"ema\":[";
         for(int k = desde; k < n; k++)
           {
            if(k > desde)
               j += ",";
            j += "[" + DoubleToString(e30[k], 2) + ","
               + DoubleToString(e50[k], 2) + ","
               + DoubleToString(e100[k], 2) + "]";
           }
         j += "]}";
        }
      j += "]}";
     }
   j += "]}";

   int h = FileOpen("panel_estado.json", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
     {
      Log("no pude escribir panel_estado.json (error " + IntegerToString(GetLastError()) + ")");
      return;
     }
   FileWriteString(h, j);
   FileClose(h);
  }

// En vivo el EA trabaja con OnTimer; en el tester los timers no existen y
// el pulso lo da OnTick (una vez por barra M1 con Model=1).
void OnTick()
  {
   if(g_bt)
      BtPaso();
  }

void OnTimer()
  {
   // Embudo: una linea por vela M3 cerrada con lo acumulado de todos los
   // simbolos. Se imprime aqui y no dentro de Revisar porque los contadores
   // son globales y Revisar corre una vez por simbolo.
   if(ArraySize(g_est) > 0 && StringLen(g_est[0].nombre) > 0)
     {
      datetime b3 = iTime(g_est[0].nombre, PERIOD_M3, 0);
      if(b3 > 0 && b3 != g_embBar)
        {
         if(g_embBar != 0)
            EmbLog();
         g_embBar = b3;
        }
      if(b3 > 0 && b3 != g_panelBar)
        {
         PanelEstado();
         // Captura real de la grafica de MT5 (con las EMAs/indicadores tal como
         // las pinta el terminal) para que el panel movil muestre "lo mismo de
         // MT5" y no una reconstruccion. Se sobrescribe en cada vela M3.
         ChartScreenShot(0, "panel_chart.png", 1280, 720);
         g_panelBar = b3;
        }
     }

   int n = ArraySize(g_est);
   for(int i=0; i<n; i++)
      Revisar(i);

   if(g_latidoMin <= 0)
      return;
   datetime ahora = TimeGMT();
   if(g_ultimoLatido == 0)
     {
      g_ultimoLatido = ahora;
      return;
     }
   if((long)ahora - (long)g_ultimoLatido < (long)g_latidoMin * 60)
      return;
   g_ultimoLatido = ahora;

   string txt = "latido:";
   for(int i=0; i<n; i++)
     {
      if(StringLen(g_est[i].nombre) == 0)
         continue;
      MqlRates r[];
      int m = CopyRates(g_est[i].nombre, g_tfArr[g_iRef], 0, 2, r);
      string precio = (m > 0) ? FmtPrecio(r[m-1].close) : "sin datos";
      int senTot = 0;
      for(int tfi = 0; tfi < g_nTf; tfi++)
         senTot += g_est[i].senales[tfi];
      txt = txt + " " + g_est[i].nombre + "=" + precio
            + "(senales " + IntegerToString(senTot) + ")";
     }
   Log(txt);
   // Estado H1 por simbolo, una vez por latido: evidencia numerica para
   // decidir si el veto por H1 esta midiendo la estructura o una etiqueta vieja.
   for(int i=0; i<n; i++)
     {
      if(StringLen(g_est[i].nombre) == 0)
         continue;
      string eh = EstadoH1(g_est[i].nombre);
      if(StringLen(eh) > 0)
         Log("[H1] " + g_est[i].nombre + ": " + eh);
     }
   if(g_enviarPrecios == 1 && g_tgToken != "" && g_tgChat != "")
      EnviarTelegram(txt);
  }

//--------------------------------------------------------------------
//  Eco de parametros: los mismos numeros, traducidos a minutos por TF.
//--------------------------------------------------------------------
void EcoParametros()
  {
   for(int t = 0; t < g_nTf; t++)
     {
      ENUM_TIMEFRAMES tf = g_tfArr[t];
      int minVel = (PeriodSeconds(tf) * P_hchMinVelas) / 60;
      int maxVel = (PeriodSeconds(tf) * P_hchMaxVelas) / 60;
      int espVel = (PeriodSeconds(tf) * P_hchMaxEspera) / 60;
      Log("[EFECTIVO] " + g_tfTxtArr[t]
          + " HCH{score>=" + DoubleToString(P_hchMinScore, 0)
          + " patron=" + IntegerToString(P_hchMinVelas) + "-" + IntegerToString(P_hchMaxVelas)
          + "v (" + IntegerToString(minVel) + "-" + IntegerToString(maxVel) + " min)"
          + " zigzag=" + DoubleToString(P_hchZZAtr, 1) + "xATR"
          + " ruptura=" + DoubleToString(P_hchBufRuptura, 2) + " ATR"
          + " espera=" + IntegerToString(P_hchMaxEspera) + "v ("
          + IntegerToString(espVel) + " min)}");
      Log("[EFECTIVO] " + g_tfTxtArr[t]
          + " LIQ{swing=" + IntegerToString(P_liqSwing) + "v"
          + " barrido<=" + IntegerToString(P_liqMaxBarrido) + "v"
          + " rebote=" + DoubleToString(P_liqReboteAtr, 2) + "xATR en "
          + IntegerToString(P_liqReboteVelas) + "v ("
          + IntegerToString((PeriodSeconds(tf) * P_liqReboteVelas) / 60) + " min)"
          + " nivel=" + IntegerToString(P_liqMaxEdadNivel) + "v}");
     }
  }

//====================================================================
//  Tendencia mayor (port de serieEstructural + _tendenciaMayor)
//  Pivotes por CIERRE con k=5, confirmados k velas despues, y margen
//  0,25 ATR14 sobre el swing contrario.
//====================================================================
void SerieEstructural(const MqlRates &r[], const int kPivote, const double margenAtr,
                      int &dir[], double &invalida[])
  {
   int n = ArraySize(r);
   ArrayResize(dir, n);
   ArrayResize(invalida, n);
   ArrayInitialize(dir, 0);
   ArrayInitialize(invalida, 0.0);
   if(n < kPivote * 4 + 10)
      return;

   int altos[], bajos[];
   ArrayResize(altos, 0);
   ArrayResize(bajos, 0);
   for(int i = kPivote; i < n - kPivote; i++)
     {
      bool esAlto = true, esBajo = true;
      for(int m = 1; m <= kPivote; m++)
        {
         if(!(r[i].close > r[i-m].close && r[i].close > r[i+m].close))
            esAlto = false;
         if(!(r[i].close < r[i-m].close && r[i].close < r[i+m].close))
            esBajo = false;
         if(!esAlto && !esBajo)
            break;
        }
      if(esAlto)
        {
         int k = ArraySize(altos);
         ArrayResize(altos, k + 1);
         altos[k] = i;
        }
      if(esBajo)
        {
         int k = ArraySize(bajos);
         ArrayResize(bajos, k + 1);
         bajos[k] = i;
        }
     }

   double A[];
   CalcAtr(r, 14, A);

   int d = 0, ia = 0, ib = 0, ultimoAlto = -1, ultimoBajo = -1;
   int na = ArraySize(altos), nb = ArraySize(bajos);
   for(int i = 0; i < n; i++)
     {
      while(ia < na && altos[ia] + kPivote <= i)
        {
         ultimoAlto = altos[ia];
         ia++;
        }
      while(ib < nb && bajos[ib] + kPivote <= i)
        {
         ultimoBajo = bajos[ib];
         ib++;
        }
      double m = (margenAtr > 0 && A[i] > 0) ? margenAtr * A[i] : 0;
      if(ultimoAlto >= 0 && r[i].close > r[ultimoAlto].close + m && d != 1)
         d = 1;
      else if(ultimoBajo >= 0 && r[i].close < r[ultimoBajo].close - m && d != -1)
         d = -1;
      dir[i] = d;
      if(d == 1)
         invalida[i] = (ultimoBajo >= 0) ? r[ultimoBajo].close : 0;
      else if(d == -1)
         invalida[i] = (ultimoAlto >= 0) ? r[ultimoAlto].close : 0;
      else
         invalida[i] = 0;
     }
  }

struct TendMayor
  {
   bool     ok;
   string   tendencia;
   string   fase;
   double   invalida;
   datetime t;
   int      velasRotura;   // velas H1 desde la rotura que sostiene la direccion
  };

TendMayor TendenciaMayor(const string simbolo, const datetime tCierre)
  {
   TendMayor tm;
   tm.ok = false;
   tm.tendencia = "";
   tm.fase = "";
   tm.invalida = 0;
   tm.t = 0;
   tm.velasRotura = 0;

   MqlRates h1[];
   int n = CopyRates(simbolo, PERIOD_H1, 1, 1500, h1);
   if(n < P_emaFondo + 5)
      return tm;

   // ultima vela H1 cuyo cierre ya ocurrio cuando se emitio la senal
   int k = -1;
   for(int i = n - 1; i >= 0; i--)
     {
      if((long)h1[i].time + 3600 <= (long)tCierre)
        {
         k = i;
         break;
        }
     }
   if(k < P_emaFondo)
      return tm;

   int dir[];
   double inv[];
   SerieEstructural(h1, 5, 0.25, dir, inv);

   double cierres[];
   ArrayResize(cierres, n);
   for(int i = 0; i < n; i++)
      cierres[i] = h1[i].close;
   double e30[];
   CalcEma(cierres, P_emaContacto, e30);

   int d = dir[k];
   tm.ok = true;
   tm.t = h1[k].time;
   // antiguedad de la rotura: si la direccion lleva cientos de velas H1 sin
   // renovarse, la etiqueta describe el pasado, no la estructura de ahora.
   int vr = 0;
   if(d != 0)
      for(int j = k; j >= 0; j--)
        {
         if(dir[j] != d)
            break;
         vr = k - j;
        }
   tm.velasRotura = vr;
   tm.invalida = inv[k];
   tm.tendencia = (d == 1) ? "ALCISTA" : ((d == -1) ? "BAJISTA" : "RANGO");
   bool enTendencia = false;
   if(d == 1)
      enTendencia = (h1[k].close >= e30[k]);
   else if(d == -1)
      enTendencia = (h1[k].close <= e30[k]);
   tm.fase = (d == 0) ? "RANGO" : (enTendencia ? "TENDENCIA" : "RETROCESO");
   return tm;
  }

string SufijoTendencia(const TendMayor &tm, const string tfZona)
  {   if(!tm.ok || tfZona == "H1")
      return "";
   string fase = (tm.fase == "TENDENCIA") ? "en tendencia"
                 : ((tm.fase == "RETROCESO") ? "retroceso" : "sin swing");
   return " · H1 " + tm.tendencia + " · " + fase;
  }

// Resumen de una linea del estado H1, para el latido.
string EstadoH1(const string simbolo)
  {
   TendMayor tm = TendenciaMayor(simbolo, TimeGMT());
   if(!tm.ok)
      return "";
   return tm.tendencia + " · " + tm.fase + " · rotura hace "
          + IntegerToString(tm.velasRotura) + " velas H1";
  }
