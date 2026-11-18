//+------------------------------------------------------------------+
//| EstrategiaAdversaria.mq5                                         |
//| EA adversario para cuenta DEMO en MT5 (Windows / GitHub Actions) |
//|                                                                  |
//| Porta la escalera del nucleo del motor (motor-senales/nucleo.js) |
//|   1 / 1R   seductora (salida sobre EMA50 + quiebre con cuerpo)   |
//|   2 / 2R   2o toque a EMA30 (entrada al toque)                   |
//|   3 / 3R   3er toque a EMA30 (entrada al toque)                  |
//|   2B/2RB   quiebre del minimo anterior, entrada en el retesteo   |
//|   3B/3RB   tercer toque + quiebre                                |
//|   la R es RESET (todo junto, igual que 1RE/2RE/3RE)              |
//|                                                                  |
//| No opera: lee velas y manda la senal a Telegram por WebRequest.  |
//| La cuenta demo solo se usa para tener el feed del broker real.   |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "Escalera del video 03 sobre la cuenta DEMO; senal a Telegram."

//--------------------------------------------------------------------
//  Configuracion: se lee de  <datos>/MQL5/Files/adv.cfg
//--------------------------------------------------------------------
string g_tgToken   = "";
string g_tgChat    = "";
string g_simbolos  = "FX Vol 20,FX Vol 40,SFX Vol 20,SFX Vol 40";
string g_tfTxt     = "M5";
int    g_velas     = 3000;
int    g_latidoMin = 15;
int    g_enviarPrecios = 0;   // 1 = enviar snapshot de precios a Telegram en cada latido

// Multi-TF: el EA procesa estas 4 temporalidades en un solo terminal
string           g_tfTxtArr[];
ENUM_TIMEFRAMES  g_tfArr[];
int              g_nTf      = 4;
ENUM_TIMEFRAMES  g_tf      = PERIOD_M5;

//--------------------------------------------------------------------
//  Parametros de la escalera: copiados de PARAMS en nucleo.js
//--------------------------------------------------------------------
int    P_emaContacto       = 30;
int    P_emaTecho          = 50;
int    P_emaFondo          = 100;
int    P_atrPeriodo        = 14;
double P_tolToqueAtr       = 0.30;
int    P_ventanaMin        = 12;
double P_cuerpoMin         = 0.50;
double P_cuerpoMinAtr      = 0.10;
int    P_caducidad         = 3;
int    P_separacionToques  = 2;
int    P_cooldownEntrada   = 8;
double P_extensionMinAtr   = 0.5;
int    P_caducidadEngano   = 12;
int    P_caducidadRetesteo = 3;
double P_tolRetesteoAtr    = 0.30;

datetime g_ultimoLatido = 0;

//--------------------------------------------------------------------
//  Estructuras
//--------------------------------------------------------------------
struct Toque
  {
   int    bar;
   double nivel;
   double extremo;
   double alto;
   double bajo;
  };

struct Secuencia
  {
   bool   engano;
   int    enganoBar;
   double enganoNivel;
   Toque  t1, t2, t3;
   int    nT;
   int    ciclo;
   int    avisados;
   bool   retesteo;
   int    retBar;
   double retNivel;
   double retExtremo;
   int    ultimaEntrada;
  };

struct Evento
  {
   int    bar;
   string lado;
   string patron;
   double precio;
   double invalida;
   double nivel;
   string tendencia;
  };

//--------------------------------------------------------------------
//  Utilidades
//--------------------------------------------------------------------
void Log(const string msg)
  {
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

// La R es de RESET y va pegada delante de la familia: 1 -> 1R, 2B -> 2RB.
string ConReset(const string base, const int ciclo)
  {
   if(ciclo < 1)
      return base;
   if(base == "1")
      return "1R";
   if(base == "2B")
      return "2RB";
   if(base == "3B")
      return "3RB";
   return base + "R";     // 2 -> 2R · 3 -> 3R
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
   StringToCharArray(cuerpo, utf8, 0, StringLen(cuerpo), CP_UTF8);
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
   Log(StringFormat("Telegram: FALLO http=%d error=%d -> queda en pend_*.txt", code, fallo));
   GuardarPendiente(texto);
   return false;
  }

// Si MT5 no deja salir a WebRequest (error 4014: URL no autorizada), el mensaje
// se guarda en un archivo propio (uno por mensaje) y el runner del workflow lo
// manda tal cual. Un archivo por mensaje evita carreras de lectura/escritura
// y hace la entrega fiable.
int g_pendienteSeq = 0;
void GuardarPendiente(const string texto)
  {
   g_pendienteSeq++;
   // Nombre unico: tickcount ms + contador, para que dos mensajes nunca
   // sobrescriban el mismo archivo (evita perdida de senales).
   string nombre = "pend_" + IntegerToString(GetTickCount()) + "_" + IntegerToString(g_pendienteSeq) + ".txt";
   int h = FileOpen(nombre, FILE_WRITE|FILE_TXT|FILE_UNICODE);
   if(h == INVALID_HANDLE)
     {
      Log("no puedo abrir " + nombre + " (error " + IntegerToString(GetLastError()) + ")");
      return;
     }
   FileWrite(h, texto);
   FileClose(h);
   Log("mensaje guardado en " + nombre + " (pendiente de entrega)");
  }

//--------------------------------------------------------------------
//  Configuracion
//--------------------------------------------------------------------
ENUM_TIMEFRAMES TfDeTexto(const string txt)
  {
   string u = txt;
   StringToUpper(u);
   if(u == "M1")  return PERIOD_M1;
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
      else if(k == "tf")
         g_tfTxt = v;
      else if(k == "velas")
         g_velas = (int)StringToInteger(v);
      else if(k == "latido")
         g_latidoMin = (int)StringToInteger(v);
      else if(k == "precios")
         g_enviarPrecios = (int)StringToInteger(v);
     }
   FileClose(h);
   g_tf = TfDeTexto(g_tfTxt);
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
//  Cola de toques (maximo 3, como s.toques en nucleo.js)
//--------------------------------------------------------------------
void NuevaSecuencia(Secuencia &s)
  {
   ZeroMemory(s);
   s.ultimaEntrada = -100000;
  }

bool HayToque(const Secuencia &s)
  {
   return s.nT > 0;
  }

Toque UltimoToque(const Secuencia &s)
  {
   if(s.nT == 3)
      return s.t3;
   if(s.nT == 2)
      return s.t2;
   if(s.nT == 1)
      return s.t1;
   Toque z;
   ZeroMemory(z);
   return z;
  }

void PushToque(Secuencia &s, const Toque &t)
  {
   if(s.nT < 3)
     {
      if(s.nT == 0)
         s.t1 = t;
      else if(s.nT == 1)
         s.t2 = t;
      else
         s.t3 = t;
      s.nT++;
      return;
     }
   s.t1 = s.t2;
   s.t2 = s.t3;
   s.t3 = t;
  }

//--------------------------------------------------------------------
//  Un lado de una vela (espejo del bucle de _escanearCore)
//--------------------------------------------------------------------
void Emitir(Evento &eventos[], const int i, const bool venta, const string patron,
            const double precio, const double invalida, const double nivel,
            const double E30, const double E50, const double E100)
  {
   Evento ev;
   ev.bar       = i;
   ev.lado      = venta ? "VENTA" : "COMPRA";
   ev.patron    = patron;
   ev.precio    = precio;
   ev.invalida  = invalida;
   ev.nivel     = nivel;
   ev.tendencia = Tendencia(precio, E30, E50, E100);
   int t = ArraySize(eventos);
   ArrayResize(eventos, t + 1);
   eventos[t] = ev;
  }

void ProcesarBarra(const MqlRates &r[], const int i, const bool venta,
                   const double &e30[], const double &e50[], const double &e100[],
                   const double &atr[], Secuencia &s, Evento &eventos[])
  {
   double c = r[i].close, h = r[i].high, l = r[i].low, o = r[i].open;
   double atrI = atr[i];
   double E30 = e30[i], E50 = e50[i], E100 = e100[i];
   double extremo = venta ? h : l;

   // 1. el precio se salio del techo (EMA50): nace el engano
   bool salio = venta ? (c > E50) : (c < E50);
   if(salio)
     {
      if(!s.engano)
        {
         s.engano = true;
         s.enganoNivel = venta ? l : h;
        }
      else
         s.enganoNivel = venta ? MathMin(s.enganoNivel, l) : MathMax(s.enganoNivel, h);
      s.enganoBar = i;
      if(s.nT > 0)
        {
         s.ciclo++;
         s.nT = 0;
         s.avisados = 0;
        }
      s.retesteo = false;
     }

   // 1c. retesteo pendiente de la 2B: se espera la vuelta al nivel roto
   if(s.retesteo)
     {
      bool prueba    = venta ? (h >= s.retNivel - P_tolRetesteoAtr * atrI)
                             : (l <= s.retNivel + P_tolRetesteoAtr * atrI);
      bool sigueRoto = venta ? (c < s.retNivel) : (c > s.retNivel);
      if(prueba && sigueRoto)
        {
         bool alineadaAhora = venta ? (c < E30 && E30 <= E50 && E50 <= E100)
                                    : (c > E30 && E30 >= E50 && E50 >= E100);
         if(!alineadaAhora)
           {
            s.retesteo = false;
            return;
           }
         if(i - s.ultimaEntrada < P_cooldownEntrada)
            return;
         Emitir(eventos, i, venta, ConReset("2B", s.ciclo), c, s.retExtremo, s.retNivel,
                E30, E50, E100);
         s.ultimaEntrada = i;
         s.ciclo++;
         s.nT = 0;
         s.avisados = 0;
         s.retesteo = false;
         s.engano = false;
         s.enganoBar = -1;
         s.enganoNivel = 0;
         return;
        }
      if(!sigueRoto || i - s.retBar > P_caducidadRetesteo)
         s.retesteo = false;
      else
         return;   // esperando la vuelta al nivel: la secuencia no se toca
     }

   // 2. la pila EMA tiene que estar alineada en el sentido de la jugada
   bool alineada = venta ? (c < E30 && E30 <= E50 && E50 <= E100)
                         : (c > E30 && E30 >= E50 && E50 >= E100);
   if(!alineada)
     {
      bool invertida = venta ? (E30 > E50) : (E30 < E50);
      if(invertida)
        {
         s.nT = 0;
         s.ciclo = 0;
         s.avisados = 0;
         s.retesteo = false;
         s.engano = false;
         s.enganoBar = -1;
         s.enganoNivel = 0;
        }
      return;
     }

   // 3. toque a la EMA30 que NO supera la EMA50
   bool toca = venta
               ? (extremo >= E30 - P_tolToqueAtr * atrI && extremo <= E50 && c < E30)
               : (extremo <= E30 + P_tolToqueAtr * atrI && extremo >= E50 && c > E30);
   bool hayUltimo = HayToque(s);
   Toque ultimo;
   ZeroMemory(ultimo);
   if(hayUltimo)
      ultimo = UltimoToque(s);

   bool supera = true, extremoEntre = true, continuo = true;
   if(hayUltimo)
     {
      supera = venta ? (l < ultimo.bajo) : (h > ultimo.alto);
      extremoEntre = false;
      for(int k = ultimo.bar + 1; k < i; k++)
        {
         if(venta ? (r[k].low < ultimo.bajo) : (r[k].high > ultimo.alto))
           {
            extremoEntre = true;
            break;
           }
        }
      continuo = venta ? (l < ultimo.bajo - P_extensionMinAtr * atrI)
                       : (h > ultimo.alto + P_extensionMinAtr * atrI);
     }
   bool enfriado = (i - s.ultimaEntrada) >= P_cooldownEntrada;
   bool separado = !hayUltimo || (i - ultimo.bar) >= P_separacionToques;

   if(toca && enfriado && supera && extremoEntre && continuo && separado)
     {
      // "el minimo anterior" = extremo de las N velas previas al toque
      double nivel = 0;
      int desde = i - P_ventanaMin;
      if(desde < 0)
         desde = 0;
      bool primero = true;
      for(int k = desde; k < i; k++)
        {
         if(primero)
           {
            nivel = venta ? r[k].low : r[k].high;
            primero = false;
           }
         else
            nivel = venta ? MathMin(nivel, r[k].low) : MathMax(nivel, r[k].high);
        }
      Toque t;
      t.bar     = i;
      t.nivel   = nivel;
      t.extremo = extremo;
      t.alto    = h;
      t.bajo    = l;
      PushToque(s, t);

      // la 2 y la 3 son senales: el toque se entrega como entrada
      if(s.nT >= 2 && s.avisados != s.nT)
        {
         s.avisados = s.nT;
         // Precio de entrada = extremo del toque (mecha), no el cierre: la senal
         // sale mas cerca del nivel real del toque y no arrastra el cierre posterior.
         Emitir(eventos, i, venta, ConReset(IntegerToString(s.nT), s.ciclo), extremo, extremo, nivel,
                E30, E50, E100);
         s.ultimaEntrada = i;
        }
     }

   // 4. quiebre: cierre mas alla del nivel, dentro de la caducidad del toque
   if(!HayToque(s))
      return;
   Toque t4 = UltimoToque(s);
   if(i <= t4.bar || (i - t4.bar) > P_caducidad)
      return;

   bool enganoVivo = s.engano && (i - s.enganoBar) <= P_caducidadEngano;
   string base = "";
   if(s.nT >= 3)
      base = "3B";
   else if(s.nT == 2)
      base = "2B";
   else if(enganoVivo)
      base = "1";
   else
      return;                       // primer toque sin engano: no hay codigo

   double nivelQ = (base == "1") ? s.enganoNivel : t4.nivel;
   if(!(nivelQ > 0))
      return;
   bool rompe = venta ? (c < nivelQ) : (c > nivelQ);
   if(!rompe)
      return;

   // "con cuerpo": la vela que quiebra tiene que ser una vela de verdad
   double cuerpo = MathAbs(c - o);
   double rango  = h - l;
   if(!(rango > 0) || (cuerpo / rango) < P_cuerpoMin || cuerpo < P_cuerpoMinAtr * atrI)
      return;

   // la 2B no se opera al cierre: se espera el retesteo del nivel
   if(base == "2B")
     {
      s.retesteo = true;
      s.retBar = i;
      s.retNivel = nivelQ;
      s.retExtremo = t4.extremo;
      return;
     }

   if((i - s.ultimaEntrada) < P_cooldownEntrada)
      return;

   Emitir(eventos, i, venta, ConReset(base, s.ciclo), c, t4.extremo, nivelQ, E30, E50, E100);
   s.ultimaEntrada = i;
   s.ciclo++;
   s.nT = 0;
   s.avisados = 0;
   s.engano = false;
   s.enganoBar = -1;
   s.enganoNivel = 0;
  }

//--------------------------------------------------------------------
//  Escaneo completo de una serie (puro, como escanear() en nucleo.js)
//--------------------------------------------------------------------
void Escanear(const MqlRates &r[], Evento &eventos[])
  {
   ArrayResize(eventos, 0);
   int n = ArraySize(r);
   if(n < P_emaFondo + 5)
      return;

   double cierres[];
   ArrayResize(cierres, n);
   for(int i=0; i<n; i++)
      cierres[i] = r[i].close;

   double e30[], e50[], e100[], atr[];
   CalcEma(cierres, P_emaContacto, e30);
   CalcEma(cierres, P_emaTecho, e50);
   CalcEma(cierres, P_emaFondo, e100);
   CalcAtr(r, P_atrPeriodo, atr);

   Secuencia venta, compra;
   NuevaSecuencia(venta);
   NuevaSecuencia(compra);

   for(int i = P_emaFondo; i < n; i++)
     {
      if(!(atr[i] > 0) || !(e30[i] > 0) || !(e50[i] > 0) || !(e100[i] > 0))
         continue;
      ProcesarBarra(r, i, true,  e30, e50, e100, atr, venta,  eventos);
      ProcesarBarra(r, i, false, e30, e50, e100, atr, compra, eventos);
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
   if(StringFind(patron, "R") >= 0)
      patron = patron + " (reset)";
   string texto = "";
   texto += Icono(compra) + " <b>" + ev.lado + "</b>\n";
   texto += "<b>1. Activo:</b> " + simbolo + "\n";
   texto += "<b>2. Temporalidad:</b> " + tf + "\n";
   string estrategia = (StringFind(ev.patron, "E") >= 0) ? "Estructura" : "Raptor-v03";
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
   if(n > 2000)
     {
      int h0 = FileOpen("adv_enviados.txt", FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h0 != INVALID_HANDLE)
        {
         for(int i = n - 1000; i <= n; i++)
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
   datetime ultimaBarra[4];   // por cada TF (M3,M5,M15,M30)
   int      senales[4];       // por cada TF
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
      datetime ultima = r[n-1].time;
      if(ultima == g_est[idx].ultimaBarra[tfi])
         continue;
      g_est[idx].ultimaBarra[tfi] = ultima;

      Evento evs[], evsE[];
      Escanear(r, evs);
      EscanearEstructura(r, evsE);

      // candidatos de la vela recien cerrada, de las dos estrategias
      Evento cand[];
      ArrayResize(cand, 0);
      int t1 = ArraySize(evs);
      for(int i=0; i<t1; i++)
         if(evs[i].bar == n - 1)
           {
            int k = ArraySize(cand);
            ArrayResize(cand, k + 1);
            cand[k] = evs[i];
           }
      int t2 = ArraySize(evsE);
      for(int i=0; i<t2; i++)
         if(evsE[i].bar == n - 1)
           {
            int k = ArraySize(cand);
            ArrayResize(cand, k + 1);
            cand[k] = evsE[i];
           }

      long offServidor = (long)TimeTradeServer() - (long)TimeGMT();
      datetime tVelaUTC = (datetime)((long)ultima - offServidor);
      datetime tCierre  = (datetime)((long)ultima + (long)PeriodSeconds(g_tf));

      // una sola senal por vela y lado: gana la de mayor prioridad
      for(int lado = 0; lado < 2; lado++)
        {
         string cual = (lado == 0) ? "VENTA" : "COMPRA";
         int mejor = -1;
         int nc = ArraySize(cand);
         for(int i = 0; i < nc; i++)
           {
            if(cand[i].lado != cual)
               continue;
            if(mejor < 0 || Prioridad(cand[i].patron) > Prioridad(cand[mejor].patron))
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
         string texto = MensajeSenal(g_est[idx].nombre, g_tfTxt, ev, tVelaUTC, extra);
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
//  Arranque
//--------------------------------------------------------------------
int OnInit()
  {
   Log("=== EstrategiaAdversaria 1.00 ===");
   CargarCfg("adv.cfg");
   CargarEnviadas();

   // Multi-TF: inicializar arrays de temporalidades
   ArrayResize(g_tfTxtArr, g_nTf);
   ArrayResize(g_tfArr, g_nTf);
   g_tfTxtArr[0] = "M3";  g_tfArr[0] = PERIOD_M3;
   g_tfTxtArr[1] = "M5";  g_tfArr[1] = PERIOD_M5;
   g_tfTxtArr[2] = "M15"; g_tfArr[2] = PERIOD_M15;
   g_tfTxtArr[3] = "M30"; g_tfArr[3] = PERIOD_M30;
   g_tfTxt = g_tfTxtArr[1];   // default para logs
   g_tf    = g_tfArr[1];

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

   long offServidor = (long)TimeTradeServer() - (long)TimeGMT();
   Log("Desfase del servidor respecto a UTC: " + IntegerToString((int)(offServidor / 3600)) + " h");

   // Snapshot de precios al arrancar (para verificar que los activos coinciden con MT5)
   string snap = "Precios al arrancar:";
   for(int i=0; i<ArraySize(g_est); i++)
     {
      if(StringLen(g_est[i].nombre) == 0)
         continue;
      MqlRates r[];
      int m = CopyRates(g_est[i].nombre, g_tfArr[1], 0, 2, r);
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
   Log("EA detenido (reason " + IntegerToString(reason) + ")");
  }

void OnTimer()
  {
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
      int m = CopyRates(g_est[i].nombre, g_tfArr[1], 0, 2, r);
      string precio = (m > 0) ? FmtPrecio(r[m-1].close) : "sin datos";
      int senTot = 0;
      for(int tfi = 0; tfi < g_nTf; tfi++)
         senTot += g_est[i].senales[tfi];
      txt = txt + " " + g_est[i].nombre + "=" + precio
            + "(senales " + IntegerToString(senTot) + ")";
     }
   Log(txt);
   if(g_enviarPrecios == 1 && g_tgToken != "" && g_tgChat != "")
      EnviarTelegram(txt);
  }

//====================================================================
//  Estrategia ESTRUCTURA (port de escanearEstructura de nucleo.js)
//  Impulso + retroceso + quiebre, con la misma puerta EMA.
//  Codigos: 1E (entrada), 2E/3E (avisos), 2EB/3EB (entradas con quiebre)
//  y sus reseteadas 1RE, 2RE/3RE, 2REB/3REB.
//====================================================================
double P_estImpulsoMinAtr   = 0.8;
int    P_estMinVelasImpulso = 2;
int    P_estMaxVelasImpulso = 3;
double P_estCuerpoImpulso   = 0.35;
int    P_estVentana         = 20;
double P_estRetrocesoMinAtr = 1.0;
double P_estRetrocesoMaxAtr = 3.0;
int    P_estCaducidad       = 30;
int    P_estEspera          = 30;

struct SecuenciaE
  {
   Toque  t1, t2, t3;
   int    nT;
   int    ciclo;
   bool   impulso;
   int    impulsoBar;
   double impulsoOrigen;
   double impulsoExtremo;
   bool   tienePico;
   double pico;
   int    ultimaEntradaBar;
  };

struct Impulso
  {
   bool   ok;
   int    bar;
   double origen;
   double extremo;
  };

void NuevaSecuenciaE(SecuenciaE &s)
  {
   ZeroMemory(s);
   s.ultimaEntradaBar = -100000;
  }

bool HayToqueE(const SecuenciaE &s)
  {
   return s.nT > 0;
  }

Toque UltimoToqueE(const SecuenciaE &s)
  {
   if(s.nT == 3)
      return s.t3;
   if(s.nT == 2)
      return s.t2;
   if(s.nT == 1)
      return s.t1;
   Toque z;
   ZeroMemory(z);
   return z;
  }

void PushToqueE(SecuenciaE &s, const Toque &t)
  {
   if(s.nT < 3)
     {
      if(s.nT == 0)
         s.t1 = t;
      else if(s.nT == 1)
         s.t2 = t;
      else
         s.t3 = t;
      s.nT++;
      return;
     }
   s.t1 = s.t2;
   s.t2 = s.t3;
   s.t3 = t;
  }

Impulso DetectarImpulso(const MqlRates &r[], const int i, const bool venta, const double &atr[])
  {
   Impulso res;
   res.ok = false;
   res.bar = i;
   res.origen = 0;
   res.extremo = 0;
   double atrI = atr[i];
   if(!(atrI > 0))
      return res;
   int minVelas = MathMax(1, P_estMinVelasImpulso);
   int maxVelas = MathMax(minVelas, P_estMaxVelasImpulso);
   int ventana  = P_estVentana;
   if(i - ventana + 1 < 0)
      return res;
   for(int len = minVelas; len <= maxVelas; len++)
     {
      int inicio = i - len + 1;
      if(inicio < 0)
         break;
      double maxH = r[inicio].high, minL = r[inicio].low;
      for(int j = inicio + 1; j <= i; j++)
        {
         if(r[j].high > maxH)
            maxH = r[j].high;
         if(r[j].low < minL)
            minL = r[j].low;
        }
      double movimiento = maxH - minL;
      if(movimiento < P_estImpulsoMinAtr * atrI)
         continue;
      double bodySum = 0;
      for(int j = inicio; j <= i; j++)
         bodySum += MathAbs(r[j].close - r[j].open);
      double ratio = (movimiento > 0) ? bodySum / movimiento : 0;
      if(ratio < P_estCuerpoImpulso)
         continue;
      bool dirOk = venta ? (r[i].close < r[inicio].open) : (r[i].close > r[inicio].open);
      if(!dirOk)
         continue;
      double extremoVentana = venta ? 1.0e300 : -1.0e300;
      for(int j = i - ventana + 1; j <= i; j++)
         extremoVentana = venta ? MathMin(extremoVentana, r[j].low) : MathMax(extremoVentana, r[j].high);
      double extremo = venta ? minL : maxH;
      if(venta ? (extremo > extremoVentana) : (extremo < extremoVentana))
         continue;
      res.ok = true;
      res.bar = i;
      res.origen = venta ? maxH : minL;
      res.extremo = extremo;
      return res;
     }
   return res;
  }

void ProcesarBarraE(const MqlRates &r[], const int i, const bool venta,
                    const double &e30[], const double &e50[], const double &e100[],
                    const double &atr[], SecuenciaE &s, Evento &eventos[])
  {
   double atrI = atr[i];
   double cierre = r[i].close;
   double extremo = venta ? r[i].high : r[i].low;

   // 1. impulso nuevo solo si no hay uno vivo y paso el enfriamiento
   bool impulsoDetectado = false;
   if(!s.impulso && (i - s.ultimaEntradaBar) >= P_estEspera)
     {
      Impulso imp = DetectarImpulso(r, i, venta, atr);
      if(imp.ok)
        {
         s.impulso = true;
         s.impulsoBar = i;
         s.impulsoOrigen = imp.origen;
         s.impulsoExtremo = imp.extremo;
         s.tienePico = false;
         s.pico = 0;
         impulsoDetectado = true;
        }
     }
   if(!s.impulso)
      return;
   // la vela que forma el impulso no puede sembrar su propio retroceso
   if(impulsoDetectado)
      return;

   // 2. techo: si el cierre supera el origen del impulso, la pierna se rompio
   double margenTecho = 0.3 * atrI;
   bool sobreTecho = venta ? (cierre > s.impulsoOrigen + margenTecho)
                           : (cierre < s.impulsoOrigen - margenTecho);
   if(sobreTecho)
     {
      s.impulso = false;
      s.impulsoBar = -1;
      s.impulsoOrigen = 0;
      s.impulsoExtremo = 0;
      s.tienePico = false;
      s.nT = 0;
      s.ciclo = 0;
      return;
     }

   // 3. quiebre del nivel del ultimo toque, antes de actualizar la punta
   if(HayToqueE(s))
     {
      Toque t = UltimoToqueE(s);
      if(i > t.bar)
        {
         if((i - t.bar) > P_estCaducidad)
           {
            s.nT = 0;
            s.impulso = false;
            s.tienePico = false;
            return;
           }
         bool rompe = (t.nivel > 0) && (venta ? (cierre < t.nivel) : (cierre > t.nivel));
         if(rompe)
           {
            string base = (s.nT >= 3) ? "3EB" : ((s.nT == 2) ? "2EB" : "1E");
            bool alineada = venta ? (cierre < e30[i] && e30[i] <= e50[i] && e50[i] <= e100[i])
                                  : (cierre > e30[i] && e30[i] >= e50[i] && e50[i] >= e100[i]);
            if(alineada)
               Emitir(eventos, i, venta, ConReset(base, s.ciclo), cierre, t.extremo, t.nivel,
                      e30[i], e50[i], e100[i]);
            s.ciclo++;
            s.ultimaEntradaBar = i;
            s.nT = 0;
            s.impulso = false;
            s.impulsoBar = -1;
            s.impulsoOrigen = 0;
            s.impulsoExtremo = 0;
            s.tienePico = false;
            return;
           }
        }
     }

   // 4. continuacion: punta nueva = la pierna sigue, no hay retroceso
   bool nuevaPunta = venta ? (r[i].low < s.impulsoExtremo) : (r[i].high > s.impulsoExtremo);
   if(nuevaPunta)
     {
      s.impulsoExtremo = venta ? r[i].low : r[i].high;
      s.impulsoBar = i;
      s.tienePico = false;
      return;
     }

   // 5. retroceso: se aleja de la punta sin superar el origen
   bool enRetroceso = venta ? (extremo > s.impulsoExtremo && extremo <= s.impulsoOrigen)
                            : (extremo < s.impulsoExtremo && extremo >= s.impulsoOrigen);
   if(enRetroceso)
     {
      if(!s.tienePico)
        {
         s.tienePico = true;
         s.pico = extremo;
        }
      else
         s.pico = venta ? MathMax(s.pico, extremo) : MathMin(s.pico, extremo);
     }

   // 6. fin del retroceso: primera vela que cierra en la direccion del impulso
   bool reversing = (i >= 1) && (venta ? (r[i].close < r[i-1].close) : (r[i].close > r[i-1].close));
   double retraccion = s.tienePico
                       ? (venta ? (s.pico - s.impulsoExtremo) : (s.impulsoExtremo - s.pico))
                       : 0;
   bool retroValido = (retraccion >= P_estRetrocesoMinAtr * atrI)
                      && (retraccion <= P_estRetrocesoMaxAtr * atrI);

   bool superaAnterior = true;
   if(HayToqueE(s))
     {
      Toque u = UltimoToqueE(s);
      superaAnterior = venta ? (s.pico > u.extremo) : (s.pico < u.extremo);
     }
   bool separado = true;
   if(HayToqueE(s))
     {
      Toque uSep = UltimoToqueE(s);
      separado = ((i - uSep.bar) >= P_separacionToques);
     }
   bool nuevoToque = s.tienePico && retroValido && reversing && separado && superaAnterior;

   if(nuevoToque)
     {
      double nivelQuiebre = s.impulsoExtremo;
      double contacto = s.pico;
      Toque nt;
      nt.bar = i;
      nt.nivel = nivelQuiebre;
      nt.extremo = contacto;
      nt.alto = contacto;
      nt.bajo = nivelQuiebre;
      PushToqueE(s, nt);
      s.tienePico = false;

      // la 2E y la 3E son avisos: solo salen con la pila alineada
      if(s.nT >= 2)
        {
         string codigo = (s.nT == 2) ? ConReset("2E", s.ciclo) : ConReset("3E", s.ciclo);
         bool alineada = venta ? (r[i].close < e30[i] && e30[i] <= e50[i] && e50[i] <= e100[i])
                               : (r[i].close > e30[i] && e30[i] >= e50[i] && e50[i] >= e100[i]);
         if(alineada)
            Emitir(eventos, i, venta, codigo, r[i].close, contacto, nivelQuiebre,
                   e30[i], e50[i], e100[i]);
        }
     }
  }

void EscanearEstructura(const MqlRates &r[], Evento &eventos[])
  {
   ArrayResize(eventos, 0);
   int n = ArraySize(r);
   if(n < P_atrPeriodo + 5)
      return;

   double cierres[];
   ArrayResize(cierres, n);
   for(int i=0; i<n; i++)
      cierres[i] = r[i].close;

   double e30[], e50[], e100[], atr[];
   CalcEma(cierres, P_emaContacto, e30);
   CalcEma(cierres, P_emaTecho, e50);
   CalcEma(cierres, P_emaFondo, e100);
   CalcAtr(r, P_atrPeriodo, atr);

   SecuenciaE venta, compra;
   NuevaSecuenciaE(venta);
   NuevaSecuenciaE(compra);

   for(int i = P_atrPeriodo; i < n; i++)
     {
      if(!(atr[i] > 0))
         continue;
      ProcesarBarraE(r, i, true,  e30, e50, e100, atr, venta,  eventos);
      ProcesarBarraE(r, i, false, e30, e50, e100, atr, compra, eventos);
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
  };

TendMayor TendenciaMayor(const string simbolo, const datetime tCierre)
  {
   TendMayor tm;
   tm.ok = false;
   tm.tendencia = "";
   tm.fase = "";
   tm.invalida = 0;
   tm.t = 0;

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
  {
   if(!tm.ok || tfZona == "H1")
      return "";
   string fase = (tm.fase == "TENDENCIA") ? "en tendencia"
                 : ((tm.fase == "RETROCESO") ? "retroceso" : "sin swing");
   return " · H1 " + tm.tendencia + " · " + fase;
  }

//====================================================================
//  Prioridad cuando el mismo lado da dos codigos en la misma vela
//  (port de prioridadEvento: entrada > aviso y tier A > B > C)
//====================================================================
int Prioridad(const string p)
  {
   if(p == "3E" || p == "3RE")
      return 6;
   if(p == "2E" || p == "2RE")
      return 5;

   int tier = 0;
   double rr = 0;
   if(p == "3RB")      { tier = 3; rr =  0.295; }
   else if(p == "2RB") { tier = 3; rr =  0.149; }
   else if(p == "1")   { tier = 2; rr =  0.067; }
   else if(p == "1R")  { tier = 2; rr =  0.022; }
   else if(p == "3B")  { tier = 2; rr =  0.014; }
   else if(p == "2B")  { tier = 1; rr = -0.060; }
   else if(p == "3R")  { tier = 1; rr = -0.161; }
   else if(p == "2")   { tier = 1; rr = -0.163; }
   else if(p == "2R")  { tier = 1; rr = -0.196; }
   else if(p == "3")   { tier = 1; rr = -0.239; }
   else if(p == "3REB" || p == "3EB")
      tier = 3;
   else if(p == "2REB" || p == "2EB" || p == "1E" || p == "1RE")
      tier = 2;
   else
      return 0;

   return 100 + tier * 10 + (int)MathRound(rr * 10);
  }
