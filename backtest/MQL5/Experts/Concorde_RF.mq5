//+------------------------------------------------------------------+
//|                                                     Concorde.mq5 |
//|        EA multi-estratégia: 4 estratégias independentes (E1-E4), |
//|        cada uma com inputs, magic number e gestão próprios.      |
//|                                                                  |
//|  Módulos globais: sizing por risco % em todas as pernas, fuso    |
//|  auto-detectado (DST no tester), stop diário global por equity,  |
//|  cap de exposição por símbolo/direção, filtro de notícias        |
//|  (CSV no tester / calendário nativo ao vivo), painel visual e    |
//|  reconstrução de estado após restart.                            |
//|                                                                  |
//|  Recomenda-se conta hedge (as estratégias abrem 2 pernas).       |
//+------------------------------------------------------------------+
#property copyright "Concorde EA"
#property link      ""
#property version   "3.03"
#property description "Concorde EA - 4 estratégias independentes num único EA."
#property description "Sizing por risco %, stop diário global por equity, cap de exposição,"
#property description "filtro de notícias e painel de acompanhamento por estratégia."

#include <Trade\Trade.mqh>

//==================================================================
// Capital operável = Saldo + Crédito. Suporta contas financiadas por
// CRÉDITO/bônus (ACCOUNT_BALANCE=0). Em conta normal o crédito é 0,
// então é idêntico ao saldo. Usado em TODO sizing/risco por % e nos
// limites diários — nunca o ACCOUNT_BALANCE puro (que zera com crédito).
//==================================================================
double ConcordeCapital()
  {
   return AccountInfoDouble(ACCOUNT_BALANCE) + AccountInfoDouble(ACCOUNT_CREDIT);
  }



//==================================================================
//                          ENUMERAÇÕES
//==================================================================

// Tipo de cálculo de lote para a estratégia E1.
enum ENUM_E1_LotType
  {
   E1_LOTE_FIXO     = 0,   // Lote fixo por perna
   E1_LOTE_DINAMICO = 1,   // Lote dinâmico (base + degraus de saldo)
   E1_LOTE_RISCO    = 2    // Risco % do capital por perna (v9)
  };

// Tipo de cálculo de lote para a estratégia E2.
enum ENUM_E2_LotType
  {
   E2_LOTE_FIXO     = 0,   // Lote fixo por perna
   E2_LOTE_DINAMICO = 1,   // Lote dinâmico (base + degraus de saldo)
   E2_LOTE_RISCO    = 2    // Risco % do capital por perna (v9)
  };

// Tipo de cálculo de lote para a estratégia E3.
enum ENUM_E3_TipoLote
  {
   E3_LOT_TYPE_FIXED   = 0,
   E3_LOT_TYPE_DYNAMIC = 1,
   E3_LOT_TYPE_RISK    = 2  // Risco % do capital por perna (v9)
  };

// Fonte dos dados de notícias para o filtro.
enum ENUM_NewsSrc
  {
   NEWSSRC_AUTO     = 0,   // AUTO (Calendário no real / CSV no tester)
   NEWSSRC_CSV      = 1,   // Sempre CSV
   NEWSSRC_CALENDAR = 2    // Sempre Calendário nativo
  };

// Formato do arquivo CSV de notícias.
enum ENUM_NewsCsvFmt
  {
   NEWSFMT_FOREXFACTORY = 0,  // ForexFactory (Title,Country,Date,Time,Impact,...)
   NEWSFMT_SIMPLE       = 1   // Simples (Data,Hora,Moeda,Impacto,Titulo)
  };

// Modo de gestão do SL do E2 após TP1 ser atingido.
enum ENUM_E2_PostTP1Mode
  {
   E2_POST_TP1_CANDLE_TRAIL = 0, // Trail por low/high do candle M15 (padrão)
   E2_POST_TP1_BREAKEVEN    = 1, // Apenas move SL para BE; mantém fixo
   E2_POST_TP1_INCREMENTAL  = 2  // BE + trail incremental por candle (estilo E3)
  };

//==================================================================
//   INPUTS - ATIVAÇÃO DE ESTRATÉGIAS (liga/desliga individual)
//==================================================================
input group "=== ATIVAÇÃO DE ESTRATÉGIAS ==="

// Liga/desliga abertura de NOVAS operações na Estratégia 1 (E1).
// Posições e pendentes já existentes continuam sendo gerenciados normalmente.
input bool Estrategia1_Ativada = true;

// Liga/desliga abertura de NOVAS operações na Estratégia 2 (E2).
// v9: a zona de reteste em ATR ressuscitou a estratégia (PF 0.99 -> ~1.5-1.8
// no backtest 2025-26). Religada por padrão com risco reduzido (0.4%/perna).
input bool Estrategia2_Ativada = true;

// Liga/desliga abertura de NOVAS operações na Estratégia 3 (E3).
// Posições já existentes continuam sendo gerenciadas normalmente.
input bool Estrategia3_Ativada = true;

// Liga/desliga abertura de NOVAS operações na Estratégia 4 (E4).
// Posições já existentes continuam sendo gerenciadas normalmente.
input bool Estrategia4_Ativada = true;

//==================================================================
//   INPUTS - CONCORDE GLOBAL: fuso, stop diário global, exposição
//==================================================================
input group "=== CONCORDE - GLOBAL: FUSO / RISCO ==="

// AO VIVO: detectar o fuso do servidor automaticamente (TimeTradeServer vs TimeGMT).
// Resolve horário de verão sozinho. Usado por E1, E3 e filtro de notícias.
input bool   Concorde_AutoGMTLive        = true;

// TESTER (ou auto desligado): offset GMT do servidor no INVERNO (EET/Axi/4XC = 2).
input int    Concorde_GMTInvernoTester   = 2;

// TESTER: somar +1h durante o horário de verão EUROPEU (últ. dom. mar -> últ. dom. out).
// Brokers EET (Axi, 4XC) seguem essa regra. Desligue p/ broker de fuso fixo.
input bool   Concorde_DstEuropeuTester   = true;

// Stop diário GLOBAL por EQUITY: fecha TODAS as posições do Concorde e bloqueia
// novas entradas até o dia seguinte se o equity cair X% do equity de início do dia.
// 8%: com o risco simultâneo máximo das pernas somando ~6%, é freio de
// catástrofe (gap/slippage), não clipper rotineiro. A 6% disparava 26x/ano.
input bool   Concorde_UseStopDiarioGlobal = true;
input double Concorde_StopDiarioGlobalPct = 8.0;

// Máximo de pernas ABERTAS na MESMA direção no MESMO símbolo somando E1+E2+E3
// (cada estratégia abre 2 pernas). 0 = sem limite.
input int    Concorde_MaxPernasMesmaDir  = 4;

//==================================================================
//   INPUTS - FILTRO DE NOTÍCIAS (aplica-se a TODAS as estratégias)
//==================================================================
input group "=== FILTRO DE NOTÍCIAS (todas as estratégias) ==="

// Liga/desliga o filtro de notícias por completo.
input bool            News_Enable          = true;
// Fonte: AUTO usa Calendário nativo no real e CSV no tester (recomendado).
input ENUM_NewsSrc    News_Source          = NEWSSRC_AUTO;
// Minutos ANTES da notícia para fechar/bloquear.
input int             News_MinutesBefore   = 10;
// Minutos DEPOIS da notícia para voltar a liberar.
input int             News_MinutesAfter    = 10;
// Fechar posições abertas (das estratégias) ao entrar na janela.
input bool            News_CloseTrades     = true;
// Impacto mínimo (1=Baixo 2=Médio 3=Alto).
input int             News_MinImpact       = 3;
// Só considerar notícias das moedas do símbolo de cada operação.
input bool            News_OnlySymbolCcy   = true;
// Moedas manuais ex:"USD,EUR" (vazio = automático por símbolo).
input string          News_CurrenciesManual= "";
// Nome do arquivo CSV de notícias.
input string          News_CsvFileName     = "news.csv";
// Ler da pasta COMUM (Common\Files) — recomendado para o tester.
input bool            News_CsvCommonFolder = true;
// Formato do CSV.
input ENUM_NewsCsvFmt News_CsvFormat       = NEWSFMT_FOREXFACTORY;
// Delimitador do CSV.
input string          News_CsvDelimiter    = ",";
// GMT em que estão os horários DENTRO do CSV (FF/faireconomy = 0/GMT).
input int             News_SourceGMTOffset = 0;
// v9: fuso do servidor agora vem do módulo global (Concorde_AutoGMTLive / DST no tester).
// (Real/Calendário) atualizar a cada X minutos.
input int             News_RefreshMin      = 30;
// Logs detalhados do filtro.
input bool            News_VerboseLog      = false;

//==================================================================
//   INPUTS - Estratégia 1: E1 (E1)
//==================================================================
input group "=== ESTRATÉGIA 1 (range noturno + OCO) ==="

// Símbolo a operar. Vazio = usa o símbolo do gráfico.
input string E1_Simbolo                  = "";

// Magic number da E1 (identifica as ordens dessa estratégia na conta).
input int    E1_MagicNumber              = 202512;

// v9: fuso do servidor vem do módulo global (auto ao vivo, DST europeu no tester).

// Horário de fecho forçado em GMT0/UTC, expresso em minutos desde 00:00.
// Ex.: 10:30 GMT = 10*60+30 = 630. Atingida essa hora, fecha posições e pendentes da E1.
input int    E1_HoraSaidaGMT_Minutos     = 600;

// Distância em PIPS acima do range para o BuyStop e abaixo para o SellStop.
input int    E1_BufferRompimentoPips     = 70;

input group "=== ESTRATÉGIA 1 - LOTE ==="

// FIXO: usa só E1_LotePerna1/2. DINAMICO: degraus de saldo. RISCO (v9): % por perna.
input ENUM_E1_LotType E1_TipoLote                = E1_LOTE_RISCO;

// RISCO (v9): % do capital arriscado por PERNA (SL = meio do range). 2 pernas = 2x isso.
input double E1_RiscoPorPernaPct          = 0.8;

// Volume (lotes) da PERNA 1 (modo FIXO). TP cai em E1_AlvoPerna1_R x risco.
input double E1_LotePerna1               = 0.01;

// Volume (lotes) da PERNA 2 (modo FIXO). TP cai em E1_AlvoPerna2_R x risco.
input double E1_LotePerna2               = 0.01;

// DINAMICO: lote por perna quando saldo ainda não atingiu o 1º degrau.
input double E1_LoteDinamicoBasePorPerna = 0.01;

// DINAMICO: USD de SALDO que definem 1 degrau (ex.: 1000 -> a cada 1000 USD soma 1 degrau).
input double E1_UsdPorDegrauSaldo        = 1000.0;

// DINAMICO: incremento de lote em CADA perna por degrau completo.
input double E1_IncLotePorDegrau         = 0.01;

input group "=== ESTRATÉGIA 1 - ALVOS E GESTÃO ==="

// Take-profit MÍNIMO em múltiplos do risco (R = |entrada - SL|). Aplicado às duas pernas.
input double E1_TakeProfitMinimoR        = 3.0;

// Alvo da PERNA 1, em múltiplos de R. Efetivo = max(E1_TakeProfitMinimoR, E1_AlvoPerna1_R).
input double E1_AlvoPerna1_R             = 4.5;

// Alvo da PERNA 2, em múltiplos de R. Efetivo = max(E1_TakeProfitMinimoR, E1_AlvoPerna2_R).
input double E1_AlvoPerna2_R             = 5.0;

// Após TP da perna 1, move o SL da perna 2 para break-even com este offset (em PONTOS).
input int    E1_BreakEvenOffsetPontos    = 3;

// Distância em PONTOS entre o extremo do candle de trail fechado e o novo SL.
input int    E1_TrailBufferPontos        = 2;

// Timeframe usado para amostrar o range 21-00 GMT (cálculo do high/low).
input ENUM_TIMEFRAMES E1_RangeTimeframe  = PERIOD_M1;

// Timeframe usado pelo trailing-stop após o TP da perna 1.
input ENUM_TIMEFRAMES E1_TrailTimeframe  = PERIOD_M15;

//==================================================================
//   INPUTS - Estratégia 2: E2 (E2 - fractal + reteste)
//==================================================================
input group "=== ESTRATÉGIA 2 (intradiária M15) ==="

// Símbolo a operar. Vazio = usa o símbolo do gráfico.
input string          E2_Simbolo                  = "";

// Timeframe principal de operação (M15 recomendado).
input ENUM_TIMEFRAMES E2_Timeframe                = PERIOD_M15;

// Magic number do E2 (identifica as ordens dessa estratégia).
input ulong           E2_MagicNumber              = 202605122;

input group "=== ESTRATÉGIA 2 - LOTE (cada trade abre 2 pernas iguais) ==="

// FIXO: usa só E2_LoteFixoPorPerna. DINAMICO: degraus de saldo. RISCO (v9): % por perna.
input ENUM_E2_LotType E2_TipoLote                 = E2_LOTE_RISCO;

// RISCO (v9): % do capital arriscado por PERNA. 2 pernas = 2x isso.
input double          E2_RiscoPorPernaPct         = 0.8;

// FIXO: lote por perna (cada uma das 2 ordens). Ex.: 0.01 -> 0.02 total.
input double          E2_LoteFixoPorPerna         = 0.01;

// DINAMICO: lote por perna quando saldo ainda não atingiu o 1º degrau.
input double          E2_LoteDinamicoBasePorPerna = 0.01;

// DINAMICO: USD de SALDO que definem 1 degrau (ex.: 1000 -> a cada 1000 USD soma 1 degrau).
input double          E2_UsdPorDegrauSaldo        = 1000.0;

// DINAMICO: incremento de lote em CADA perna por degrau completo.
input double          E2_IncLotePorDegrau         = 0.01;

input group "=== ESTRATÉGIA 2 - FILTROS DE SETUP ==="

// Spread máximo permitido para abrir nova operação (pontos do MT5).
input int    E2_SpreadMaximoPontos                = 100;

// Meia-largura do fractal. 2 -> fractal de 5 velas (i-2 ... i+2).
input int    E2_FractalMeiaLargura                = 2;

// Quantas barras carregar do histórico (para procura de fractais e ATR).
input int    E2_BarrasHistoricoLookback           = 300;

// v9: zona de reteste em MÚLTIPLOS DE ATR (antes era preço absoluto 1.5, hardcoded
// p/ ouro — não funcionava em outro símbolo). 0.35 x ATR(14) M15 ~ equivalente no ouro.
input double E2_ZonaRetesteXAtr                   = 0.35;

// v9: buffer de rompimento em MÚLTIPLOS DE ATR (antes preço absoluto 0.3).
input double E2_BufferRompimentoXAtr              = 0.07;

// Corpo mínimo do candle de rompimento = mult x ATR.
input double E2_CorpoMinimoXAtr                   = 0.18;

// Período do ATR usado para corpo mínimo e pisos de SL/TP.
input int    E2_PeriodoAtr                        = 14;

// Quantas barras após o break ainda permitem concluir o setup.
input int    E2_SetupMaxBarras                    = 24;

// Limite máximo de NOVOS trades E2 por dia.
input int    E2_MaxTradesPorDia                   = 5;

input group "=== ESTRATÉGIA 2 - SESSÕES (hora do SERVIDOR MT5) ==="
input int    E2_SessaoAsia_InicioHora    = 3;   input int E2_SessaoAsia_InicioMinuto    = 0;
input int    E2_SessaoAsia_FimHora       = 11;  input int E2_SessaoAsia_FimMinuto       = 0;
input int    E2_SessaoLondres_InicioHora = 11;  input int E2_SessaoLondres_InicioMinuto = 0;
input int    E2_SessaoLondres_FimHora    = 16;  input int E2_SessaoLondres_FimMinuto    = 30;
input int    E2_SessaoNY_InicioHora      = 16;  input int E2_SessaoNY_InicioMinuto      = 30;
input int    E2_SessaoNY_FimHora         = 23;  input int E2_SessaoNY_FimMinuto         = 0;

// Lista de HORAS do servidor (0-23) onde NÃO abrir novos setups E2.
input string E2_HorasBloqueadasServidor           = "4,5,11,12,13,14,15,16,22,23";

input group "=== ESTRATÉGIA 2 - ALVOS, BREAK-EVEN E TRAILING ==="

// Alvo da PERNA 1 quando não houver fractal útil (multiplicador de R).
input double E2_AlvoFallback1_R                   = 1.0;

// Alvo da PERNA 2 quando não houver 2º fractal útil (multiplicador de R).
input double E2_AlvoFallback2_R                   = 2.0;

// Break-even: SL = entrada +/- offset (em PONTOS).
input double E2_BreakEvenOffsetPontos             = 50;

// Trailing: SL fica X pontos abaixo (compra) / acima (venda) da vela M15 fechada.
input double E2_TrailPadPontos                    = 30;

// Modo de gestão do SL após TP1: CANDLE_TRAIL=trail por low/high M15; BREAKEVEN=BE fixo; INCREMENTAL=BE+X pontos/candle.
input ENUM_E2_PostTP1Mode E2_PostTP1Mode          = E2_POST_TP1_BREAKEVEN;
// Modo INCREMENTAL: pontos por candle M15 adicionados ao SL de BE a cada vela após TP1.
input double              E2_TrailIncremPontos    = 20.0;

input group "=== ESTRATÉGIA 2 - DISTÂNCIAS MÍNIMAS DE STOP ==="

// Piso entrada->SL em PONTOS. 0 = desliga este lado.
input int    E2_MinStopLossPontos                 = 0;
// Piso entrada->TP1 em PONTOS. 0 = desliga.
input int    E2_MinTakeProfit1Pontos              = 0;
// Piso entrada->TP2 em PONTOS. 0 = desliga.
input int    E2_MinTakeProfit2Pontos              = 0;

// Piso adicional para SL como múltiplo do ATR.
input double E2_MinStopLossXAtr                   = 0.38;
// Piso adicional para TP1 como múltiplo do ATR.
input double E2_MinTakeProfit1XAtr                = 0.42;
// Piso adicional para TP2 (medido desde a entrada) como múltiplo do ATR.
input double E2_MinTakeProfit2XAtr                = 0.88;
// Distância mínima entre TP1 e TP2 = mult x ATR (evita TPs colados).
input double E2_MinDistanciaEntreTpsXAtr          = 0.14;

input group "=== ESTRATÉGIA 2 - FILTROS EXTRA ==="

// Razão mínima (TP1-entrada)/(entrada-SL). 0 desliga.
input double E2_MinRRTakeProfit1                  = 0.32;

// Limita o TP2 a no máximo X x risco. 0 = sem teto.
input double E2_MaxAlvoTp2_R                      = 5.0;

// Não abrir se range[1] > mult x ATR. 0 = desliga filtro.
input double E2_MaxRangeSinalXAtr                 = 3.5;

// Filtro de tendência H1 (EMA): compra só acima, venda só abaixo. Default OFF.
input bool   E2_UsarFiltroEmaH1                   = false;
input int    E2_PeriodoEmaH1                      = 50;

// Bloqueia novas operações às quartas-feiras (default OFF).
input bool   E2_PularQuartaFeira                  = false;

// Mostra comentário de status no canto superior do gráfico.
input bool   E2_MostrarStatusGrafico              = true;

//==================================================================
//   INPUTS - Estratégia 3: E3 (E3 - London Breakout)
//==================================================================
input group "=== ESTRATÉGIA 3 (breakout de sessão) ==="

// FIXO: usa só E3_LoteFixoTotal. DINAMICO: degraus de saldo. RISK (v9): % por perna.
input ENUM_E3_TipoLote E3_TipoLote                 = E3_LOT_TYPE_RISK;

// RISK (v9): % do capital arriscado por PERNA (SL = ATR x E3_StopLossXAtr). 2 pernas = 2x.
// 0.6: E3 é a estratégia mais consistente pós-fix do range (PF 1.8-1.9).
input double  E3_RiscoPorPernaPct                 = 1.2;

// FIXO: lote TOTAL da operação (dividido 50/50 entre as 2 pernas).
input double  E3_LoteFixoTotal                    = 0.02;

// DINAMICO: lote total quando saldo ainda não atingiu o 1º degrau.
input double  E3_LoteDinamicoBaseTotal            = 0.01;

// DINAMICO: USD de SALDO que definem 1 degrau (default 1000 USD).
input double  E3_UsdPorDegrauSaldo                = 1000.0;

// DINAMICO: incremento de lote TOTAL por degrau completo.
input double  E3_IncLotePorDegrau                 = 0.01;

// Magic number da PERNA 1 do E3. A perna 2 usa E3_MagicNumber+1.
// v9: era 12345 (genérico, risco de colisão com outro EA na mesma conta).
// ATENÇÃO: se houver posições abertas do E3 antigo, feche-as antes de trocar,
// ou ajuste este input de volta para 12345.
input int     E3_MagicNumber                      = 202533;

// Slippage permitido (em PONTOS).
input int     E3_SlippagePontos                   = 3;

// Spread máximo permitido em "pips" (internamente convertido para pontos).
input double  E3_SpreadMaximoPips                 = 100.0;

// Sufixo do símbolo a anexar ao _Symbol (ex.: ".x"). Vazio = sem sufixo.
input string  E3_SufixoSimbolo                    = "";

input group "=== ESTRATÉGIA 3 - CONFIGURAÇÕES DE BREAKOUT ==="

// Sessão asiática em hora GMT.
input int     E3_SessaoAsia_InicioGMT             = 0;
input int     E3_SessaoAsia_FimGMT                = 4;

// Sessão de Londres em hora GMT (janela onde o breakout é executado).
input int     E3_SessaoLondres_InicioGMT          = 8;
input int     E3_SessaoLondres_FimGMT             = 10;

// Stop-loss inicial = ATR x este multiplicador.
input double  E3_StopLossXAtr                     = 6.0;

// Alvo da PERNA 1 em múltiplos de R.
input double  E3_AlvoPerna1_R                     = 2.9;

// Alvo da PERNA 2 em múltiplos de R.
input double  E3_AlvoPerna2_R                     = 4.3;

input group "=== ESTRATÉGIA 3 - GESTÃO DE RISCO ==="

// Stop diário em % do saldo do início do dia.
input double  E3_StopDiarioPercent                = 6.0;

// Ativa fechamento programado de fim-de-dia (no horário do SERVIDOR).
input bool    E3_AtivarFechamentoFimDia           = false;

// Hora do SERVIDOR (0-23) a partir da qual o fechamento programado dispara.
input int     E3_HoraFechamentoServidor           = 23;

// Ativa o break-even na PERNA 2 quando a PERNA 1 fecha no TP.
input bool    E3_AtivarBreakEven                  = true;

// Ativa o trailing-stop incremental por candle M15 (depois do BE).
input bool    E3_AtivarTrailingStop               = true;

// Break-even: SL fica X pips acima (compra) / abaixo (venda) da entrada.
input double  E3_BreakEvenBufferPips              = 9.0;

// Trailing: PONTOS somados/subtraídos ao SL a cada candle M15 fechado após o BE.
input double  E3_TrailingIncrementoPontos         = 20.0;

input group "=== ESTRATÉGIA 3 - ATR DINÂMICO ==="

// A cada novo candle E3_TimeframeAtrUpdate, recalcula o TP mantendo o RR sobre o ATR atual.
input bool    E3_AtivarAtrDinamico                = true;
input ENUM_TIMEFRAMES E3_TimeframeAtrUpdate       = PERIOD_M15;

input group "=== ESTRATÉGIA 3 - AVANÇADOS ==="

// Período do ATR usado pelo E3. v9: testado empiricamente 1 vs 3 vs 14 (Axi 1 ano,
// real ticks): ATR(1) rendeu mais (E3 PF 1.40 vs 1.07 com 14). Mantido 1.
input int     E3_PeriodoAtr                       = 1;

// v9: range mínimo asiático em MÚLTIPLOS DE ATR (antes 0.0003 em preço — valor de
// FX que no ouro era sempre verdadeiro, i.e., filtro morto). 0 = desligado.
input double  E3_MinRangeAsiaXAtr                 = 0.0;

// v9: fuso do servidor vem do módulo global (auto ao vivo, DST europeu no tester).

//==================================================================
//   INPUTS - Estratégia 4 (multimoedas H1)
//==================================================================
input group "=== ESTRATÉGIA 4 (multimoedas H1) ==="

// Sufixo do broker (4XC = xx). Deixe vazio se não houver.
input string  E4_SymbolSuffix = "";

// Timeframe de operação.
input ENUM_TIMEFRAMES E4_Timeframe = PERIOD_H1;

// Número mágico da estratégia E4 (não conflita com as outras).
input long    E4_MagicNumber   = 550555;

// Spread máximo em pontos (0 = sem limite).
input int     E4_MaxSpreadPts  = 0;

input group "=== ESTRATÉGIA 4 - SINAL / SAÍDA (comum a todos os pares) ==="
input int     E4_Period        = 2;     // Período do indicador (padrão 2)
input double  E4_SellLevel     = 90.0;  // Venda quando indicador > este nível
input double  E4_ExitShort     = 35.0;  // Saída da venda quando indicador < este nível
input int     E4_ExitMA        = 5;     // MM de saída (preço fecha acima/abaixo)
input bool    E4_UseMAExit     = true;  // Usar saída pela MM de 5
input bool    E4_AllowLong     = true;  // Permitir compras
input bool    E4_AllowShort    = true;  // Permitir vendas

input group "=== ESTRATÉGIA 4 - RISCO ==="
input bool    E4_UseStop       = true;  // Usar stop de proteção por ATR
input int     E4_ATRPeriod     = 14;    // Período do ATR
input double  E4_RiskPercent   = 2.0;   // Risco por trade (% do saldo) — v9: 0.8 (era 1.0)
input double  E4_FixedLots     = 0.10;  // Lote fixo (usado se stop desligado)

// v9.1: lote DINÂMICO por degraus de saldo (quando ligado, sobrepõe o risco %;
// o stop ATR continua sendo colocado). Igual ao modo DINAMICO das outras estratégias.
input bool    E4_UseDynLots    = false; // Usar lote dinâmico por degraus
input double  E4_DynBaseLots   = 0.01;  // Lote base (abaixo do 1º degrau)
input double  E4_UsdPorDegrau  = 1000.0;// USD de capital por degrau
input double  E4_DynIncLots    = 0.01;  // Incremento de lote por degrau

input group "=== ESTRATÉGIA 4 - PROTEÇÕES ==="
input bool    E4_UseDailyLock    = false;  // Trava de perda diária (v6: OFF por padrão)
input double  E4_DailyLossPct    = 3.0;    // Perda max do dia (% do saldo inicial do dia)
input bool    E4_UseDDLock       = false;  // Trava de drawdown máximo (v6: OFF por padrão)
input double  E4_MaxDDPct        = 15.0;   // Drawdown max do pico de equity (%)
input bool    E4_BlockRollover   = true;   // Bloquear entradas no rollover (23h-0h servidor)
input string  E4_HorasBloqueadasGMT = "8,18,22";      // Horas GMT sem novas entradas (lista "8,18"; vazio = nenhuma)
input bool    E4_FridayClose     = true;   // Fechar tudo (desta estratégia) sexta à noite
input int     E4_FridayCloseHour = 22;     // Hora (servidor) p/ fechar sexta
input int     E4_MaxBarsInTrade  = 0;      // Saída por tempo: barras max na posição (0 = off)
input bool    E4_UseBreakEven    = false;  // Mover SL para breakeven
input double  E4_BEAtrTrigger    = 1.0;    // Breakeven após X*ATR a favor

input group "=== ESTRATÉGIA 4 - Par 1 ==="
input bool    E4_Use1     = true;     // Operar este par
input string  E4_Sym1     = "EURUSD"; // Nome base do par (sem sufixo)
input double  E4_Buy1     = 7;        // Nível de compra
input int     E4_Trend1   = 225;      // MM de tendência
input double  E4_ExitL1   = 80;       // Nível de saída da compra
input double  E4_ATR1     = 2.5;      // ATR x SL

input group "=== ESTRATÉGIA 4 - Par 2 ==="
input bool    E4_Use2     = true;     // Operar este par
input string  E4_Sym2     = "USDCAD"; // Nome base do par
input double  E4_Buy2     = 11;       // Nível de compra
input int     E4_Trend2   = 100;      // MM de tendência
input double  E4_ExitL2   = 60;       // Nível de saída da compra
input double  E4_ATR2     = 2.5;      // ATR x SL

input group "=== ESTRATÉGIA 4 - Par 3 ==="
input bool    E4_Use3     = true;     // Operar este par
input string  E4_Sym3     = "USDJPY"; // Nome base do par
input double  E4_Buy3     = 14;       // Nível de compra
input int     E4_Trend3   = 125;      // MM de tendência
input double  E4_ExitL3   = 60;       // Nível de saída da compra
input double  E4_ATR3     = 2.5;      // ATR x SL

input group "=== ESTRATÉGIA 4 - Par 4 ==="
input bool    E4_Use4     = true;     // Operar este par
input string  E4_Sym4     = "AUDUSD"; // Nome base do par
input double  E4_Buy4     = 14;       // Nível de compra
input int     E4_Trend4   = 125;      // MM de tendência
input double  E4_ExitL4   = 60;       // Nível de saída da compra
input double  E4_ATR4     = 2.5;      // ATR x SL

input group "=== PAINEL CONCORDE EA ==="

// Mostrar painel visual no gráfico.
input bool    Panel_Mostrar                       = true;

// Canto do gráfico onde o painel é exibido.
input ENUM_BASE_CORNER Panel_Canto                = CORNER_LEFT_UPPER;

// Distância em pixels do canto X.
input int     Panel_X                            = 10;

// Distância em pixels do canto Y.
input int     Panel_Y                            = 30;

//==================================================================
//                       VARIÁVEIS GLOBAIS
//==================================================================

// ----- E1 -----
CTrade   e1_trade;
string   g_e1_symbol;
double   g_e1_point;
int      g_e1_digits;
double   g_e1_pip_size;
double   g_e1_volume_min;
double   g_e1_volume_max;
double   g_e1_volume_step;
int      g_e1_pending_gmt_day_index = -1;
ulong    g_e1_bs_tp3 = 0, g_e1_bs_tp5 = 0;
ulong    g_e1_ss_tp3 = 0, g_e1_ss_tp5 = 0;
bool     g_e1_trail_armed = false;
bool     g_e1_be_done = false;
datetime g_e1_last_trail_bar_time = 0;
string   g_e1_comment = "";

#define E1_COMMENT_TP3 "E1_TP3"
#define E1_COMMENT_TP5 "E1_TP5"

// ----- E2 -----
CTrade     e2_trade;
string     g_e2_sym;
datetime   g_e2_lastBarTime = 0;
int        g_e2_atrHandle   = INVALID_HANDLE;
int        g_e2_maH1Handle  = INVALID_HANDLE;
datetime   g_e2_dayKey      = 0;
int        g_e2_tradesToday = 0;
bool       g_e2_twoLegOpen  = false;
bool       g_e2_beTrailActive = false;
double     g_e2_beStopPrice   = 0.0;   // SL inicial do BE (p/ trail incremental)
int        g_e2_incremCount   = 0;     // candles desde o BE (p/ trail incremental)
bool       g_e2_blockHour[24];
string     g_e2_comment     = "";

enum E2_SetupState
  {
   E2_ST_IDLE = 0,
   E2_ST_BULL_BREAK,
   E2_ST_BULL_WAIT,
   E2_ST_BEAR_BREAK,
   E2_ST_BEAR_WAIT
  };
E2_SetupState g_e2_state    = E2_ST_IDLE;
int           g_e2_breakAge = 0;
double        g_e2_flipLevel = 0.0;
bool          g_e2_retestTouched = false;

// ----- E3 -----
string   g_e3_sym;
double   g_e3_pip, g_e3_pipFactor;
int      g_e3_digits;
double   g_e3_dailyStartBalance;
datetime g_e3_lastTradeDay;
bool     g_e3_dailyStopHit       = false;
double   g_e3_asiaHigh, g_e3_asiaLow;
bool     g_e3_breakoutSetup      = false;
datetime g_e3_setupTime;
bool     g_e3_dailyTradeExecuted = false;
ulong    g_e3_tp1Ticket          = 0;
ulong    g_e3_tp2Ticket          = 0;
double   g_e3_entryPrice         = 0;
bool     g_e3_tp1Hit             = false;
bool     g_e3_breakEvenSet       = false;
datetime g_e3_lastCandleTime     = 0;
double   g_e3_beStopLoss         = 0.0;
int      g_e3_candleCount        = 0;
datetime g_e3_lastEndOfDayCloseDay = 0;
datetime g_e3_lastATRUpdateCandle  = 0;
int      g_e3_atrHandle          = INVALID_HANDLE;
string   g_e3_comment            = "";

// ----- RSI (Estratégia 4 - E4 Multi) -----
CTrade e4_trade;
#define E4_MAX_SYMS 4

struct E4_SymCfg
  {
   bool      use;
   string    symbol;     // nome completo (base + sufixo)
   double    buy;
   int       trendMA;
   double    exitLong;
   double    atrMult;
   int       hRSI, hTrendMA, hExitMA, hATR;
   datetime  lastBar;
  };
E4_SymCfg g_e4_cfg[E4_MAX_SYMS];
int        g_e4_nActive = 0;
bool       g_e4_enabled = false;   // false = nenhum par válido (estratégia dormente)

// estado das travas de perda da Estratégia 4
double   g_e4_dayStartBal = 0;
int      g_e4_curDay      = -1;
double   g_e4_eqPeak      = 0;
bool     g_e4_ddLocked    = false;
string   g_e4_comment     = "";

// ----- FILTRO DE NOTÍCIAS -----
struct NewsEvent
  {
   datetime time;     // horário do evento já convertido p/ hora do SERVIDOR
   string   ccy;      // moeda (USD, EUR, ...)
   int      impact;   // 1=Baixo 2=Médio 3=Alto
   string   title;
  };
NewsEvent g_news[];
int       g_news_count       = 0;
bool      g_news_loaded      = false;
datetime  g_news_lastRefresh = 0;
datetime  g_news_lastCsvDay  = 0;
CTrade    g_news_trade;
// cache de blackout por símbolo (recalcula 1x por minuto por símbolo)
string    g_news_cacheSym[16];
bool      g_news_cacheVal[16];
int       g_news_cacheN      = 0;
datetime  g_news_cacheMinute = 0;
int       g_news_srvOffset   = 0;   // fuso do servidor efetivo (auto ou manual)

// ----- PAINEL -----
datetime g_panel_lastBarTime = 0;  // controla atualização por candle

//==================================================================
//  MÓDULO GLOBAL v9: fuso auto+DST, stop diário global, exposição,
//  lote por risco %. Compartilhado por todas as estratégias.
//==================================================================

// Dia do mês do último domingo de um mês de 31 dias (março/outubro).
int Concorde_LastSundayDay(const int year, const int month)
  {
   MqlDateTime st;
   st.year = year; st.mon = month; st.day = 31;
   st.hour = 12; st.min = 0; st.sec = 0;
   datetime t = StructToTime(st);
   MqlDateTime d2; TimeToStruct(t, d2);
   return 31 - d2.day_of_week;   // day_of_week: 0=domingo
  }

// Horário de verão europeu: último domingo de março 01:00 UTC até
// último domingo de outubro 01:00 UTC.
bool Concorde_IsEuDst(const datetime gmtNow)
  {
   MqlDateTime dt; TimeToStruct(gmtNow, dt);
   if(dt.mon < 3 || dt.mon > 10) return false;
   if(dt.mon > 3 && dt.mon < 10) return true;
   const int lastSun = Concorde_LastSundayDay(dt.year, dt.mon);
   if(dt.mon == 3)
      return (dt.day > lastSun || (dt.day == lastSun && dt.hour >= 1));
   return (dt.day < lastSun || (dt.day == lastSun && dt.hour < 1));
  }

// Offset GMT do servidor (horas). Ao vivo: auto (TimeTradeServer vs TimeGMT).
// Tester: base de inverno + regra DST europeia (brokers EET como Axi/4XC).
int Concorde_SrvGmtOffset()
  {
   static datetime s_lastCalc = 0;
   static int      s_cached   = 3;
   datetime now = TimeCurrent();
   if(s_lastCalc != 0 && now - s_lastCalc < 300) return s_cached;
   s_lastCalc = now;

   const bool tester = (bool)MQLInfoInteger(MQL_TESTER);
   if(!tester && Concorde_AutoGMTLive)
     {
      long diff = (long)TimeTradeServer() - (long)TimeGMT();
      int off = (int)MathRound((double)diff / 3600.0);
      if(off < -12) off = -12;
      if(off > 14)  off = 14;
      s_cached = off;
      return s_cached;
     }
   int off = Concorde_GMTInvernoTester;
   // GMT aproximado com offset de inverno: erro <=1h, irrelevante p/ regra por dia.
   datetime gmtApprox = now - (datetime)(off * 3600);
   if(Concorde_DstEuropeuTester && Concorde_IsEuDst(gmtApprox)) off += 1;
   s_cached = off;
   return s_cached;
  }

// Lote para arriscar riskPct% do capital com SL a slDistPrice (em preço).
// Devolve fallbackLots se os dados do símbolo não permitirem calcular.
double Concorde_LotsByRisk(const string sym, const double slDistPrice,
                         const double riskPct, const double fallbackLots)
  {
   if(slDistPrice <= 0.0 || riskPct <= 0.0) return fallbackLots;
   double riskMoney = ConcordeCapital() * riskPct / 100.0;
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return fallbackLots;
   double valuePerLot = (slDistPrice / tickSize) * tickValue;
   if(valuePerLot <= 0) return fallbackLots;
   double lots = riskMoney / valuePerLot;
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double stp  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(stp > 0) lots = MathFloor(lots / stp) * stp;
   return MathMax(minL, MathMin(maxL, lots));
  }

// Pernas abertas na mesma direção no símbolo, somando E1(E1)+E2(E2)+E3(E3).
int Concorde_CountLegsSameDir(const string sym, const bool isBuy)
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      bool ours = (m == (long)E1_MagicNumber || m == (long)E2_MagicNumber
                || m == (long)E3_MagicNumber  || m == (long)E3_MagicNumber + 1);
      if(!ours) continue;
      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((isBuy && pt == POSITION_TYPE_BUY) || (!isBuy && pt == POSITION_TYPE_SELL)) c++;
     }
   return c;
  }

// true = pode abrir mais newLegs pernas nessa direção sem estourar o cap.
bool Concorde_CanOpenLegs(const string sym, const bool isBuy, const int newLegs)
  {
   if(Concorde_MaxPernasMesmaDir <= 0) return true;
   return (Concorde_CountLegsSameDir(sym, isBuy) + newLegs <= Concorde_MaxPernasMesmaDir);
  }

// ----- Stop diário global por equity -----
double   g_glob_dayStartEq = 0.0;
int      g_glob_day        = -1;
bool     g_glob_stopHit    = false;
CTrade   g_glob_trade;

bool Concorde_GlobalStopActive()
  {
   return (Concorde_UseStopDiarioGlobal && g_glob_stopHit);
  }

void Concorde_GlobalStopCheck()
  {
   if(!Concorde_UseStopDiarioGlobal) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_glob_day)
     {
      g_glob_day        = dt.day_of_year;
      g_glob_dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
      g_glob_stopHit    = false;
     }
   if(g_glob_stopHit || g_glob_dayStartEq <= 0.0) return;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_glob_dayStartEq * (1.0 - Concorde_StopDiarioGlobalPct / 100.0)) return;

   g_glob_stopHit = true;
   PrintFormat("CONCORDE STOP DIÁRIO GLOBAL: equity %.2f <= %.2f (-%.1f%% do início do dia). Fechando tudo.",
               eq, g_glob_dayStartEq * (1.0 - Concorde_StopDiarioGlobalPct / 100.0),
               Concorde_StopDiarioGlobalPct);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(!News_IsOurMagic(m)) continue;
      g_glob_trade.SetExpertMagicNumber(m);   // deal de saída herda o magic (painel)
      g_glob_trade.PositionClose(t);
     }
   E1_CancelPendings();
  }

//==================================================================
//                PAINEL VISUAL - CONCORDE EA
//==================================================================

#define PANEL_PREFIX   "ConcordePanel_"
#define PANEL_FONT     "Consolas"
#define PANEL_FONT_SZ  8

// Cores do painel - paleta escura idêntica ao screenshot de referência
#define CLR_BG            C'18,20,28'      // fundo principal, quase preto azulado
#define CLR_HEADER_BG     C'12,14,20'      // header ligeiramente mais escuro
#define CLR_BORDER        C'40,45,60'      // borda externa sutil
#define CLR_DIVIDER       C'35,38,50'      // divisores entre seções
#define CLR_GOLD          C'235,195,75'    // dourado do header e TOTAL
#define CLR_WHITE         C'235,235,240'   // valores brancos (saldo/equity)
#define CLR_GRAY_LBL      C'130,135,155'   // labels pequenos (Dia, Acumulado, Saldo, Lote)
#define CLR_GRAY_DIM      C'90,95,110'     // estratégia desativada
#define CLR_GREEN         C'80,220,130'    // P&L positivo
#define CLR_RED           C'235,90,90'     // P&L negativo

// Cores das barras verticais e nomes das estratégias
#define CLR_STRAT1        C'225,105,55'    // E1: laranja-vermelho
#define CLR_STRAT2        C'225,75,140'    // E2: magenta-rosa
#define CLR_STRAT3        C'155,95,205'    // E3: roxo
#define CLR_STRAT4        C'75,170,225'    // E4: azul
#define CLR_STRAT_TOTAL   C'235,195,75'    // TOTAL: dourado

// Largura do painel (px)
#define PANEL_W        270

void Panel_DeleteAll()
  {
   ObjectsDeleteAll(0, PANEL_PREFIX);
  }

void Panel_CreateRect(const string name, int x, int y, int w, int h,
                      color bg, color border = CLR_BORDER, int border_w = 1)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,      Panel_Canto);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,        h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,        border_w);
   // BACK=false → renderiza em PRIMEIRO PLANO, sobre os candles (painel opaco).
   ObjectSetInteger(0, name, OBJPROP_BACK,         false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,       true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,       0);
  }

void Panel_CreateLabel(const string name, int x, int y,
                       const string text, color clr,
                       int font_sz = PANEL_FONT_SZ,
                       uint anchor = ANCHOR_LEFT_UPPER)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,    Panel_Canto);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
   ObjectSetString (0, name, OBJPROP_FONT,      PANEL_FONT);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  font_sz);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,    anchor);
   ObjectSetInteger(0, name, OBJPROP_BACK,      false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
   // Labels acima dos retângulos (zorder 0) → ficam sempre visíveis.
   ObjectSetInteger(0, name, OBJPROP_ZORDER,    10);
  }

void Panel_SetLabel(const string name, const string text, color clr)
  {
   if(ObjectFind(0, name) < 0) return;
   ObjectSetString (0, name, OBJPROP_TEXT,  text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

// Retorna cor verde/vermelho conforme sinal do valor
color Panel_PnlColor(double v)
  {
   if(v > 0.0) return CLR_GREEN;
   if(v < 0.0) return CLR_RED;
   return CLR_GRAY_LBL;
  }

// Formata P&L com sinal
string Panel_FmtPnl(double v)
  {
   if(v >= 0.0) return StringFormat("+%.2f", v);
   return StringFormat("%.2f", v);
  }

// Calcula o lote atual por perna de cada estratégia para exibição
double Panel_E1_LotActual()
  {
   if(E1_TipoLote == E1_LOTE_FIXO) return E1_LotePerna1;
   double saldo = ConcordeCapital();
   double degraus = 0.0;
   if(E1_UsdPorDegrauSaldo > 0.0) degraus = MathFloor(saldo / E1_UsdPorDegrauSaldo);
   if(degraus < 0.0) degraus = 0.0;
   double lot = E1_LoteDinamicoBasePorPerna + degraus * E1_IncLotePorDegrau;
   if(g_e1_volume_max > 0.0 && lot > g_e1_volume_max) lot = g_e1_volume_max;
   if(lot < g_e1_volume_min) lot = g_e1_volume_min;
   return NormalizeDouble(lot, 2);
  }

// Calcula P&L do dia para um magic number (soma deals de hoje + posições abertas)
double Panel_DayPnl(long magic1, long magic2 = -1)
  {
   double pnl = 0.0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime dayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

   HistorySelect(dayStart, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long mg = HistoryDealGetInteger(d, DEAL_MAGIC);
      if(mg != magic1 && (magic2 < 0 || mg != magic2)) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN) continue;
      pnl += HistoryDealGetDouble(d, DEAL_PROFIT)
           + HistoryDealGetDouble(d, DEAL_COMMISSION)
           + HistoryDealGetDouble(d, DEAL_SWAP);
     }

   // Posições abertas (P&L flutuante)
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg != magic1 && (magic2 < 0 || mg != magic2)) continue;
      pnl += PositionGetDouble(POSITION_PROFIT)
           + PositionGetDouble(POSITION_SWAP);
     }
   return pnl;
  }

// Calcula P&L acumulado (histórico completo) para um magic number
double Panel_TotalPnl(long magic1, long magic2 = -1)
  {
   double pnl = 0.0;
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long mg = HistoryDealGetInteger(d, DEAL_MAGIC);
      if(mg != magic1 && (magic2 < 0 || mg != magic2)) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN) continue;
      pnl += HistoryDealGetDouble(d, DEAL_PROFIT)
           + HistoryDealGetDouble(d, DEAL_COMMISSION)
           + HistoryDealGetDouble(d, DEAL_SWAP);
     }
   // Posições abertas
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg != magic1 && (magic2 < 0 || mg != magic2)) continue;
      pnl += PositionGetDouble(POSITION_PROFIT)
           + PositionGetDouble(POSITION_SWAP);
     }
   return pnl;
  }

// Cria a estrutura fixa do painel (chamado apenas em Panel_Create).
// Layout idêntico ao screenshot de referência:
//  ┌─────────────────────────────────┐
//  │         ✈  CONCORDE EA           │  ← header dourado
//  │  Saldo              Equity      │  ← labels cinza
//  │  19503.13        19436.55       │  ← valores brancos
//  ├─────────────────────────────────┤
//  │▌ESTRATÉGIA 1 ON     Lote: 0.40 │  ← barra vertical + nome colorido + status
//  │ Dia              Acumulado      │
//  │ +1336.07         +7312.54       │  ← valores verdes/vermelhos
//  ├──  (repetido x3)  ──────────────┤
//  │▌TOTAL                           │
//  │ Dia              Acumulado      │
//  │ +1269.49         +18828.19      │
//  └─────────────────────────────────┘
void Panel_Build()
  {
   int px = Panel_X;
   int py = Panel_Y;
   int w  = PANEL_W;
   int rx = px + w - 8;       // âncora direita para textos right-aligned

   // Alturas de cada faixa (px)
   const int hHdr    = 26;    // cabeçalho "CONCORDE EA"
   const int hLbl    = 15;    // linha de labels pequenos
   const int hVal    = 22;    // linha de valores grandes
   const int hTitle  = 20;    // linha de título + lote (ou status)
   const int hDiv    = 1;     // divisor
   const int hPad    = 7;     // padding inferior
   const int barW    = 3;     // largura da barra vertical à esquerda
   const int xText   = px + 12;  // x onde começa o texto após a barra

   int totalH = hHdr
              + hLbl + hVal + hDiv
              + 4 * (hTitle + hLbl + hVal + hDiv)
              + hTitle + hLbl + hVal
              + hPad;

   // Altura da seção de cada estratégia (sem o divisor) — para a barra vertical
   const int hStratSection = hTitle + hLbl + hVal;
   const int hTotalSection = hTitle + hLbl + hVal;

   // ── Fundo geral ──────────────────────────────────────────────
   Panel_CreateRect(PANEL_PREFIX+"bg", px, py, w, totalH, CLR_BG, CLR_BORDER, 1);

   // ── Cabeçalho ────────────────────────────────────────────────
   Panel_CreateRect(PANEL_PREFIX+"hdr_bg", px, py, w, hHdr, CLR_HEADER_BG, CLR_BORDER, 1);
   Panel_CreateLabel(PANEL_PREFIX+"hdr_txt",
                     px + w/2, py + hHdr/2,
                     "✈  CONCORDE EA", CLR_GOLD, 10, ANCHOR_CENTER);

   int y = py + hHdr;

   // ── Saldo / Equity ────────────────────────────────────────────
   Panel_CreateLabel(PANEL_PREFIX+"lbl_saldo",  px+8, y+3, "Saldo",  CLR_GRAY_LBL, 7);
   Panel_CreateLabel(PANEL_PREFIX+"lbl_equity", rx,   y+3, "Equity", CLR_GRAY_LBL, 7, ANCHOR_RIGHT_UPPER);
   y += hLbl;
   Panel_CreateLabel(PANEL_PREFIX+"val_saldo",  px+8, y+2, "0.00", CLR_WHITE, 10);
   Panel_CreateLabel(PANEL_PREFIX+"val_equity", rx,   y+2, "0.00", CLR_WHITE, 10, ANCHOR_RIGHT_UPPER);
   y += hVal;

   Panel_CreateRect(PANEL_PREFIX+"div0", px, y, w, hDiv, CLR_DIVIDER, CLR_DIVIDER, 0);
   y += hDiv;

   // ── 4 Estratégias ─────────────────────────────────────────────
   string sNames[4] = {"ESTRATÉGIA 1","ESTRATÉGIA 2","ESTRATÉGIA 3","ESTRATÉGIA 4"};
   color  sColors[4] = {CLR_STRAT1, CLR_STRAT2, CLR_STRAT3, CLR_STRAT4};

   for(int s = 0; s < 4; s++)
     {
      string sf = IntegerToString(s+1);

      // Barra vertical colorida à esquerda da seção
      Panel_CreateRect(PANEL_PREFIX+"bar"+sf, px, y, barW, hStratSection,
                       sColors[s], sColors[s], 0);

      // Linha 1: nome (cor da estratégia) + status ON/OFF + Lote (à direita)
      Panel_CreateLabel(PANEL_PREFIX+"s"+sf+"_name",
                        xText, y+3, sNames[s], sColors[s], 8);
      // Status ON/OFF posicionado após o nome (~118px depois do início do texto)
      Panel_CreateLabel(PANEL_PREFIX+"s"+sf+"_st",
                        xText+118, y+4, "ON", CLR_GREEN, 7);
      Panel_CreateLabel(PANEL_PREFIX+"s"+sf+"_lote",
                        rx, y+3, "Lote: 0.00", CLR_GRAY_LBL, 8, ANCHOR_RIGHT_UPPER);
      y += hTitle;

      // Linha 2: "Dia" | "Acumulado" — labels cinza pequenos
      Panel_CreateLabel(PANEL_PREFIX+"s"+sf+"_dia_t",
                        xText, y+2, "Dia",       CLR_GRAY_LBL, 7);
      Panel_CreateLabel(PANEL_PREFIX+"s"+sf+"_acc_t",
                        rx,    y+2, "Acumulado", CLR_GRAY_LBL, 7, ANCHOR_RIGHT_UPPER);
      y += hLbl;

      // Linha 3: valor dia | valor acumulado
      Panel_CreateLabel(PANEL_PREFIX+"s"+sf+"_dia",
                        xText, y+2, "+0.00", CLR_GREEN, 9);
      Panel_CreateLabel(PANEL_PREFIX+"s"+sf+"_acc",
                        rx,    y+2, "+0.00", CLR_GREEN, 9, ANCHOR_RIGHT_UPPER);
      y += hVal;

      Panel_CreateRect(PANEL_PREFIX+"div"+sf, px, y, w, hDiv, CLR_DIVIDER, CLR_DIVIDER, 0);
      y += hDiv;
     }

   // ── TOTAL ─────────────────────────────────────────────────────
   // Barra vertical dourada
   Panel_CreateRect(PANEL_PREFIX+"bar_tot", px, y, barW, hTotalSection,
                    CLR_STRAT_TOTAL, CLR_STRAT_TOTAL, 0);

   Panel_CreateLabel(PANEL_PREFIX+"tot_name",
                     xText, y+3, "TOTAL", CLR_STRAT_TOTAL, 9);
   y += hTitle;

   Panel_CreateLabel(PANEL_PREFIX+"tot_dia_t",
                     xText, y+2, "Dia",       CLR_GRAY_LBL, 7);
   Panel_CreateLabel(PANEL_PREFIX+"tot_acc_t",
                     rx,    y+2, "Acumulado", CLR_GRAY_LBL, 7, ANCHOR_RIGHT_UPPER);
   y += hLbl;

   Panel_CreateLabel(PANEL_PREFIX+"tot_dia",
                     xText, y+2, "+0.00", CLR_GREEN, 9);
   Panel_CreateLabel(PANEL_PREFIX+"tot_acc",
                     rx,    y+2, "+0.00", CLR_GREEN, 9, ANCHOR_RIGHT_UPPER);

   ChartRedraw(0);
  }

// v9: no tester não-visual o painel não renderiza — pular economiza os scans
// de histórico (Panel_DayPnl/Panel_TotalPnl) a cada candle M15.
bool Panel_SkipInTester()
  {
   return ((bool)MQLInfoInteger(MQL_TESTER) && !(bool)MQLInfoInteger(MQL_VISUAL_MODE));
  }

void Panel_Create()
  {
   if(!Panel_Mostrar || Panel_SkipInTester()) return;
   Panel_DeleteAll();
   Panel_Build();
   Panel_Update(true);
  }

// Aplica visual ATIVA/INATIVA a uma estratégia: barra + nome + label de status.
// Quando inativa: barra fica cinza-escuro, nome também, e mostra "OFF" em vermelho.
void Panel_ApplyStratStatus(int idx, bool ativa, color stratColor)
  {
   string sf = IntegerToString(idx);
   string barName  = PANEL_PREFIX+"bar"+sf;
   string nameName = PANEL_PREFIX+"s"+sf+"_name";
   string stName   = PANEL_PREFIX+"s"+sf+"_st";

   color  barClr  = ativa ? stratColor : CLR_GRAY_DIM;
   color  nameClr = ativa ? stratColor : CLR_GRAY_DIM;
   string stTxt   = ativa ? "ON" : "OFF";
   color  stClr   = ativa ? CLR_GREEN : CLR_RED;

   if(ObjectFind(0, barName) >= 0)
     {
      ObjectSetInteger(0, barName, OBJPROP_BGCOLOR,      barClr);
      ObjectSetInteger(0, barName, OBJPROP_BORDER_COLOR, barClr);
     }
   if(ObjectFind(0, nameName) >= 0)
      ObjectSetInteger(0, nameName, OBJPROP_COLOR, nameClr);
   Panel_SetLabel(stName, stTxt, stClr);
  }

void Panel_Update(bool force = false)
  {
   if(!Panel_Mostrar || Panel_SkipInTester()) return;

   // Atualiza apenas quando muda o candle M15 (ou forçado na inicialização)
   datetime barNow = iTime(_Symbol, PERIOD_M15, 0);
   if(!force && barNow == g_panel_lastBarTime) return;
   g_panel_lastBarTime = barNow;

   // ── Saldo / Equity ────────────────────────────────────────────
   double saldo  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   Panel_SetLabel(PANEL_PREFIX+"val_saldo",  DoubleToString(saldo,  2), CLR_WHITE);
   Panel_SetLabel(PANEL_PREFIX+"val_equity", DoubleToString(equity, 2), CLR_WHITE);

   // ── Estratégia 1 — E1 ───────────────────────────────────────
   string lrb_lotTxt = (E1_TipoLote == E1_LOTE_RISCO)
                       ? StringFormat("Risco: %.1f%%/p", E1_RiscoPorPernaPct)
                       : "Lote: "+DoubleToString(Panel_E1_LotActual(), 2);
   double lrb_dia = Panel_DayPnl(E1_MagicNumber);
   double lrb_acc = Panel_TotalPnl(E1_MagicNumber);
   Panel_SetLabel(PANEL_PREFIX+"s1_lote", lrb_lotTxt, CLR_GRAY_LBL);
   Panel_SetLabel(PANEL_PREFIX+"s1_dia",  Panel_FmtPnl(lrb_dia), Panel_PnlColor(lrb_dia));
   Panel_SetLabel(PANEL_PREFIX+"s1_acc",  Panel_FmtPnl(lrb_acc), Panel_PnlColor(lrb_acc));
   Panel_ApplyStratStatus(1, Estrategia1_Ativada, CLR_STRAT1);

   // ── Estratégia 2 — E2 ─────────────────────────────────────
   string ab_lotTxt = (E2_TipoLote == E2_LOTE_RISCO)
                      ? StringFormat("Risco: %.1f%%/p", E2_RiscoPorPernaPct)
                      : "Lote: "+DoubleToString(E2_LotPerLeg_Panel(), 2);
   double ab_dia = Panel_DayPnl((long)E2_MagicNumber);
   double ab_acc = Panel_TotalPnl((long)E2_MagicNumber);
   Panel_SetLabel(PANEL_PREFIX+"s2_lote", ab_lotTxt, CLR_GRAY_LBL);
   Panel_SetLabel(PANEL_PREFIX+"s2_dia",  Panel_FmtPnl(ab_dia), Panel_PnlColor(ab_dia));
   Panel_SetLabel(PANEL_PREFIX+"s2_acc",  Panel_FmtPnl(ab_acc), Panel_PnlColor(ab_acc));
   Panel_ApplyStratStatus(2, Estrategia2_Ativada, CLR_STRAT2);

   // ── Estratégia 3 — E3 ─────────────────────────────────
   string bp_lotTxt = (E3_TipoLote == E3_LOT_TYPE_RISK)
                      ? StringFormat("Risco: %.1f%%/p", E3_RiscoPorPernaPct)
                      : "Lote: "+DoubleToString(E3_CalculateLotSize_Panel(), 2);
   double bp_dia = Panel_DayPnl(E3_MagicNumber, E3_MagicNumber+1);
   double bp_acc = Panel_TotalPnl(E3_MagicNumber, E3_MagicNumber+1);
   Panel_SetLabel(PANEL_PREFIX+"s3_lote", bp_lotTxt, CLR_GRAY_LBL);
   Panel_SetLabel(PANEL_PREFIX+"s3_dia",  Panel_FmtPnl(bp_dia), Panel_PnlColor(bp_dia));
   Panel_SetLabel(PANEL_PREFIX+"s3_acc",  Panel_FmtPnl(bp_acc), Panel_PnlColor(bp_acc));
   Panel_ApplyStratStatus(3, Estrategia3_Ativada, CLR_STRAT3);

   // ── Estratégia 4 — E4 ───────────────────────────────
   // Lote é calculado por risco % a cada trade, então mostra o risco.
   string rsi_lotTxt;
   if(E4_UseDynLots)
      rsi_lotTxt = StringFormat("Lote din: %.2f",
                     E4_DynBaseLots + MathFloor(ConcordeCapital()/MathMax(1.0,E4_UsdPorDegrau))*E4_DynIncLots);
   else if(E4_UseStop)
      rsi_lotTxt = StringFormat("Risco: %.1f%%", E4_RiskPercent);
   else
      rsi_lotTxt = StringFormat("Lote: %.2f", E4_FixedLots);
   double rsi_dia = Panel_DayPnl(E4_MagicNumber);
   double rsi_acc = Panel_TotalPnl(E4_MagicNumber);
   Panel_SetLabel(PANEL_PREFIX+"s4_lote", rsi_lotTxt, CLR_GRAY_LBL);
   Panel_SetLabel(PANEL_PREFIX+"s4_dia",  Panel_FmtPnl(rsi_dia), Panel_PnlColor(rsi_dia));
   Panel_SetLabel(PANEL_PREFIX+"s4_acc",  Panel_FmtPnl(rsi_acc), Panel_PnlColor(rsi_acc));
   Panel_ApplyStratStatus(4, Estrategia4_Ativada && g_e4_enabled, CLR_STRAT4);

   // ── TOTAL ─────────────────────────────────────────────────────
   double tot_dia = lrb_dia + ab_dia + bp_dia + rsi_dia;
   double tot_acc = lrb_acc + ab_acc + bp_acc + rsi_acc;
   Panel_SetLabel(PANEL_PREFIX+"tot_dia", Panel_FmtPnl(tot_dia), Panel_PnlColor(tot_dia));
   Panel_SetLabel(PANEL_PREFIX+"tot_acc", Panel_FmtPnl(tot_acc), Panel_PnlColor(tot_acc));

   ChartRedraw(0);
  }


//==================================================================
//                FUNÇÕES UTILITÁRIAS GERAIS DA E1
//==================================================================

long E1_SecondsSinceEpoch(datetime t) { return (long)t; }

long E1_GmtSeconds(datetime srv)
  {
   // v9: fuso auto-detectado (ao vivo) / DST europeu (tester) via módulo global.
   return E1_SecondsSinceEpoch(srv) - (long)Concorde_SrvGmtOffset() * 3600;
  }

void E1_GmtTimeOfDay(datetime srv, int &hour, int &minute, int &second)
  {
   long g = E1_GmtSeconds(srv);
   int sod = (int)(g % 86400);
   if(sod < 0) sod += 86400;
   hour   = sod / 3600;
   minute = (sod % 3600) / 60;
   second = sod % 60;
  }

int E1_GmtDayIndex(datetime srv)
  {
   long g = E1_GmtSeconds(srv);
   if(g < 0) return (int)((g - 86399) / 86400);
   return (int)(g / 86400);
  }

datetime E1_LastGmtMidnightServer(datetime srv)
  {
   long g = E1_GmtSeconds(srv);
   int sod = (int)(g % 86400);
   if(sod < 0) sod += 86400;
   return (datetime)(E1_SecondsSinceEpoch(srv) - sod);
  }

void E1_ResetTrailState()
  {
   g_e1_trail_armed = false;
   g_e1_be_done = false;
   g_e1_last_trail_bar_time = 0;
  }

bool E1_Gmt0PastExit(int gh, int gm, int gs)
  {
   int m = E1_HoraSaidaGMT_Minutos;
   if(m < 0) m = 0;
   if(m > 1439) m = 1439;
   int now_sec  = gh*3600 + gm*60 + gs;
   int exit_sec = m*60;
   return (now_sec >= exit_sec);
  }

double E1_PipSizeForSymbol(const string sym)
  {
   g_e1_digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   g_e1_point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(g_e1_digits == 1 || g_e1_digits == 2 || g_e1_digits == 3)
      return g_e1_point * 10.0;
   return g_e1_point;
  }

bool E1_NormalizeVolume(double &vol)
  {
   if(vol < g_e1_volume_min) vol = g_e1_volume_min;
   if(vol > g_e1_volume_max) vol = g_e1_volume_max;
   vol = MathFloor(vol / g_e1_volume_step + 1e-12) * g_e1_volume_step;
   return vol >= g_e1_volume_min - 1e-12;
  }

// Lote por perna para a E1 (fixo, dinâmico ou risco % — v9).
// riskDistPrice = |entrada - SL| em preço (só usado no modo RISCO).
double E1_LotPerLeg(int legIndex, double riskDistPrice = 0.0)
  {
   if(E1_TipoLote == E1_LOTE_FIXO)
      return (legIndex == 1) ? E1_LotePerna1 : E1_LotePerna2;

   if(E1_TipoLote == E1_LOTE_RISCO)
     {
      double fallback = (legIndex == 1) ? E1_LotePerna1 : E1_LotePerna2;
      double lot = Concorde_LotsByRisk(g_e1_symbol, riskDistPrice, E1_RiscoPorPernaPct, fallback);
      if(!E1_NormalizeVolume(lot)) lot = g_e1_volume_min;
      return lot;
     }

   double saldo = ConcordeCapital();
   double degraus = 0.0;
   if(E1_UsdPorDegrauSaldo > 0.0) degraus = MathFloor(saldo / E1_UsdPorDegrauSaldo);
   if(degraus < 0.0) degraus = 0.0;

   double lot = E1_LoteDinamicoBasePorPerna + degraus * E1_IncLotePorDegrau;

   if(g_e1_volume_max > 0.0 && lot > g_e1_volume_max) lot = g_e1_volume_max;
   if(lot < g_e1_volume_min) lot = g_e1_volume_min;
   lot = MathFloor(lot / g_e1_volume_step + 1e-12) * g_e1_volume_step;
   if(lot < g_e1_volume_min) lot = g_e1_volume_min;
   return NormalizeDouble(lot, 2);
  }

//==================================================================
//                FUNÇÕES OPERACIONAIS DA E1
//==================================================================

bool E1_CalcRangeHighLow(datetime t_end_server, double &hi, double &lo)
  {
   datetime t_start_server = t_end_server - 3*3600;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   datetime srv_from = t_start_server - 120;
   datetime srv_to   = t_end_server + 60;
   int n = CopyRates(g_e1_symbol, E1_RangeTimeframe, srv_from, srv_to, rates);
   if(n <= 0) { Print("E1 CalcRange: CopyRates falhou err=", GetLastError()); return false; }
   hi = -DBL_MAX; lo = DBL_MAX;
   for(int i = 0; i < n; i++)
     {
      datetime tb = rates[i].time;
      if(tb < t_start_server || tb >= t_end_server) continue;
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
     }
   if(hi <= -DBL_MAX/2 || lo >= DBL_MAX/2 || hi <= lo)
     { Print("E1 CalcRange: range inválido."); return false; }
   return true;
  }

void E1_ClearPendingTicketVars()
  {
   g_e1_bs_tp3 = g_e1_bs_tp5 = g_e1_ss_tp3 = g_e1_ss_tp5 = 0;
  }

void E1_CancelPendings(int onlyType = -1)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_e1_symbol) continue;
      if((int)OrderGetInteger(ORDER_MAGIC) != E1_MagicNumber) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool match = (onlyType == -1
                    && (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP))
                || ((int)type == onlyType);
      if(match)
         e1_trade.OrderDelete(ticket);
     }
   if(onlyType == -1)
      E1_ClearPendingTicketVars();
   else if(onlyType == ORDER_TYPE_BUY_STOP)
     { g_e1_bs_tp3 = g_e1_bs_tp5 = 0; }
   else if(onlyType == ORDER_TYPE_SELL_STOP)
     { g_e1_ss_tp3 = g_e1_ss_tp5 = 0; }
  }

void E1_CloseOurPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e1_symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != E1_MagicNumber) continue;
      e1_trade.PositionClose(ticket);
     }
   E1_ResetTrailState();
  }

bool E1_PositionExistsByComment(const string cmt, ulong &ticket_out)
  {
   ticket_out = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e1_symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != E1_MagicNumber) continue;
      if(PositionGetString(POSITION_COMMENT) == cmt)
        { ticket_out = t; return true; }
     }
   return false;
  }

bool E1_PlacePendingBreakout(double range_high, double range_low)
  {
   double ask = SymbolInfoDouble(g_e1_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_e1_symbol, SYMBOL_BID);
   int    lvl = (int)SymbolInfoInteger(g_e1_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist = lvl * g_e1_point;

   double mid = (range_high + range_low) * 0.5;
   double buf = E1_BufferRompimentoPips * g_e1_pip_size;

   double buy_price  = NormalizeDouble(range_high + buf, g_e1_digits);
   double sell_price = NormalizeDouble(range_low  - buf, g_e1_digits);
   double sl_buy     = NormalizeDouble(mid, g_e1_digits);
   double sl_sell    = NormalizeDouble(mid, g_e1_digits);

   double risk_buy  = buy_price - sl_buy;
   double risk_sell = sl_sell - sell_price;
   if(risk_buy <= 0 || risk_sell <= 0)
     { Print("E1: risco inválido (range muito estreito ou SL)."); return false; }

   double rr3_buy  = MathMax(E1_TakeProfitMinimoR, E1_AlvoPerna1_R) * risk_buy;
   double rr5_buy  = MathMax(E1_TakeProfitMinimoR, E1_AlvoPerna2_R) * risk_buy;
   double rr3_sell = MathMax(E1_TakeProfitMinimoR, E1_AlvoPerna1_R) * risk_sell;
   double rr5_sell = MathMax(E1_TakeProfitMinimoR, E1_AlvoPerna2_R) * risk_sell;

   double tp_buy3  = NormalizeDouble(buy_price  + rr3_buy,  g_e1_digits);
   double tp_buy5  = NormalizeDouble(buy_price  + rr5_buy,  g_e1_digits);
   double tp_sell3 = NormalizeDouble(sell_price - rr3_sell, g_e1_digits);
   double tp_sell5 = NormalizeDouble(sell_price - rr5_sell, g_e1_digits);

   if(buy_price < ask + min_dist) { Print("E1 BuyStop: preço inválido vs Ask/stops_level."); return false; }
   if(sell_price > bid - min_dist){ Print("E1 SellStop: preço inválido vs Bid/stops_level.");return false; }

   e1_trade.SetExpertMagicNumber(E1_MagicNumber);
   e1_trade.SetTypeFillingBySymbol(g_e1_symbol);
   e1_trade.SetDeviationInPoints(30);

   // v9: volumes por LADO — no modo RISCO usa a distância real entrada->SL de cada lado.
   double vb3 = E1_LotPerLeg(1, risk_buy),  vb5 = E1_LotPerLeg(2, risk_buy);
   double vs3 = E1_LotPerLeg(1, risk_sell), vs5 = E1_LotPerLeg(2, risk_sell);
   if(!E1_NormalizeVolume(vb3) || !E1_NormalizeVolume(vb5)
   || !E1_NormalizeVolume(vs3) || !E1_NormalizeVolume(vs5))
     { Print("E1: volume inválido."); return false; }

   // v9: cap de exposição por direção (pernas E1+E2+E3 já abertas neste símbolo).
   bool wantBuy  = Concorde_CanOpenLegs(g_e1_symbol, true,  2);
   bool wantSell = Concorde_CanOpenLegs(g_e1_symbol, false, 2);
   if(!wantBuy || !wantSell)
      Print("E1: cap de pernas — buy=", (wantBuy ? "ok" : "BLOQUEADO"),
            " sell=", (wantSell ? "ok" : "BLOQUEADO"));
   if(!wantBuy && !wantSell) return false;

   E1_CancelPendings();
   E1_ResetTrailState();

   bool ok = true;
   if(wantBuy)
     {
      bool ok_bs3 = e1_trade.BuyStop (vb3, buy_price,  g_e1_symbol, sl_buy,  tp_buy3,  ORDER_TIME_GTC, 0, E1_COMMENT_TP3);
      g_e1_bs_tp3 = e1_trade.ResultOrder();
      if(!ok_bs3) Print("E1 BuyStop TP3: ", e1_trade.ResultRetcodeDescription());

      bool ok_bs5 = e1_trade.BuyStop (vb5, buy_price,  g_e1_symbol, sl_buy,  tp_buy5,  ORDER_TIME_GTC, 0, E1_COMMENT_TP5);
      g_e1_bs_tp5 = e1_trade.ResultOrder();
      if(!ok_bs5) Print("E1 BuyStop TP5: ", e1_trade.ResultRetcodeDescription());
      ok = ok && ok_bs3 && ok_bs5;
     }
   if(wantSell)
     {
      bool ok_ss3 = e1_trade.SellStop(vs3, sell_price, g_e1_symbol, sl_sell, tp_sell3, ORDER_TIME_GTC, 0, E1_COMMENT_TP3);
      g_e1_ss_tp3 = e1_trade.ResultOrder();
      if(!ok_ss3) Print("E1 SellStop TP3: ", e1_trade.ResultRetcodeDescription());

      bool ok_ss5 = e1_trade.SellStop(vs5, sell_price, g_e1_symbol, sl_sell, tp_sell5, ORDER_TIME_GTC, 0, E1_COMMENT_TP5);
      g_e1_ss_tp5 = e1_trade.ResultOrder();
      if(!ok_ss5) Print("E1 SellStop TP5: ", e1_trade.ResultRetcodeDescription());
      ok = ok && ok_ss3 && ok_ss5;
     }

   if(!ok)
     { E1_CancelPendings(); return false; }
   return true;
  }

void E1_CheckOcoFromPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e1_symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != E1_MagicNumber) continue;
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(ptype == POSITION_TYPE_BUY)  { E1_CancelPendings(ORDER_TYPE_SELL_STOP); return; }
      if(ptype == POSITION_TYPE_SELL) { E1_CancelPendings(ORDER_TYPE_BUY_STOP);  return; }
     }
  }

void E1_ManageBreakevenAndTrail()
  {
   if(!g_e1_trail_armed) return;

   ulong t5 = 0;
   if(!E1_PositionExistsByComment(E1_COMMENT_TP5, t5))
     { E1_ResetTrailState(); return; }
   if(!PositionSelectByTicket(t5)) return;

   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);
   double bid   = SymbolInfoDouble(g_e1_symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(g_e1_symbol, SYMBOL_ASK);
   int    stp   = (int)SymbolInfoInteger(g_e1_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_d = stp * g_e1_point;
   double be_off = E1_BreakEvenOffsetPontos  * g_e1_point;
   double tr_buf = E1_TrailBufferPontos * g_e1_point;

   if(!g_e1_be_done)
     {
      // v9: só marca o BE como feito se o modify teve SUCESSO (ou não era necessário).
      // Antes, um modify rejeitado (requote/stops level) deixava a perna sem BE p/ sempre.
      bool beOk = true;
      double new_sl = (ptype == POSITION_TYPE_BUY)
                      ? NormalizeDouble(open - be_off, g_e1_digits)
                      : NormalizeDouble(open + be_off, g_e1_digits);
      if(ptype == POSITION_TYPE_BUY)
        {
         new_sl = MathMin(new_sl, bid - min_d);
         if(new_sl > sl + g_e1_point*0.5) beOk = e1_trade.PositionModify(t5, new_sl, tp);
        }
      else
        {
         new_sl = MathMax(new_sl, ask + min_d);
         if(sl == 0 || new_sl < sl - g_e1_point*0.5) beOk = e1_trade.PositionModify(t5, new_sl, tp);
        }
      if(!beOk)
        { Print("E1 BE: modify falhou (", e1_trade.ResultRetcodeDescription(), ") — vai retentar."); return; }
      g_e1_be_done = true;
      datetime b0 = iTime(g_e1_symbol, E1_TrailTimeframe, 0);
      g_e1_last_trail_bar_time = (b0 > 0 ? b0 : 0);
      return;
     }

   datetime bar0 = iTime(g_e1_symbol, E1_TrailTimeframe, 0);
   if(bar0 == 0 || bar0 == g_e1_last_trail_bar_time) return;
   g_e1_last_trail_bar_time = bar0;

   double new_sl = sl;
   if(ptype == POSITION_TYPE_BUY)
     {
      double lo = iLow(g_e1_symbol, E1_TrailTimeframe, 1);
      if(lo <= 0) return;
      double trail = NormalizeDouble(lo - tr_buf, g_e1_digits);
      new_sl = MathMax(sl, trail);
      new_sl = MathMin(new_sl, bid - min_d);
      if(new_sl > sl + g_e1_point*0.5 && new_sl < bid - g_e1_point*0.5)
         e1_trade.PositionModify(t5, new_sl, tp);
     }
   else if(ptype == POSITION_TYPE_SELL)
     {
      double hi = iHigh(g_e1_symbol, E1_TrailTimeframe, 1);
      if(hi <= 0) return;
      double trail = NormalizeDouble(hi + tr_buf, g_e1_digits);
      new_sl = MathMin(sl, trail);
      new_sl = MathMax(new_sl, ask + min_d);
      if(new_sl < sl - g_e1_point*0.5 && new_sl > ask + g_e1_point*0.5)
         e1_trade.PositionModify(t5, new_sl, tp);
     }
  }

void E1_ProcessSession()
  {
   datetime now = TimeCurrent();
   int gh, gm, gs; E1_GmtTimeOfDay(now, gh, gm, gs);
   int day_ix = E1_GmtDayIndex(now);

   // v9: fecha só 1x por dia GMT (antes rodava o loop de fechar/cancelar a cada
   // segundo, das 06:00 até meia-noite GMT — inofensivo mas desperdício).
   static int s_lrb_closed_day = -999999;
   if(E1_Gmt0PastExit(gh, gm, gs) && s_lrb_closed_day != day_ix)
     {
      E1_CloseOurPositions();
      E1_CancelPendings();
      E1_ResetTrailState();
      s_lrb_closed_day = day_ix;
     }

   static int s_prev_day_ix = 0;
   if(s_prev_day_ix != 0 && day_ix != s_prev_day_ix)
      E1_ResetTrailState();
   s_prev_day_ix = day_ix;

   // Filtro de notícias: durante a janela, cancela pendentes da E1 (não deixa romper na notícia).
   if(News_StratBlock(g_e1_symbol))
      E1_CancelPendings();

   E1_ManageBreakevenAndTrail();
   E1_CheckOcoFromPosition();

   if(gh == 0 && gm == 0)
     {
      datetime t_midnight = E1_LastGmtMidnightServer(now);
      int midnight_day_ix = E1_GmtDayIndex(t_midnight);
      // Toggle: só coloca pendentes novos se a Estratégia 1 estiver ativada.
      // Gestão de posições/pendentes existentes (acima) continua sempre rodando.
      // v9: stop diário global também bloqueia pendentes novos.
      if(Estrategia1_Ativada && !Concorde_GlobalStopActive()
         && g_e1_pending_gmt_day_index != midnight_day_ix
         && !News_StratBlock(g_e1_symbol))
        {
         double hi, lo;
         if(E1_CalcRangeHighLow(t_midnight, hi, lo))
            if(E1_PlacePendingBreakout(hi, lo))
               g_e1_pending_gmt_day_index = midnight_day_ix;
        }
     }

   g_e1_comment = StringFormat("E1: gmt=%02d:%02d:%02d | exitMin=%d | armed=%s | beDone=%s",
                                gh, gm, gs, E1_HoraSaidaGMT_Minutos,
                                (g_e1_trail_armed ? "sim" : "não"),
                                (g_e1_be_done     ? "sim" : "não"));
  }

//==================================================================
//                   E2 v2 (E2) - HELPERS
//==================================================================

bool   E2_UseSymbol()
  {
   g_e2_sym = (E2_Simbolo == "" ? _Symbol : E2_Simbolo);
   return true;
  }

double E2_PointValue()
  {
   double pt = SymbolInfoDouble(g_e2_sym, SYMBOL_POINT);
   if(pt <= 0) pt = _Point;
   return pt;
  }

double E2_TickSize()
  {
   double ts = SymbolInfoDouble(g_e2_sym, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) ts = E2_PointValue();
   return ts;
  }

double E2_NormPrice(const double p)
  {
   int dg = (int)SymbolInfoInteger(g_e2_sym, SYMBOL_DIGITS);
   return NormalizeDouble(p, dg);
  }

bool E2_SpreadOK()
  {
   long sp = SymbolInfoInteger(g_e2_sym, SYMBOL_SPREAD);
   return (sp >= 0 && sp <= E2_SpreadMaximoPontos);
  }

int E2_MinutesOfDay(const datetime t)
  {
   MqlDateTime dt; TimeToStruct(t, dt);
   return dt.hour*60 + dt.min;
  }

bool E2_WindowContains(const int curMin, const int sh, const int sm, const int eh, const int em)
  {
   int s = sh*60+sm, e = eh*60+em;
   if(s <= e) return (curMin >= s && curMin < e);
   return (curMin >= s || curMin < e);
  }

bool E2_InSession()
  {
   int m = E2_MinutesOfDay(TimeCurrent());
   if(E2_WindowContains(m, E2_SessaoAsia_InicioHora, E2_SessaoAsia_InicioMinuto, E2_SessaoAsia_FimHora, E2_SessaoAsia_FimMinuto)) return true;
   if(E2_WindowContains(m, E2_SessaoLondres_InicioHora,  E2_SessaoLondres_InicioMinuto,  E2_SessaoLondres_FimHora,  E2_SessaoLondres_FimMinuto )) return true;
   if(E2_WindowContains(m, E2_SessaoNY_InicioHora,   E2_SessaoNY_InicioMinuto,   E2_SessaoNY_FimHora,   E2_SessaoNY_FimMinuto  )) return true;
   return false;
  }

void E2_InitBlockedHoursFromInput()
  {
   ArrayInitialize(g_e2_blockHour, false);
   string raw = E2_HorasBloqueadasServidor;
   StringReplace(raw, " ", "");
   if(StringLen(raw) == 0) return;
   string parts[];
   const int n = StringSplit(raw, ',', parts);
   for(int i = 0; i < n; i++)
     {
      const int h = (int)StringToInteger(parts[i]);
      if(h >= 0 && h <= 23) g_e2_blockHour[h] = true;
     }
  }

bool E2_IsServerHourBlocked()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return g_e2_blockHour[dt.hour];
  }

bool E2_IsWednesdaySkip()
  {
   if(!E2_PularQuartaFeira) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 3);
  }

bool E2_CanOpenNewSetup()
  {
   if(News_StratBlock(g_e2_sym)) return false;   // filtro de notícias bloqueia novas entradas
   if(Concorde_GlobalStopActive()) return false;   // v9: stop diário global
   return (E2_InSession() && !E2_IsServerHourBlocked() && E2_SpreadOK() && !E2_IsWednesdaySkip());
  }

void E2_ResetDayCounterIfNeeded()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime day = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(day != g_e2_dayKey) { g_e2_dayKey = day; g_e2_tradesToday = 0; }
  }

bool E2_IsFractalHigh(const MqlRates &r[], const int i, const int w)
  {
   if(i < w || i + w >= ArraySize(r)) return false;
   double h = r[i].high;
   for(int k = 1; k <= w; k++)
     {
      if(h <= r[i-k].high) return false;
      if(h <= r[i+k].high) return false;
     }
   return true;
  }
bool E2_IsFractalLow(const MqlRates &r[], const int i, const int w)
  {
   if(i < w || i + w >= ArraySize(r)) return false;
   double lo = r[i].low;
   for(int k = 1; k <= w; k++)
     {
      if(lo >= r[i-k].low) return false;
      if(lo >= r[i+k].low) return false;
     }
   return true;
  }

bool E2_NearestFractalHigh(const MqlRates &r[], const int w, const int minBarIndex, double &outPrice, int &outIdx)
  {
   outPrice = 0; outIdx = -1;
   int n = ArraySize(r);
   int start = MathMax(w, minBarIndex);
   for(int i = start; i < n - w; i++)
      if(E2_IsFractalHigh(r, i, w)) { outPrice = r[i].high; outIdx = i; return true; }
   return false;
  }
bool E2_NearestFractalLow(const MqlRates &r[], const int w, const int minBarIndex, double &outPrice, int &outIdx)
  {
   outPrice = 0; outIdx = -1;
   int n = ArraySize(r);
   int start = MathMax(w, minBarIndex);
   for(int i = start; i < n - w; i++)
      if(E2_IsFractalLow(r, i, w))  { outPrice = r[i].low;  outIdx = i; return true; }
   return false;
  }

bool E2_NextFractalHighAbove(const MqlRates &r[], const int w, const double ref, double &outPrice)
  {
   outPrice = 0; double best = DBL_MAX; bool found = false; int n = ArraySize(r);
   for(int i = w; i < n - w; i++)
      if(E2_IsFractalHigh(r, i, w))
        {
         const double hi = r[i].high;
         if(hi <= ref) continue;
         if(hi < best) { best = hi; found = true; }
        }
   if(found) { outPrice = best; return true; }
   return false;
  }
bool E2_NextFractalLowBelow(const MqlRates &r[], const int w, const double ref, double &outPrice)
  {
   outPrice = 0; double best = -DBL_MAX; bool found = false; int n = ArraySize(r);
   for(int i = w; i < n - w; i++)
      if(E2_IsFractalLow(r, i, w))
        {
         const double lo = r[i].low;
         if(lo >= ref) continue;
         if(lo > best) { best = lo; found = true; }
        }
   if(found) { outPrice = best; return true; }
   return false;
  }
bool E2_NextFractalHighAboveExcl(const MqlRates &r[], const int w, const double ref, const double exclLevel, double &outPrice)
  {
   outPrice = 0; double best = DBL_MAX; bool found = false; int n = ArraySize(r);
   const double eps = E2_TickSize() * 4;
   for(int i = w; i < n - w; i++)
      if(E2_IsFractalHigh(r, i, w))
        {
         const double hi = r[i].high;
         if(hi <= ref) continue;
         if(hi <= exclLevel + eps) continue;
         if(hi < best) { best = hi; found = true; }
        }
   if(found) { outPrice = best; return true; }
   return false;
  }
bool E2_NextFractalLowBelowExcl(const MqlRates &r[], const int w, const double ref, const double exclLevel, double &outPrice)
  {
   outPrice = 0; double best = DBL_MAX; bool found = false; int n = ArraySize(r);
   const double eps = E2_TickSize() * 4;
   for(int i = w; i < n - w; i++)
      if(E2_IsFractalLow(r, i, w))
        {
         const double lo = r[i].low;
         if(lo >= ref) continue;
         if(lo >= exclLevel - eps) continue;
         if(lo < best) { best = lo; found = true; }
        }
   if(found) { outPrice = best; return true; }
   return false;
  }

double E2_LowestSinceBar(const MqlRates &r[], const int newestIdx, const int oldestIdx)
  {
   double mn = DBL_MAX;
   for(int i = newestIdx; i <= oldestIdx; i++) mn = MathMin(mn, r[i].low);
   return mn;
  }
double E2_HighestSinceBar(const MqlRates &r[], const int newestIdx, const int oldestIdx)
  {
   double mx = -DBL_MAX;
   for(int i = newestIdx; i <= oldestIdx; i++) mx = MathMax(mx, r[i].high);
   return mx;
  }

bool E2_StopsDistanceOK(const bool isBuy, const double price, const double sl, const double tp)
  {
   long lvl = (long)SymbolInfoInteger(g_e2_sym, SYMBOL_TRADE_STOPS_LEVEL);
   double pt = E2_PointValue();
   double minDist = lvl * pt;
   if(minDist <= 0) return true;
   if(isBuy)
     {
      if(price - sl < minDist - E2_TickSize()*0.5) return false;
      if(tp - price < minDist - E2_TickSize()*0.5) return false;
     }
   else
     {
      if(sl - price < minDist - E2_TickSize()*0.5) return false;
      if(price - tp < minDist - E2_TickSize()*0.5) return false;
     }
   return true;
  }

void E2_EnforceMinimumStops(const bool isBuy, const double entry, const double atr,
                            double &sl, double &tp1, double &tp2)
  {
   const double pt = E2_PointValue();
   const double tick = E2_TickSize();

   double minSlDist  = 0.0;
   if(E2_MinStopLossPontos  > 0) minSlDist  = MathMax(minSlDist,  (double)E2_MinStopLossPontos  * pt);
   if(E2_MinStopLossXAtr > 0.0 && atr > 0.0) minSlDist = MathMax(minSlDist, E2_MinStopLossXAtr * atr);

   double minTp1Dist = 0.0;
   if(E2_MinTakeProfit1Pontos  > 0) minTp1Dist = MathMax(minTp1Dist, (double)E2_MinTakeProfit1Pontos * pt);
   if(E2_MinTakeProfit1XAtr > 0.0 && atr > 0.0) minTp1Dist = MathMax(minTp1Dist, E2_MinTakeProfit1XAtr * atr);

   double minTp2Dist = 0.0;
   if(E2_MinTakeProfit2Pontos  > 0) minTp2Dist = MathMax(minTp2Dist, (double)E2_MinTakeProfit2Pontos * pt);
   if(E2_MinTakeProfit2XAtr > 0.0 && atr > 0.0) minTp2Dist = MathMax(minTp2Dist, E2_MinTakeProfit2XAtr * atr);

   const double gapMin = (E2_MinDistanciaEntreTpsXAtr > 0.0 && atr > 0.0
                          ? E2_MinDistanciaEntreTpsXAtr * atr : tick * 4.0);

   if(isBuy)
     {
      if(minSlDist  > 0.0 && entry - sl  < minSlDist)  sl  = E2_NormPrice(entry - minSlDist);
      if(minTp1Dist > 0.0 && tp1 - entry < minTp1Dist) tp1 = E2_NormPrice(entry + minTp1Dist);
      if(minTp2Dist > 0.0 && tp2 - entry < minTp2Dist) tp2 = E2_NormPrice(entry + minTp2Dist);
      if(tp2 <= tp1 + gapMin) tp2 = E2_NormPrice(tp1 + gapMin);
     }
   else
     {
      if(minSlDist  > 0.0 && sl - entry  < minSlDist)  sl  = E2_NormPrice(entry + minSlDist);
      if(minTp1Dist > 0.0 && entry - tp1 < minTp1Dist) tp1 = E2_NormPrice(entry - minTp1Dist);
      if(minTp2Dist > 0.0 && entry - tp2 < minTp2Dist) tp2 = E2_NormPrice(entry - minTp2Dist);
      if(tp2 >= tp1 - gapMin) tp2 = E2_NormPrice(tp1 - gapMin);
     }
  }

bool E2_PassesTp1RiskReward(const bool isBuy, const double entry, const double sl, const double tp1)
  {
   if(E2_MinRRTakeProfit1 <= 0.0) return true;
   const double tick2 = E2_TickSize() * 2.0;
   if(isBuy)
     {
      const double risk = entry - sl;
      if(risk <= tick2) return false;
      return (((tp1 - entry) / risk) >= E2_MinRRTakeProfit1);
     }
   const double risk = sl - entry;
   if(risk <= tick2) return false;
   return (((entry - tp1) / risk) >= E2_MinRRTakeProfit1);
  }

bool E2_PassesSignalRangeFilter(const MqlRates &r[], const double atr)
  {
   if(E2_MaxRangeSinalXAtr <= 0.0 || atr <= 0.0) return true;
   const double rng = r[1].high - r[1].low;
   return (rng <= E2_MaxRangeSinalXAtr * atr);
  }

void E2_CapTp2AtRiskMultiple(const bool isBuy, const double entry, const double sl, double &tp1, double &tp2)
  {
   if(E2_MaxAlvoTp2_R <= 0.0) return;
   const double tick = E2_TickSize();
   const double minRisk = tick * 4.0;
   if(isBuy)
     {
      const double risk = entry - sl;
      if(risk < minRisk) return;
      const double maxDist = E2_MaxAlvoTp2_R * risk;
      if(tp2 - entry > maxDist) tp2 = E2_NormPrice(entry + maxDist);
      if(tp2 <= tp1 + tick*4.0) tp2 = E2_NormPrice(tp1 + tick*4.0);
     }
   else
     {
      const double risk = sl - entry;
      if(risk < minRisk) return;
      const double maxDist = E2_MaxAlvoTp2_R * risk;
      if(entry - tp2 > maxDist) tp2 = E2_NormPrice(entry - maxDist);
      if(tp2 >= tp1 - tick*4.0) tp2 = E2_NormPrice(tp1 - tick*4.0);
     }
  }

bool E2_H1AllowsLong()
  {
   if(!E2_UsarFiltroEmaH1 || g_e2_maH1Handle == INVALID_HANDLE) return true;
   double ma[1];
   if(CopyBuffer(g_e2_maH1Handle, 0, 1, 1, ma) < 1) return true;
   const double c = iClose(g_e2_sym, PERIOD_H1, 1);
   if(c <= 0.0) return true;
   return (c >= ma[0]);
  }
bool E2_H1AllowsShort()
  {
   if(!E2_UsarFiltroEmaH1 || g_e2_maH1Handle == INVALID_HANDLE) return true;
   double ma[1];
   if(CopyBuffer(g_e2_maH1Handle, 0, 1, 1, ma) < 1) return true;
   const double c = iClose(g_e2_sym, PERIOD_H1, 1);
   if(c <= 0.0) return true;
   return (c <= ma[0]);
  }

int E2_CountOurPositions()
  {
   int c = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e2_sym) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != E2_MagicNumber) continue;
      c++;
     }
   return c;
  }

void E2_CloseOurPositionsEmergency()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e2_sym) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != E2_MagicNumber) continue;
      e2_trade.PositionClose(ticket);
     }
  }

void E2_CollectOurTickets(ulong &t1, ulong &t2)
  {
   t1 = 0; t2 = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e2_sym) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != E2_MagicNumber) continue;
      if(t1 == 0) t1 = ticket;
      else if(t2 == 0) t2 = ticket;
     }
  }

// v9: estado promovido de statics locais p/ globais — permite reconstrução
// no OnInit após restart (antes, restart com 1 perna viva deixava-a órfã).
int      g_e2_lastCount       = 0;
datetime g_e2_lastManageBar   = 0;
bool     g_e2_immediateBeDone = false;

void E2_ManagePostEntry(const MqlRates &r[])
  {
   int n = E2_CountOurPositions();
   if(n == 0)
     {
      g_e2_twoLegOpen      = false;
      g_e2_beTrailActive   = false;
      g_e2_lastCount       = 0;
      g_e2_lastManageBar   = 0;
      g_e2_immediateBeDone = false;
      g_e2_beStopPrice     = 0.0;
      g_e2_incremCount     = 0;
      return;
     }

   ulong p1 = 0, p2 = 0;
   E2_CollectOurTickets(p1, p2);

   if(n == 2) g_e2_twoLegOpen = true;

   const bool legClosed = (g_e2_twoLegOpen && g_e2_lastCount == 2 && n == 1);
   if(legClosed)
     {
      g_e2_beTrailActive   = true;
      g_e2_immediateBeDone = false;
      g_e2_beStopPrice     = 0.0;
      g_e2_incremCount     = 0;
     }
   g_e2_lastCount = n;

   if(!g_e2_beTrailActive) return;

   ulong surv = (p1 != 0 ? p1 : p2);
   if(!PositionSelectByTicket(surv)) return;

   const long type   = PositionGetInteger(POSITION_TYPE);
   const double open = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl   = PositionGetDouble(POSITION_SL);
   const double tp   = PositionGetDouble(POSITION_TP);
   const double bid  = SymbolInfoDouble(g_e2_sym, SYMBOL_BID);
   const double ask  = SymbolInfoDouble(g_e2_sym, SYMBOL_ASK);
   const double pt   = E2_PointValue();
   const double pad  = E2_TrailPadPontos  * pt;
   const double tick = E2_TickSize();

   // Imediato: move SL para BE logo que TP1 fecha (todos os modos).
   // v9: só marca como feito se o modify teve sucesso (retry no próximo tick).
   if(!g_e2_immediateBeDone)
     {
      bool beOk = true;
      if(type == POSITION_TYPE_BUY)
        {
         const double be    = E2_NormPrice(open + E2_BreakEvenOffsetPontos * pt);
         const double newSl = MathMax(sl, be);
         if(newSl > sl + tick*0.25) beOk = e2_trade.PositionModify(surv, newSl, tp);
         if(beOk) g_e2_beStopPrice = newSl;
        }
      else if(type == POSITION_TYPE_SELL)
        {
         const double be    = E2_NormPrice(open - E2_BreakEvenOffsetPontos * pt);
         double baseSl = sl; if(baseSl <= 0.0) baseSl = DBL_MAX;
         const double newSl = MathMin(baseSl, be);
         if(sl <= 0.0 || newSl < sl - tick*0.25) beOk = e2_trade.PositionModify(surv, newSl, tp);
         if(beOk) g_e2_beStopPrice = newSl;
        }
      if(!beOk)
        { Print("E2 BE: modify falhou (", e2_trade.ResultRetcodeDescription(), ") — vai retentar."); return; }
      g_e2_immediateBeDone = true;
      return;
     }

   // Modo BREAKEVEN: não faz trailing; mantém SL fixo no BE
   if(E2_PostTP1Mode == E2_POST_TP1_BREAKEVEN) return;

   if(ArraySize(r) < 3) return;
   const datetime t1 = r[1].time;
   if(t1 == g_e2_lastManageBar) return;
   g_e2_lastManageBar = t1;

   if(!PositionSelectByTicket(surv)) return;
   const long type2   = PositionGetInteger(POSITION_TYPE);
   const double open2 = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl2   = PositionGetDouble(POSITION_SL);
   const double tp2   = PositionGetDouble(POSITION_TP);
   const double bid2  = SymbolInfoDouble(g_e2_sym, SYMBOL_BID);
   const double ask2  = SymbolInfoDouble(g_e2_sym, SYMBOL_ASK);

   if(E2_PostTP1Mode == E2_POST_TP1_CANDLE_TRAIL)
     {
      // Trail por low/high do candle M15 anterior (comportamento original)
      if(type2 == POSITION_TYPE_BUY)
        {
         const double be    = E2_NormPrice(open2 + E2_BreakEvenOffsetPontos * pt);
         const double trail = E2_NormPrice(r[1].low - pad);
         double newSl = MathMax(sl2, MathMax(be, trail));
         newSl = MathMin(newSl, E2_NormPrice(bid2 - tick));
         if(newSl > sl2 + tick*0.25) e2_trade.PositionModify(surv, newSl, tp2);
        }
      else if(type2 == POSITION_TYPE_SELL)
        {
         const double be    = E2_NormPrice(open2 - E2_BreakEvenOffsetPontos * pt);
         const double trail = E2_NormPrice(r[1].high + pad);
         double baseSl = sl2; if(baseSl <= 0.0) baseSl = DBL_MAX;
         double newSl = MathMin(baseSl, MathMin(be, trail));
         newSl = MathMax(newSl, E2_NormPrice(ask2 + tick));
         if(sl2 <= 0.0 || newSl < sl2 - tick*0.25) e2_trade.PositionModify(surv, newSl, tp2);
        }
     }
   else // E2_POST_TP1_INCREMENTAL
     {
      // Trail incremental estilo E3: BE + (X pontos × nº de candles)
      g_e2_incremCount++;
      if(g_e2_beStopPrice == 0.0) g_e2_beStopPrice = sl2;
      const double increm = E2_TrailIncremPontos * pt;

      if(type2 == POSITION_TYPE_BUY)
        {
         double newSl = E2_NormPrice(g_e2_beStopPrice + increm * g_e2_incremCount);
         const double maxSl = E2_NormPrice(bid2 - tick);
         if(newSl > maxSl) newSl = maxSl;
         if(newSl > sl2 + tick*0.25) e2_trade.PositionModify(surv, newSl, tp2);
        }
      else if(type2 == POSITION_TYPE_SELL)
        {
         double newSl = E2_NormPrice(g_e2_beStopPrice - increm * g_e2_incremCount);
         const double minSl = E2_NormPrice(ask2 + tick);
         if(newSl < minSl) newSl = minSl;
         if(sl2 <= 0.0 || newSl < sl2 - tick*0.25) e2_trade.PositionModify(surv, newSl, tp2);
        }
     }
  }

// Lote por perna para uso interno do E2.
// riskDistPrice = |entrada - SL| (só usado no modo RISCO — v9).
double E2_LotPerLeg(double riskDistPrice = 0.0)
  {
   if(E2_TipoLote == E2_LOTE_FIXO)
      return NormalizeDouble(E2_LoteFixoPorPerna, 2);

   if(E2_TipoLote == E2_LOTE_RISCO)
      return Concorde_LotsByRisk(g_e2_sym, riskDistPrice, E2_RiscoPorPernaPct, E2_LoteFixoPorPerna);

   const double saldo = ConcordeCapital();
   double degraus = 0.0;
   if(E2_UsdPorDegrauSaldo > 0.0) degraus = MathFloor(saldo / E2_UsdPorDegrauSaldo);
   if(degraus < 0.0) degraus = 0.0;

   double lot = E2_LoteDinamicoBasePorPerna + degraus * E2_IncLotePorDegrau;

   const double vmin  = SymbolInfoDouble(g_e2_sym, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(g_e2_sym, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(g_e2_sym, SYMBOL_VOLUME_STEP);

   if(vmax > 0.0 && lot > vmax) lot = vmax;
   if(lot < vmin) lot = vmin;

   if(vstep > 0.0)
     {
      const int dg = (int)MathMax(0, (int)MathCeil(-MathLog10(vstep)));
      lot = vmin + MathFloor((lot - vmin) / vstep + 1e-8) * vstep;
      lot = NormalizeDouble(lot, dg > 0 ? dg : 2);
     }
   else
      lot = NormalizeDouble(lot, 2);

   if(lot < vmin) lot = NormalizeDouble(vmin, 2);
   if(vmax > 0.0 && lot > vmax) lot = NormalizeDouble(vmax, 2);
   return lot;
  }

// Versão do lote E2 para o painel (sem depender de g_e2_sym estar inicializado num contexto limpo)
double E2_LotPerLeg_Panel()
  {
   if(StringLen(g_e2_sym) == 0) return E2_LoteFixoPorPerna;
   return E2_LotPerLeg();
  }

bool E2_OpenTwoLegs(const bool isBuy, const double sl, const double tp1, const double tp2)
  {
   // v9: cap de exposição — não abre se estourar o máx de pernas na direção.
   if(!Concorde_CanOpenLegs(g_e2_sym, isBuy, 2))
     { Print("E2: cap de pernas na direção — entrada bloqueada."); return false; }

   e2_trade.SetExpertMagicNumber(E2_MagicNumber);
   e2_trade.SetDeviationInPoints(50);
   e2_trade.SetTypeFillingBySymbol(g_e2_sym);

   // v9: modo RISCO usa a distância real entrada->SL.
   const double refPx  = isBuy ? SymbolInfoDouble(g_e2_sym, SYMBOL_ASK)
                               : SymbolInfoDouble(g_e2_sym, SYMBOL_BID);
   const double abLeg = E2_LotPerLeg(MathAbs(refPx - sl));

   bool ok1 = false, ok2 = false;
   if(isBuy)
     {
      ok1 = e2_trade.Buy (abLeg, g_e2_sym, 0, sl, tp1, "E2_L1");
      ok2 = e2_trade.Buy (abLeg, g_e2_sym, 0, sl, tp2, "E2_L2");
     }
   else
     {
      ok1 = e2_trade.Sell(abLeg, g_e2_sym, 0, sl, tp1, "E2_L1");
      ok2 = e2_trade.Sell(abLeg, g_e2_sym, 0, sl, tp2, "E2_L2");
     }

   if(ok1 && ok2)
     {
      g_e2_tradesToday++;
      g_e2_state = E2_ST_IDLE;
      g_e2_breakAge = 0;
      g_e2_retestTouched = false;
      g_e2_twoLegOpen = true;
      g_e2_beTrailActive = false;
      return true;
     }
   if(ok1 && !ok2) E2_CloseOurPositionsEmergency();

   Print("E2: falha ao abrir pernas. ret1=", ok1, " ret2=", ok2,
         " err=", GetLastError(), " rc=", e2_trade.ResultRetcodeDescription());
   return false;
  }

void E2_OnTickWork()
  {
   g_e2_comment = "E2: aguardando…";

   MqlRates rates[];
   int need = E2_BarrasHistoricoLookback + 20;
   int got = CopyRates(g_e2_sym, E2_Timeframe, 0, need, rates);
   if(got < need - 5) return;

   datetime bar1 = rates[1].time;
   bool newBar = (bar1 != g_e2_lastBarTime);
   if(newBar) g_e2_lastBarTime = bar1;

   E2_ResetDayCounterIfNeeded();

   if(E2_CountOurPositions() > 0) { E2_ManagePostEntry(rates); return; }

   if(!newBar) return;

   // Toggle: bloqueia detecção de novos setups da Estratégia 2.
   // Gestão de posições existentes (acima) continua sempre rodando.
   if(!Estrategia2_Ativada)
     {
      if(g_e2_state != E2_ST_IDLE)
        { g_e2_state = E2_ST_IDLE; g_e2_breakAge = 0; g_e2_retestTouched = false; }
      return;
     }

   if(!E2_CanOpenNewSetup())
     {
      if(g_e2_state != E2_ST_IDLE)
        { g_e2_state = E2_ST_IDLE; g_e2_breakAge = 0; g_e2_retestTouched = false; }
      if(E2_MostrarStatusGrafico)
        {
         MqlDateTime dtx; TimeToStruct(TimeCurrent(), dtx);
         g_e2_comment = StringFormat(
            "E2 v2 | %s | aguardando janela | h=%02d | ses=%s | hBlk=%s | q=%s | spr=%s | est=%d",
            g_e2_sym, dtx.hour,
            (E2_InSession() ? "sim" : "não"),
            (E2_IsServerHourBlocked() ? "SIM" : "não"),
            (E2_IsWednesdaySkip() ? "SIM" : "não"),
            (E2_SpreadOK() ? "ok" : "alto"),
            (int)g_e2_state);
        }
      return;
     }

   if(g_e2_tradesToday >= E2_MaxTradesPorDia) return;

   int w = MathMax(1, E2_FractalMeiaLargura);

   double atrBuf[];
   if(CopyBuffer(g_e2_atrHandle, 0, 0, 3, atrBuf) < 1) return;
   double atr = atrBuf[1];
   if(atr <= 0) return;

   double body = MathAbs(rates[1].close - rates[1].open);
   double minBody = E2_CorpoMinimoXAtr * atr;

   // v9: zona de reteste e buffer de rompimento em múltiplos de ATR
   // (antes eram preços absolutos hardcoded p/ ouro: 1.5 e 0.3).
   const double abZona = E2_ZonaRetesteXAtr    * atr;
   const double abBuf  = E2_BufferRompimentoXAtr * atr;

   double resPrice = 0; int resIdx = -1;
   double supPrice = 0; int supIdx = -1;
   E2_NearestFractalHigh(rates, w, w + 1, resPrice, resIdx);
   E2_NearestFractalLow (rates, w, w + 1, supPrice, supIdx);

   if(g_e2_state == E2_ST_IDLE)
     {
      if(resPrice > 0 && rates[1].close > resPrice + abBuf && body >= minBody)
        { g_e2_state = E2_ST_BULL_BREAK; g_e2_flipLevel = resPrice; g_e2_breakAge = 0; g_e2_retestTouched = false; }
      else if(supPrice > 0 && rates[1].close < supPrice - abBuf && body >= minBody)
        { g_e2_state = E2_ST_BEAR_BREAK; g_e2_flipLevel = supPrice; g_e2_breakAge = 0; g_e2_retestTouched = false; }
     }
   else if(g_e2_state == E2_ST_BULL_BREAK || g_e2_state == E2_ST_BULL_WAIT)
     {
      g_e2_breakAge++;
      if(g_e2_breakAge > E2_SetupMaxBarras) g_e2_state = E2_ST_IDLE;
      else
        {
         if(rates[1].close < g_e2_flipLevel - abZona * 2) g_e2_state = E2_ST_IDLE;
         else
           {
            if(!g_e2_retestTouched)
               if(rates[1].low <= g_e2_flipLevel + abZona
               && rates[1].low >= g_e2_flipLevel - abZona * 3)
                  g_e2_retestTouched = true;

            if(g_e2_retestTouched)
              {
               if(rates[1].close > g_e2_flipLevel + abBuf && rates[1].close > rates[1].open)
                 {
                  int oldest = MathMax(1, MathMin(g_e2_breakAge + 2, got - w - 1));
                  double sl  = E2_NormPrice(E2_LowestSinceBar(rates, 1, oldest) - abBuf);
                  double ask = SymbolInfoDouble(g_e2_sym, SYMBOL_ASK);
                  double tp1s = 0, tp2s = 0;
                  if(!E2_NextFractalHighAbove(rates, w, ask, tp1s))
                     tp1s = E2_NormPrice(ask + E2_AlvoFallback1_R * (ask - sl));
                  if(!E2_NextFractalHighAboveExcl(rates, w, ask, tp1s, tp2s))
                     tp2s = E2_NormPrice(ask + E2_AlvoFallback2_R * (ask - sl));

                  E2_EnforceMinimumStops(true, ask, atr, sl, tp1s, tp2s);
                  E2_CapTp2AtRiskMultiple(true, ask, sl, tp1s, tp2s);

                  if(E2_PassesSignalRangeFilter(rates, atr) && E2_H1AllowsLong()
                     && tp1s > ask && tp2s > tp1s
                     && E2_PassesTp1RiskReward(true, ask, sl, tp1s)
                     && E2_StopsDistanceOK(true, ask, sl, tp1s)
                     && E2_StopsDistanceOK(true, ask, sl, tp2s))
                     E2_OpenTwoLegs(true, sl, tp1s, tp2s);
                 }
               g_e2_state = E2_ST_BULL_WAIT;
              }
           }
        }
     }
   else if(g_e2_state == E2_ST_BEAR_BREAK || g_e2_state == E2_ST_BEAR_WAIT)
     {
      g_e2_breakAge++;
      if(g_e2_breakAge > E2_SetupMaxBarras) g_e2_state = E2_ST_IDLE;
      else
        {
         if(rates[1].close > g_e2_flipLevel + abZona * 2) g_e2_state = E2_ST_IDLE;
         else
           {
            if(!g_e2_retestTouched)
               if(rates[1].high >= g_e2_flipLevel - abZona
               && rates[1].high <= g_e2_flipLevel + abZona * 3)
                  g_e2_retestTouched = true;

            if(g_e2_retestTouched)
              {
               if(rates[1].close < g_e2_flipLevel - abBuf && rates[1].close < rates[1].open)
                 {
                  int oldest = MathMax(1, MathMin(g_e2_breakAge + 2, got - w - 1));
                  double sl  = E2_NormPrice(E2_HighestSinceBar(rates, 1, oldest) + abBuf);
                  double bid = SymbolInfoDouble(g_e2_sym, SYMBOL_BID);
                  double tp1s = 0, tp2s = 0;
                  if(!E2_NextFractalLowBelow(rates, w, bid, tp1s))
                     tp1s = E2_NormPrice(bid - E2_AlvoFallback1_R * (sl - bid));
                  if(!E2_NextFractalLowBelowExcl(rates, w, bid, tp1s, tp2s))
                     tp2s = E2_NormPrice(bid - E2_AlvoFallback2_R * (sl - bid));

                  E2_EnforceMinimumStops(false, bid, atr, sl, tp1s, tp2s);
                  E2_CapTp2AtRiskMultiple(false, bid, sl, tp1s, tp2s);

                  if(E2_PassesSignalRangeFilter(rates, atr) && E2_H1AllowsShort()
                     && tp1s < bid && tp2s < tp1s
                     && E2_PassesTp1RiskReward(false, bid, sl, tp1s)
                     && E2_StopsDistanceOK(false, bid, sl, tp1s)
                     && E2_StopsDistanceOK(false, bid, sl, tp2s))
                     E2_OpenTwoLegs(false, sl, tp1s, tp2s);
                 }
               g_e2_state = E2_ST_BEAR_WAIT;
              }
           }
        }
     }

   if(E2_MostrarStatusGrafico)
     {
      const long spr = SymbolInfoInteger(g_e2_sym, SYMBOL_SPREAD);
      MqlDateTime dtx; TimeToStruct(TimeCurrent(), dtx);
      g_e2_comment = StringFormat(
         "E2 v2 | %s | spr=%s/%d | ses=%s | hBlk=%s | q=%s | h=%02d | est=%d | tr=%d/%d",
         g_e2_sym, IntegerToString(spr), E2_SpreadMaximoPontos,
         (E2_InSession() ? "sim" : "não"),
         (E2_IsServerHourBlocked() ? "SIM" : "não"),
         (E2_IsWednesdaySkip() ? "SIM" : "não"),
         dtx.hour, (int)g_e2_state, g_e2_tradesToday, E2_MaxTradesPorDia);
     }
  }

int E2_Init()
  {
   E2_UseSymbol();
   if(!SymbolSelect(g_e2_sym, true))
      Print("E2: aviso — símbolo pode estar oculto: ", g_e2_sym);

   e2_trade.SetExpertMagicNumber(E2_MagicNumber);

   g_e2_atrHandle = iATR(g_e2_sym, E2_Timeframe, E2_PeriodoAtr);
   if(g_e2_atrHandle == INVALID_HANDLE) { Print("E2: falha iATR"); return INIT_FAILED; }

   g_e2_maH1Handle = INVALID_HANDLE;
   if(E2_UsarFiltroEmaH1)
     {
      g_e2_maH1Handle = iMA(g_e2_sym, PERIOD_H1, E2_PeriodoEmaH1, 0, MODE_EMA, PRICE_CLOSE);
      if(g_e2_maH1Handle == INVALID_HANDLE)
         Print("E2: falha iMA H1 (filtro desativado até corrigir)");
     }

   g_e2_lastBarTime = 0;
   g_e2_state = E2_ST_IDLE;

   // v9: reconstrução de estado após restart. Se sobrou 1 perna, simula a
   // transição 2->1 no próximo tick (ativa BE+trail); se 2, retoma normal.
   int nOpen = E2_CountOurPositions();
   if(nOpen >= 1)
     {
      g_e2_twoLegOpen      = true;
      g_e2_lastCount       = 2;
      g_e2_immediateBeDone = false;
      Print("E2 v9: restart com ", nOpen, " perna(s) aberta(s) — estado reconstruído.");
     }

   E2_InitBlockedHoursFromInput();
   Print("E2 | horas bloqueadas: \"", E2_HorasBloqueadasServidor, "\" | TP2 max ",
         DoubleToString(E2_MaxAlvoTp2_R, 1),
         "R | range filt ", DoubleToString(E2_MaxRangeSinalXAtr, 2),
         "×ATR | H1EMA=", (E2_UsarFiltroEmaH1 ? "sim" : "não"),
         " | skipQua=", (E2_PularQuartaFeira ? "sim" : "não"));
   if(E2_TipoLote == E2_LOTE_FIXO)
      Print("E2 lote: FIXO | por perna=", DoubleToString(E2_LoteFixoPorPerna, 2), " (2 ordens)");
   else if(E2_TipoLote == E2_LOTE_RISCO)
      Print("E2 lote: RISCO ", DoubleToString(E2_RiscoPorPernaPct, 2), "%/perna (v9)");
   else
      Print("E2 lote: DINÂMICO | base/perna=", DoubleToString(E2_LoteDinamicoBasePorPerna, 2),
            " | USD/degrau=", DoubleToString(E2_UsdPorDegrauSaldo, 0),
            " | +lote/perna/degrau=", DoubleToString(E2_IncLotePorDegrau, 2),
            " | lote/perna agora=", DoubleToString(E2_LotPerLeg(), 2));
   return INIT_SUCCEEDED;
  }

void E2_Deinit(const int reason)
  {
   if(g_e2_atrHandle  != INVALID_HANDLE) IndicatorRelease(g_e2_atrHandle);
   if(g_e2_maH1Handle != INVALID_HANDLE) IndicatorRelease(g_e2_maH1Handle);
  }

//==================================================================
//                BREAKPOINT v8 (E3) - HELPERS E LÓGICA
//==================================================================

int E3_CountPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e3_sym) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic == E3_MagicNumber || magic == E3_MagicNumber + 1) count++;
     }
   return count;
  }

void E3_CloseAllPositions(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e3_sym) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != E3_MagicNumber && magic != E3_MagicNumber + 1) continue;

      MqlTradeRequest request; ZeroMemory(request);
      MqlTradeResult  result;  ZeroMemory(result);
      long posType = PositionGetInteger(POSITION_TYPE);
      request.action    = TRADE_ACTION_DEAL;
      request.symbol    = g_e3_sym;
      request.position  = ticket;
      request.volume    = PositionGetDouble(POSITION_VOLUME);
      request.type      = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price     = (request.type == ORDER_TYPE_SELL)
                          ? SymbolInfoDouble(g_e3_sym, SYMBOL_BID)
                          : SymbolInfoDouble(g_e3_sym, SYMBOL_ASK);
      request.deviation = (ulong)E3_SlippagePontos;
      request.comment   = reason;
      request.magic     = (ulong)magic;

      if(!OrderSend(request, result))
         Print("E3 fechar #", ticket, ": ", GetLastError());
      else if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
         Print("E3 fechar retcode ", result.retcode, " ", result.comment);
     }
  }

double E3_CalculateLotSize()
  {
   if(E3_TipoLote == E3_LOT_TYPE_FIXED)
      return NormalizeDouble(E3_LoteFixoTotal, 2);

   double currentBalance = ConcordeCapital();
   int increments = (int)MathFloor(currentBalance / E3_UsdPorDegrauSaldo);
   if(increments < 0) increments = 0;
   double calculatedLot = E3_LoteDinamicoBaseTotal + increments * E3_IncLotePorDegrau;
   double normalizedLot = NormalizeDouble(calculatedLot, 2);
   if(normalizedLot < 0.01) normalizedLot = 0.01;
   return normalizedLot;
  }

// Versão do lote E3 para o painel (retorna lote por perna = total/2)
double E3_CalculateLotSize_Panel()
  {
   double total = E3_CalculateLotSize();
   double perLeg = NormalizeDouble(total / 2.0, 2);
   if(perLeg < 0.01) perLeg = 0.01;
   return perLeg;
  }

void E3_CheckNewDay()
  {
   datetime currentDay[];
   if(CopyTime(g_e3_sym, PERIOD_D1, 0, 1, currentDay) <= 0) return;

   if(currentDay[0] != g_e3_lastTradeDay)
     {
      g_e3_dailyStartBalance  = ConcordeCapital();
      g_e3_dailyStopHit       = false;
      g_e3_dailyTradeExecuted = false;
      g_e3_breakoutSetup      = false;

      const bool hasOpen = (E3_CountPositions() > 0);
      if(!hasOpen)
        {
         g_e3_tp1Ticket    = 0;
         g_e3_tp2Ticket    = 0;
         g_e3_entryPrice   = 0;
         g_e3_tp1Hit       = false;
         g_e3_breakEvenSet = false;
         g_e3_lastCandleTime = 0;
         g_e3_beStopLoss   = 0.0;
         g_e3_candleCount  = 0;
        }
      g_e3_lastTradeDay = currentDay[0];
     }
  }

bool E3_CheckDailyStop()
  {
   if(g_e3_dailyStopHit) return true;
   double currentBalance = ConcordeCapital();
   double dailyLoss      = g_e3_dailyStartBalance - currentBalance;
   double maxDailyLoss   = g_e3_dailyStartBalance * E3_StopDiarioPercent / 100.0;
   if(dailyLoss >= maxDailyLoss)
     {
      E3_CloseAllPositions("Stop Diário Atingido");
      g_e3_dailyStopHit = true;
      return true;
     }
   return false;
  }

bool E3_CheckEndOfDayClose()
  {
   if(!E3_AtivarFechamentoFimDia) return false;
   int closeHour = E3_HoraFechamentoServidor;
   if(closeHour < 0)  closeHour = 0;
   if(closeHour > 23) closeHour = 23;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < closeHour) return false;

   datetime currentDay[];
   if(CopyTime(g_e3_sym, PERIOD_D1, 0, 1, currentDay) <= 0) return false;
   if(g_e3_lastEndOfDayCloseDay == currentDay[0]) return true;

   if(E3_CountPositions() > 0) E3_CloseAllPositions("Fechamento diário programado");
   g_e3_dailyTradeExecuted   = true;
   g_e3_breakoutSetup        = false;
   g_e3_lastEndOfDayCloseDay = currentDay[0];
   return true;
  }

bool E3_IsNewCandleForATRUpdate()
  {
   datetime currentCandle[];
   if(CopyTime(g_e3_sym, E3_TimeframeAtrUpdate, 0, 1, currentCandle) <= 0) return false;
   if(currentCandle[0] == g_e3_lastATRUpdateCandle) return false;
   g_e3_lastATRUpdateCandle = currentCandle[0];
   return true;
  }

void E3_ManageDynamicATRTakeProfitOnly()
  {
   if(!E3_AtivarAtrDinamico) return;
   if(!E3_IsNewCandleForATRUpdate()) return;

   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_e3_atrHandle, 0, 1, 1, atr) <= 0) return;

   double riskDist = atr[0] * E3_StopLossXAtr;
   if(riskDist <= 0.0) return;

   long minDistancePoints = SymbolInfoInteger(g_e3_sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance     = minDistancePoints * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e3_sym) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != E3_MagicNumber && magic != E3_MagicNumber + 1) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double rr        = (magic == E3_MagicNumber) ? E3_AlvoPerna1_R : E3_AlvoPerna2_R;

      double newTP = 0.0;
      if(posType == POSITION_TYPE_BUY)       newTP = openPrice + (riskDist * rr);
      else if(posType == POSITION_TYPE_SELL) newTP = openPrice - (riskDist * rr);
      else continue;

      double bid = SymbolInfoDouble(g_e3_sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_e3_sym, SYMBOL_ASK);
      if(minDistance > 0)
        {
         if(posType == POSITION_TYPE_BUY)  { if(newTP < ask + minDistance) continue; }
         else                              { if(newTP > bid - minDistance) continue; }
        }

      newTP = NormalizeDouble(newTP, g_e3_digits);
      if(MathAbs(newTP - currentTP) < _Point) continue;

      // blindagem: não modificar sem conexão (evita "no connection")
      // nem em posição que já foi fechada (evita err=4756 por ticket inexistente).
      if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return;
      if(!PositionSelectByTicket(ticket)) continue;

      MqlTradeRequest request; ZeroMemory(request);
      MqlTradeResult  result;  ZeroMemory(result);
      request.action   = TRADE_ACTION_SLTP;
      request.symbol   = g_e3_sym;
      request.position = ticket;
      request.sl       = currentSL;
      request.tp       = newTP;

      if(!OrderSend(request, result))
         Print("E3 ATR-TP: erro #", ticket, " err=", GetLastError());
      else if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
         Print("E3 ATR-TP: retcode ", result.retcode, " ", result.comment);
     }
  }

bool E3_IsLondonSession()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour - Concorde_SrvGmtOffset();   // v9: fuso auto/DST
   if(hour < 0)  hour += 24;
   if(hour >= 24) hour -= 24;
   return (hour >= E3_SessaoLondres_InicioGMT && hour < E3_SessaoLondres_FimGMT);
  }

bool E3_IsAsianSession()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour - Concorde_SrvGmtOffset();   // v9: fuso auto/DST
   if(hour < 0)  hour += 24;
   if(hour >= 24) hour -= 24;
   return (hour >= E3_SessaoAsia_InicioGMT && hour < E3_SessaoAsia_FimGMT);
  }

// v9: range asiático = high/low da SESSÃO INTEIRA (E3_SessaoAsia_InicioGMT
// até FimGMT do dia GMT atual). A versão antiga copiava só 12 barras M15
// (3h rolling, atualizadas 1x por candle H1) e nem cobria a sessão de 4h.
void E3_UpdateAsianRangeSession()
  {
   datetime now = TimeCurrent();
   long gmtSec = (long)now - (long)Concorde_SrvGmtOffset() * 3600;
   int  sod    = (int)(gmtSec % 86400);
   if(sod < 0) sod += 86400;
   datetime srvGmtMidnight = now - sod;   // instante (hora do servidor) da meia-noite GMT
   datetime asiaStart = srvGmtMidnight + E3_SessaoAsia_InicioGMT * 3600;
   datetime asiaEnd   = srvGmtMidnight + E3_SessaoAsia_FimGMT    * 3600;
   if(now <= asiaStart) return;           // sessão de hoje ainda não começou

   datetime copyEnd = (now < asiaEnd ? now : asiaEnd);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int n = CopyRates(g_e3_sym, PERIOD_M15, asiaStart - 60, copyEnd + 60, rates);
   if(n <= 0) return;

   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < n; i++)
     {
      if(rates[i].time < asiaStart || rates[i].time >= asiaEnd) continue;
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
     }
   if(hi > -DBL_MAX/2 && lo < DBL_MAX/2 && hi > lo)
     { g_e3_asiaHigh = hi; g_e3_asiaLow = lo; }
  }

void E3_CheckBreakoutSetup()
  {
   static datetime lastSetupCheck = 0;
   datetime currentTime[];
   if(CopyTime(g_e3_sym, PERIOD_M15, 0, 1, currentTime) <= 0) return;
   if(currentTime[0] == lastSetupCheck) return;
   lastSetupCheck = currentTime[0];

   // v9: recalcula na Ásia (range parcial cresce) e em Londres (range completo).
   if(E3_IsAsianSession() || E3_IsLondonSession()) E3_UpdateAsianRangeSession();

   // v9: range mínimo em múltiplos de ATR (0 = desligado). O antigo
   // E3_MinRangeAsiaPreco=0.0003 era valor de FX — no ouro, filtro morto.
   double minRange = 0.0;
   if(E3_MinRangeAsiaXAtr > 0.0)
     {
      double atrv[]; ArraySetAsSeries(atrv, true);
      if(CopyBuffer(g_e3_atrHandle, 0, 1, 1, atrv) > 0) minRange = atrv[0] * E3_MinRangeAsiaXAtr;
     }

   if(E3_IsLondonSession() && !g_e3_breakoutSetup && !g_e3_dailyTradeExecuted)
      if(g_e3_asiaHigh > 0 && g_e3_asiaLow > 0
      && (g_e3_asiaHigh - g_e3_asiaLow) > minRange)
        { g_e3_breakoutSetup = true; g_e3_setupTime = TimeCurrent(); }
  }

void E3_OpenSplitPosition(const ENUM_ORDER_TYPE type, double price, double sl,
                          double tp1, double tp2, const string comment)
  {
   price = NormalizeDouble(price, g_e3_digits);
   sl    = NormalizeDouble(sl,    g_e3_digits);
   tp1   = NormalizeDouble(tp1,   g_e3_digits);
   tp2   = NormalizeDouble(tp2,   g_e3_digits);

   long minDistancePoints = SymbolInfoInteger(g_e3_sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance     = minDistancePoints * _Point;
   if(type == ORDER_TYPE_BUY)
     {
      if(sl  > price - minDistance) sl  = price - minDistance;
      if(tp1 < price + minDistance) tp1 = price + minDistance;
      if(tp2 < price + minDistance) tp2 = price + minDistance;
     }
   else
     {
      if(sl  < price + minDistance) sl  = price + minDistance;
      if(tp1 > price - minDistance) tp1 = price - minDistance;
      if(tp2 > price - minDistance) tp2 = price - minDistance;
     }

   // v9: lote por perna — modo RISK usa a distância real entrada->SL.
   double lotSize;
   if(E3_TipoLote == E3_LOT_TYPE_RISK)
      lotSize = Concorde_LotsByRisk(g_e3_sym, MathAbs(price - sl), E3_RiscoPorPernaPct, 0.01);
   else
     {
      double totalLot = E3_CalculateLotSize();
      lotSize = NormalizeDouble(totalLot / 2.0, 2);
      if(lotSize < 0.01) lotSize = 0.01;
     }

   g_e3_tp1Ticket = 0; g_e3_tp2Ticket = 0; g_e3_entryPrice = 0;
   g_e3_tp1Hit = false; g_e3_breakEvenSet = false;
   g_e3_lastCandleTime = 0; g_e3_beStopLoss = 0.0; g_e3_candleCount = 0;

   MqlTradeRequest request1; ZeroMemory(request1);
   MqlTradeResult  result1;  ZeroMemory(result1);
   request1.action    = TRADE_ACTION_DEAL;
   request1.symbol    = g_e3_sym;
   request1.volume    = lotSize;
   request1.type      = type;
   request1.price     = (type == ORDER_TYPE_BUY)
                        ? SymbolInfoDouble(g_e3_sym, SYMBOL_ASK)
                        : SymbolInfoDouble(g_e3_sym, SYMBOL_BID);
   request1.sl        = sl;
   request1.tp        = tp1;
   request1.comment   = comment + " TP1";
   request1.magic     = (ulong)E3_MagicNumber;
   request1.deviation = (ulong)E3_SlippagePontos;

   if(OrderSend(request1, result1)
      && (result1.retcode == TRADE_RETCODE_DONE || result1.retcode == TRADE_RETCODE_PLACED))
     {
      // v9: ticket direto do deal retornado — sem Sleep() (que congelava as
      // 4 estratégias por 300ms) nem re-scan de posições.
      if(result1.deal > 0 && HistoryDealSelect(result1.deal))
         g_e3_tp1Ticket = (ulong)HistoryDealGetInteger(result1.deal, DEAL_POSITION_ID);
      if(g_e3_tp1Ticket == 0)
         for(int i = PositionsTotal() - 1; i >= 0; i--)
           {
            ulong posTicket = PositionGetTicket(i);
            if(posTicket > 0 && PositionSelectByTicket(posTicket))
               if(PositionGetString(POSITION_SYMBOL) == g_e3_sym
               && PositionGetInteger(POSITION_MAGIC) == E3_MagicNumber)
                 { g_e3_tp1Ticket = posTicket; break; }
           }

      MqlTradeRequest request2; ZeroMemory(request2);
      MqlTradeResult  result2;  ZeroMemory(result2);
      request2.action    = TRADE_ACTION_DEAL;
      request2.symbol    = g_e3_sym;
      request2.volume    = lotSize;
      request2.type      = type;
      request2.price     = (type == ORDER_TYPE_BUY)
                           ? SymbolInfoDouble(g_e3_sym, SYMBOL_ASK)
                           : SymbolInfoDouble(g_e3_sym, SYMBOL_BID);
      request2.sl        = sl;
      request2.tp        = tp2;
      request2.comment   = comment + " TP2";
      request2.magic     = (ulong)(E3_MagicNumber + 1);
      request2.deviation = (ulong)E3_SlippagePontos;

      if(OrderSend(request2, result2)
         && (result2.retcode == TRADE_RETCODE_DONE || result2.retcode == TRADE_RETCODE_PLACED))
        {
         // v9: ticket direto do deal — sem Sleep().
         if(result2.deal > 0 && HistoryDealSelect(result2.deal))
            g_e3_tp2Ticket = (ulong)HistoryDealGetInteger(result2.deal, DEAL_POSITION_ID);
         if(g_e3_tp2Ticket != 0 && PositionSelectByTicket(g_e3_tp2Ticket))
            g_e3_entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         else
            for(int j = PositionsTotal() - 1; j >= 0; j--)
              {
               ulong posTicket2 = PositionGetTicket(j);
               if(posTicket2 > 0 && PositionSelectByTicket(posTicket2))
                  if(PositionGetString(POSITION_SYMBOL) == g_e3_sym
                  && PositionGetInteger(POSITION_MAGIC) == E3_MagicNumber + 1)
                    {
                     g_e3_tp2Ticket  = posTicket2;
                     g_e3_entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                     break;
                    }
              }
        }
     }
  }

void E3_ExecuteBreakout()
  {
   if(g_e3_dailyTradeExecuted) { g_e3_breakoutSetup = false; return; }
   if(E3_CountPositions() > 0) return;
   if(Concorde_GlobalStopActive()) return;   // v9: stop diário global

   double currentPrice = SymbolInfoDouble(g_e3_sym, SYMBOL_BID);
   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_e3_atrHandle, 0, 1, 1, atr) <= 0) return;

   if(currentPrice > g_e3_asiaHigh)
     {
      if(!Concorde_CanOpenLegs(g_e3_sym, true, 2)) return;   // v9: cap de exposição
      double entry    = SymbolInfoDouble(g_e3_sym, SYMBOL_ASK);
      double stopLoss = entry - (atr[0] * E3_StopLossXAtr);
      double tp1      = entry + (atr[0] * E3_StopLossXAtr * E3_AlvoPerna1_R);
      double tp2      = entry + (atr[0] * E3_StopLossXAtr * E3_AlvoPerna2_R);
      E3_OpenSplitPosition(ORDER_TYPE_BUY, entry, stopLoss, tp1, tp2, "E3_BUY");
      g_e3_dailyTradeExecuted = true;
      g_e3_breakoutSetup      = false;
     }
   else if(currentPrice < g_e3_asiaLow)
     {
      if(!Concorde_CanOpenLegs(g_e3_sym, false, 2)) return;  // v9: cap de exposição
      double entry    = SymbolInfoDouble(g_e3_sym, SYMBOL_BID);
      double stopLoss = entry + (atr[0] * E3_StopLossXAtr);
      double tp1      = entry - (atr[0] * E3_StopLossXAtr * E3_AlvoPerna1_R);
      double tp2      = entry - (atr[0] * E3_StopLossXAtr * E3_AlvoPerna2_R);
      E3_OpenSplitPosition(ORDER_TYPE_SELL, entry, stopLoss, tp1, tp2, "E3_SELL");
      g_e3_dailyTradeExecuted = true;
      g_e3_breakoutSetup      = false;
     }
  }

void E3_ManageBreakEven()
  {
   if(!E3_AtivarBreakEven || g_e3_breakEvenSet) return;

   bool   tp1Open = false, tp2Open = false;
   ulong  tp2TicketLocal = 0;
   ENUM_POSITION_TYPE tp2Type = WRONG_VALUE;
   double tp2OpenPrice = 0.0, tp2Stop = 0.0, tp2Take = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_e3_sym) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic == E3_MagicNumber) tp1Open = true;
      else if(magic == E3_MagicNumber + 1)
        {
         tp2Open = true;
         tp2TicketLocal = ticket;
         tp2Type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         tp2OpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         tp2Stop      = PositionGetDouble(POSITION_SL);
         tp2Take      = PositionGetDouble(POSITION_TP);
        }
     }

   if(!tp2Open) { g_e3_tp2Ticket = 0; g_e3_entryPrice = 0; return; }

   g_e3_tp2Ticket  = tp2TicketLocal;
   g_e3_entryPrice = tp2OpenPrice;

   if(tp1Open) return;

   // v9: g_e3_tp1Hit normalmente já chega aqui setado pelo OnTradeTransaction.
   // Fallback (ex.: restart): busca no histórico LIMITADO a 3 dias — antes era
   // HistorySelect(0,...) sobre a conta inteira A CADA TICK.
   if(!g_e3_tp1Hit)
     {
      HistorySelect(TimeCurrent() - 3*86400, TimeCurrent());
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d > 0
            && HistoryDealGetString(d, DEAL_SYMBOL) == g_e3_sym
            && HistoryDealGetInteger(d, DEAL_MAGIC) == E3_MagicNumber
            && HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_OUT)
           { g_e3_tp1Hit = true; break; }
        }
     }

   if(!g_e3_tp1Hit) return;

   // v2: adota BE ja aplicado (ex.: apos restart do EA/terminal) e destrava o trailing.
   // Sem isto, apos qualquer reinit com o SL ja no BE, a funcao retornava sem marcar
   // g_e3_breakEvenSet e o trailing ficava morto para sempre.
   if(tp2Stop != 0.0
      && ((tp2Type == POSITION_TYPE_BUY  && tp2Stop >= tp2OpenPrice)
       || (tp2Type == POSITION_TYPE_SELL && tp2Stop <= tp2OpenPrice)))
     {
      g_e3_breakEvenSet = true;
      g_e3_beStopLoss   = tp2Stop;
      g_e3_candleCount  = 0;
      datetime ctAdopt[];
      if(CopyTime(g_e3_sym, PERIOD_M15, 0, 1, ctAdopt) > 0)
         g_e3_lastCandleTime = ctAdopt[0];
      else
         g_e3_lastCandleTime = 0;
      Print("E3: BE ja aplicado detectado (pos-restart) - trailing reativado. SL=",
            DoubleToString(tp2Stop, g_e3_digits));
      return;
     }

   double buffer = E3_BreakEvenBufferPips * g_e3_pip;
   double bePrice = (tp2Type == POSITION_TYPE_BUY)
                    ? tp2OpenPrice + buffer : tp2OpenPrice - buffer;
   bePrice = NormalizeDouble(bePrice, g_e3_digits);

   long minDistancePoints = SymbolInfoInteger(g_e3_sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance     = minDistancePoints * _Point;
   double currentPrice    = (tp2Type == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(g_e3_sym, SYMBOL_BID)
                            : SymbolInfoDouble(g_e3_sym, SYMBOL_ASK);

   if(tp2Type == POSITION_TYPE_BUY)
     {
      if(minDistance > 0 && (currentPrice - bePrice) < minDistance)
         bePrice = NormalizeDouble(currentPrice - minDistance, g_e3_digits);
      if(bePrice <= tp2Stop || bePrice >= currentPrice) return;
     }
   else
     {
      if(minDistance > 0 && (bePrice - currentPrice) < minDistance)
         bePrice = NormalizeDouble(currentPrice + minDistance, g_e3_digits);
      if((tp2Stop != 0 && bePrice >= tp2Stop) || bePrice <= currentPrice) return;
     }

   MqlTradeRequest request; ZeroMemory(request);
   MqlTradeResult  result;  ZeroMemory(result);
   request.action   = TRADE_ACTION_SLTP;
   request.symbol   = g_e3_sym;
   request.position = tp2TicketLocal;
   request.sl       = bePrice;
   request.tp       = tp2Take;

   if(OrderSend(request, result)
      && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED))
     {
      g_e3_breakEvenSet = true;
      g_e3_beStopLoss   = bePrice;
      g_e3_candleCount  = 0;
      datetime currentCandleTime[];
      if(CopyTime(g_e3_sym, PERIOD_M15, 0, 1, currentCandleTime) > 0)
         g_e3_lastCandleTime = currentCandleTime[0];
      else
         g_e3_lastCandleTime = 0;
     }
  }

void E3_ManageIncrementalTrailing()
  {
   if(!E3_AtivarTrailingStop || !g_e3_breakEvenSet || g_e3_tp2Ticket == 0) return;
   if(!PositionSelectByTicket(g_e3_tp2Ticket))
     {
      g_e3_breakEvenSet = false; g_e3_beStopLoss = 0.0;
      g_e3_lastCandleTime = 0;   g_e3_candleCount = 0;
      return;
     }

   datetime currentCandle[];
   if(CopyTime(g_e3_sym, PERIOD_M15, 0, 1, currentCandle) <= 0) return;
   if(currentCandle[0] == g_e3_lastCandleTime) return;

   g_e3_lastCandleTime = currentCandle[0];
   g_e3_candleCount++;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double currentStop = PositionGetDouble(POSITION_SL);
   double currentTP   = PositionGetDouble(POSITION_TP);

   if(g_e3_beStopLoss == 0.0) g_e3_beStopLoss = currentStop;

   double increment = E3_TrailingIncrementoPontos * _Point;
   double newStop   = 0.0;
   if(posType == POSITION_TYPE_BUY)
     {
      newStop = g_e3_beStopLoss + (increment * g_e3_candleCount);
      double currentPrice = SymbolInfoDouble(g_e3_sym, SYMBOL_BID);
      long minDistancePoints = SymbolInfoInteger(g_e3_sym, SYMBOL_TRADE_STOPS_LEVEL);
      double minDistance = minDistancePoints * _Point;
      double maxStop = currentPrice - minDistance;
      if(newStop > maxStop) newStop = maxStop;
     }
   else if(posType == POSITION_TYPE_SELL)
     {
      newStop = g_e3_beStopLoss - (increment * g_e3_candleCount);
      double currentPrice = SymbolInfoDouble(g_e3_sym, SYMBOL_ASK);
      long minDistancePoints = SymbolInfoInteger(g_e3_sym, SYMBOL_TRADE_STOPS_LEVEL);
      double minDistance = minDistancePoints * _Point;
      double minStop = currentPrice + minDistance;
      if(newStop < minStop) newStop = minStop;
     }
   else return;

   newStop = NormalizeDouble(newStop, g_e3_digits);
   if(MathAbs(newStop - currentStop) < _Point) return;

   // blindagem: não modificar sem conexão nem em posição já fechada.
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return;
   if(!PositionSelectByTicket(g_e3_tp2Ticket)) return;

   MqlTradeRequest request; ZeroMemory(request);
   MqlTradeResult  result;  ZeroMemory(result);
   request.action   = TRADE_ACTION_SLTP;
   request.symbol   = g_e3_sym;
   request.position = g_e3_tp2Ticket;
   request.sl       = newStop;
   request.tp       = currentTP;

   if(!OrderSend(request, result))
      Print("E3 trailing: erro ", GetLastError());
   else if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
      Print("E3 trailing: retcode ", result.retcode, " ", result.comment);
  }

void E3_CheckBrokerTime()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int off        = Concorde_SrvGmtOffset();
   int serverHour = dt.hour;
   int gmtHour    = serverHour - off;
   if(gmtHour < 0)  gmtHour += 24;
   if(gmtHour >= 24) gmtHour -= 24;
   Print("Concorde/E3: servidor ", TimeToString(TimeCurrent(), TIME_MINUTES),
         " | GMT offset (v9 auto/DST) ", off, " | GMT calc ", gmtHour, ":00");
  }

int E3_Init()
  {
   // v3.01: o simbolo do grafico e sempre valido - usa direto; o sufixo so entra
   // como fallback (evita 'XAUUSD.p.pro' ao anexar com sufixo default errado).
   g_e3_sym = _Symbol;
   if(!SymbolSelect(g_e3_sym, true)
      && StringLen(E3_SufixoSimbolo) > 0 && StringFind(g_e3_sym, E3_SufixoSimbolo) < 0)
      g_e3_sym = _Symbol + E3_SufixoSimbolo;

   // v9: símbolo inválido agora ABORTA o init. Antes só imprimia "aviso" e o E3
   // seguia com dados lixo (ex.: gráfico XAUUSD.p + sufixo .pro = XAUUSD.p.pro).
   if(!SymbolSelect(g_e3_sym, true))
     {
      Print("E3: símbolo inválido/não encontrado: '", g_e3_sym,
            "'. Confira o gráfico e o input E3_SufixoSimbolo. Init abortado.");
      return INIT_FAILED;
     }

   g_e3_digits = (int)SymbolInfoInteger(g_e3_sym, SYMBOL_DIGITS);
   g_e3_pip    = (g_e3_digits == 2) ? 0.01
               : (g_e3_digits == 3) ? 0.001
               : (g_e3_digits == 4) ? 0.0001
               : (g_e3_digits == 5) ? 0.00001 : _Point;
   g_e3_pipFactor = g_e3_pip / _Point;

   g_e3_dailyStartBalance    = ConcordeCapital();
   g_e3_lastTradeDay         = TimeCurrent();
   g_e3_dailyTradeExecuted   = false;
   g_e3_tp1Ticket            = 0;
   g_e3_tp2Ticket            = 0;
   g_e3_entryPrice           = 0;
   g_e3_tp1Hit               = false;
   g_e3_breakEvenSet         = false;
   g_e3_lastCandleTime       = 0;
   g_e3_beStopLoss           = 0.0;
   g_e3_candleCount          = 0;
   g_e3_lastEndOfDayCloseDay = 0;
   g_e3_lastATRUpdateCandle  = 0;

   g_e3_atrHandle = iATR(g_e3_sym, PERIOD_M15, E3_PeriodoAtr);
   if(g_e3_atrHandle == INVALID_HANDLE) { Print("E3: falha iATR ", GetLastError()); return INIT_FAILED; }

   E3_CheckBrokerTime();
   return INIT_SUCCEEDED;
  }

void E3_Deinit(const int reason)
  {
   if(g_e3_atrHandle != INVALID_HANDLE) IndicatorRelease(g_e3_atrHandle);
   if(reason != REASON_CHARTCHANGE) Print("E3: deinit ", reason);
  }

void E3_OnTick()
  {
   E3_CheckNewDay();

   if(E3_CheckDailyStop())     { g_e3_comment = "E3: stop diário ativo"; return; }
   if(E3_CheckEndOfDayClose()) { g_e3_comment = "E3: fechamento fim-dia / bloqueio"; return; }

   long   spreadPoints = SymbolInfoInteger(g_e3_sym, SYMBOL_SPREAD);
   double spread       = spreadPoints * _Point;
   if(spread > E3_SpreadMaximoPips * g_e3_pipFactor) { g_e3_comment = "E3: spread alto"; return; }

   if(E3_AtivarAtrDinamico)              E3_ManageDynamicATRTakeProfitOnly();
   if(E3_AtivarBreakEven)                     E3_ManageBreakEven();
   if(E3_AtivarTrailingStop && g_e3_breakEvenSet) E3_ManageIncrementalTrailing();

   // Toggle: bloqueia novas entradas da Estratégia 3.
   // Gestão de posições existentes (acima) continua sempre rodando.
   if(!Estrategia3_Ativada)
     {
      g_e3_comment = "E3: DESLIGADA (gerenciando posições existentes)";
      return;
     }

   if(News_StratBlock(g_e3_sym))
     {
      g_e3_comment = "E3: bloqueado por notícia";
      return;
     }

   E3_CheckBreakoutSetup();
   if(g_e3_breakoutSetup && E3_IsLondonSession()) E3_ExecuteBreakout();

   g_e3_comment = StringFormat("E3: pos=%d | setup=%s | tradeDia=%s | AsiaH/L=%.5f/%.5f",
                               E3_CountPositions(),
                               (g_e3_breakoutSetup      ? "sim" : "não"),
                               (g_e3_dailyTradeExecuted ? "sim" : "não"),
                               g_e3_asiaHigh, g_e3_asiaLow);
  }

//==================================================================
//   E1 - Init / Deinit
//==================================================================

int E1_Init()
  {
   g_e1_symbol = (E1_Simbolo == "" ? _Symbol : E1_Simbolo);
   if(!SymbolSelect(g_e1_symbol, true))
     { Print("E1: símbolo não disponível: ", g_e1_symbol); return INIT_FAILED; }

   g_e1_volume_min  = SymbolInfoDouble(g_e1_symbol, SYMBOL_VOLUME_MIN);
   g_e1_volume_max  = SymbolInfoDouble(g_e1_symbol, SYMBOL_VOLUME_MAX);
   g_e1_volume_step = SymbolInfoDouble(g_e1_symbol, SYMBOL_VOLUME_STEP);
   g_e1_pip_size    = E1_PipSizeForSymbol(g_e1_symbol);

   e1_trade.SetExpertMagicNumber(E1_MagicNumber);
   E1_ResetTrailState();

   // v9: reconstrução de estado após restart — se só a perna TP5 sobrou,
   // o TP1 já caiu: rearma o trail (antes, restart deixava a perna órfã).
   ulong t3 = 0, t5 = 0;
   bool has3 = E1_PositionExistsByComment(E1_COMMENT_TP3, t3);
   bool has5 = E1_PositionExistsByComment(E1_COMMENT_TP5, t5);
   if(has5 && !has3)
     {
      g_e1_trail_armed = true;
      g_e1_be_done     = false;   // BE re-aplicado (só sobe o SL; inofensivo)
      Print("E1 v9: restart com perna TP5 órfã #", t5, " — trail rearmado.");
     }

   int emin = E1_HoraSaidaGMT_Minutos;
   if(emin < 0) emin = 0;
   if(emin > 1439) emin = 1439;
   int eh = emin / 60, em = emin % 60;

   string loteInfo;
   if(E1_TipoLote == E1_LOTE_FIXO)
      loteInfo = StringFormat("FIXO | P1=%.2f | P2=%.2f", E1_LotePerna1, E1_LotePerna2);
   else if(E1_TipoLote == E1_LOTE_RISCO)
      loteInfo = StringFormat("RISCO %.2f%%/perna (v9)", E1_RiscoPorPernaPct);
   else
      loteInfo = StringFormat("DINÂMICO | base=%.2f | USD/degrau=%.0f | +lote/degrau=%.2f | agora=%.2f/%.2f",
                     E1_LoteDinamicoBasePorPerna, E1_UsdPorDegrauSaldo, E1_IncLotePorDegrau,
                     E1_LotPerLeg(1), E1_LotPerLeg(2));

   Print("E1 | Saída GMT0 >= ", IntegerToString(eh, 2, '0'), ":",
         IntegerToString(em, 2, '0'),
         " | Trail=", EnumToString(E1_TrailTimeframe),
         " | TPs min=", DoubleToString(E1_TakeProfitMinimoR, 1), "R",
         " | Lote: ", loteInfo,
         " | Conta hedge recomendada.");
   return INIT_SUCCEEDED;
  }

void E1_Deinit(const int reason) {}

//==================================================================
//        E4 CONNORS MULTI (RSI) - Estratégia 4 - HELPERS
//==================================================================

bool E4_GetVal(int handle, int shift, double &v)
  {
   double tmp[];
   if(CopyBuffer(handle, 0, shift, 1, tmp) <= 0) return(false);
   v = tmp[0]; return(true);
  }

// Travas de perda da Estratégia 4: true = novas entradas permitidas
bool E4_LossLocksAllow()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_e4_curDay)
     {
      g_e4_curDay = dt.day_of_year;
      g_e4_dayStartBal = ConcordeCapital();
     }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_e4_eqPeak) g_e4_eqPeak = eq;

   if(E4_UseDDLock && g_e4_eqPeak > 0)
     {
      double dd = (g_e4_eqPeak - eq) / g_e4_eqPeak * 100.0;
      if(dd >= E4_MaxDDPct)
        {
         if(!g_e4_ddLocked) PrintFormat("E4 TRAVA DE DRAWDOWN ativada: %.1f%%. Sem novas entradas até reiniciar o EA.", dd);
         g_e4_ddLocked = true;
        }
     }
   if(g_e4_ddLocked) return(false);

   if(E4_UseDailyLock && g_e4_dayStartBal > 0)
     {
      double loss = (g_e4_dayStartBal - eq) / g_e4_dayStartBal * 100.0;
      if(loss >= E4_DailyLossPct) return(false); // libera no dia seguinte
     }
   return(true);
  }

bool E4_IsRolloverHour()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return(dt.hour == 23 || dt.hour == 0);
  }

// Horas GMT bloqueadas para novas entradas da E4 (lista "8,18").
bool g_e4_blockedHours[24];

void E4_ParseBlockedHours()
  {
   for(int i = 0; i < 24; i++) g_e4_blockedHours[i] = false;
   string parts[];
   int n = StringSplit(E4_HorasBloqueadasGMT, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string p = parts[i];
      StringTrimLeft(p); StringTrimRight(p);
      if(p == "") continue;
      int h = (int)StringToInteger(p);
      if(h >= 0 && h < 24) g_e4_blockedHours[h] = true;
     }
  }

bool E4_BlockedHourNow()
  {
   int gh, gm, gs; E1_GmtTimeOfDay(TimeCurrent(), gh, gm, gs);
   return g_e4_blockedHours[gh];
  }

bool E4_IsFridayCloseTime()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return(dt.day_of_week == 5 && dt.hour >= E4_FridayCloseHour);
  }

double E4_CalcLots(string sym, double slDistancePrice)
  {
   // v9.1: modo dinâmico por degraus de saldo (base + inc a cada X USD de capital).
   if(E4_UseDynLots)
     {
      double degraus = (E4_UsdPorDegrau > 0.0) ? MathFloor(ConcordeCapital() / E4_UsdPorDegrau) : 0.0;
      if(degraus < 0.0) degraus = 0.0;
      double lots = E4_DynBaseLots + degraus * E4_DynIncLots;
      double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      double stp  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      if(stp > 0) lots = MathFloor(lots / stp) * stp;
      return(MathMax(minL, MathMin(maxL, lots)));
     }
   if(!E4_UseStop || slDistancePrice <= 0) return(E4_FixedLots);
   double balance = ConcordeCapital();
   double riskMoney = balance * E4_RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return(E4_FixedLots);
   double valuePerLot = (slDistancePrice / tickSize) * tickValue;
   if(valuePerLot <= 0) return(E4_FixedLots);
   double lots = riskMoney / valuePerLot;
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double stp  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(stp > 0) lots = MathFloor(lots / stp) * stp;
   return(MathMax(minL, MathMin(maxL, lots)));
  }

bool E4_HasPosition(string sym, long &type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != E4_MagicNumber) continue;
      type = (long)PositionGetInteger(POSITION_TYPE); return(true);
     }
   return(false);
  }

void E4_ClosePosition(string sym)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != E4_MagicNumber) continue;
      if(!e4_trade.PositionClose(t))
         PrintFormat("E4 falha ao fechar #%I64u %s err=%d", t, sym, e4_trade.ResultRetcode());
     }
  }

void E4_CloseAllMagic()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != E4_MagicNumber) continue;
      if(!e4_trade.PositionClose(t))
         PrintFormat("E4 falha ao fechar #%I64u err=%d", t, e4_trade.ResultRetcode());
     }
  }

// Gestão a cada tick: saída por tempo e breakeven
void E4_ManageEveryTick(int idx)
  {
   if(E4_MaxBarsInTrade <= 0 && !E4_UseBreakEven) return;
   string sym = g_e4_cfg[idx].symbol;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != E4_MagicNumber) continue;

      // saída por tempo
      if(E4_MaxBarsInTrade > 0)
        {
         datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         if(TimeCurrent() - opened >= (long)E4_MaxBarsInTrade * PeriodSeconds(E4_Timeframe))
           {
            if(!e4_trade.PositionClose(t))
               PrintFormat("E4 falha saída por tempo #%I64u %s err=%d", t, sym, e4_trade.ResultRetcode());
            continue;
           }
        }

      // breakeven por ATR
      if(E4_UseBreakEven)
        {
         double atr;
         if(!E4_GetVal(g_e4_cfg[idx].hATR, 1, atr) || atr <= 0) continue;
         long   type = PositionGetInteger(POSITION_TYPE);
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl   = PositionGetDouble(POSITION_SL);
         double tp   = PositionGetDouble(POSITION_TP);
         int    dig  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         double bid  = SymbolInfoDouble(sym, SYMBOL_BID);
         double ask  = SymbolInfoDouble(sym, SYMBOL_ASK);

         if(type == POSITION_TYPE_BUY && bid - open >= E4_BEAtrTrigger * atr && (sl == 0 || sl < open))
           {
            double newSL = NormalizeDouble(open, dig);
            if(!e4_trade.PositionModify(t, newSL, tp))
               PrintFormat("E4 falha breakeven #%I64u %s err=%d", t, sym, e4_trade.ResultRetcode());
           }
         else if(type == POSITION_TYPE_SELL && open - ask >= E4_BEAtrTrigger * atr && (sl == 0 || sl > open))
           {
            double newSL = NormalizeDouble(open, dig);
            if(!e4_trade.PositionModify(t, newSL, tp))
               PrintFormat("E4 falha breakeven #%I64u %s err=%d", t, sym, e4_trade.ResultRetcode());
           }
        }
     }
  }

void E4_ProcessSymbol(int idx)
  {
   string sym = g_e4_cfg[idx].symbol;

   // novo candle no timeframe do par?
   datetime curBar = iTime(sym, E4_Timeframe, 0);
   if(curBar == 0) return;
   if(curBar == g_e4_cfg[idx].lastBar) return;
   g_e4_cfg[idx].lastBar = curBar;

   if(Bars(sym, E4_Timeframe) < g_e4_cfg[idx].trendMA + 5) return;

   double rsi, trendMA, exitMA, atr;
   if(!E4_GetVal(g_e4_cfg[idx].hRSI, 1, rsi)) return;
   if(!E4_GetVal(g_e4_cfg[idx].hTrendMA, 1, trendMA)) return;
   if(!E4_GetVal(g_e4_cfg[idx].hExitMA, 1, exitMA)) return;
   if(!E4_GetVal(g_e4_cfg[idx].hATR, 1, atr)) return;
   if(atr <= 0) return;

   double closePrev = iClose(sym, E4_Timeframe, 1);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   long posType = -1;
   bool hasPos = E4_HasPosition(sym, posType);

   // -------- SAÍDAS (sempre rodam, mesmo com a estratégia desligada) --------
   if(hasPos)
     {
      if(posType == POSITION_TYPE_BUY)
        {
         bool exitByRSI = (rsi > g_e4_cfg[idx].exitLong);
         bool exitByMA  = (E4_UseMAExit && closePrev > exitMA);
         if(exitByRSI || exitByMA) E4_ClosePosition(sym);
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         bool exitByRSI = (rsi < E4_ExitShort);
         bool exitByMA  = (E4_UseMAExit && closePrev < exitMA);
         if(exitByRSI || exitByMA) E4_ClosePosition(sym);
        }
      return;
     }

   // Toggle: bloqueia novas entradas da Estratégia 4.
   // Gestão de posições existentes (acima) continua sempre rodando.
   if(!Estrategia4_Ativada) return;

   // v9: stop diário global bloqueia novas entradas.
   if(Concorde_GlobalStopActive()) return;

   // Filtro de notícias: bloqueia novas entradas neste par durante a janela.
   if(News_StratBlock(sym)) return;

   // -------- filtros de entrada --------
   if(!E4_LossLocksAllow()) return;
   if(E4_BlockRollover && E4_IsRolloverHour()) return;
   if(E4_BlockedHourNow()) return;              // filtro de horas GMT
   if(E4_FridayClose && E4_IsFridayCloseTime()) return;

   // -------- filtro de spread --------
   if(E4_MaxSpreadPts > 0)
     {
      long spread = (long)SymbolInfoInteger(sym, SYMBOL_SPREAD);
      if(spread > E4_MaxSpreadPts) return;
     }

   // -------- ENTRADAS --------
   if(E4_AllowLong && closePrev > trendMA && rsi < g_e4_cfg[idx].buy)
     {
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double sl = E4_UseStop ? NormalizeDouble(ask - g_e4_cfg[idx].atrMult * atr, digits) : 0.0;
      double slDist = E4_UseStop ? (ask - sl) : 0.0;
      double lots = E4_CalcLots(sym, slDist);
      if(lots > 0 && !e4_trade.Buy(lots, sym, ask, sl, 0.0, "E4_L"))
         PrintFormat("E4 falha BUY %s err=%d", sym, e4_trade.ResultRetcode());
     }
   else if(E4_AllowShort && closePrev < trendMA && rsi > E4_SellLevel)
     {
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double sl = E4_UseStop ? NormalizeDouble(bid + g_e4_cfg[idx].atrMult * atr, digits) : 0.0;
      double slDist = E4_UseStop ? (sl - bid) : 0.0;
      double lots = E4_CalcLots(sym, slDist);
      if(lots > 0 && !e4_trade.Sell(lots, sym, bid, sl, 0.0, "E4_S"))
         PrintFormat("E4 falha SELL %s err=%d", sym, e4_trade.ResultRetcode());
     }
  }

int E4_Init()
  {
   E4_ParseBlockedHours();
   e4_trade.SetExpertMagicNumber(E4_MagicNumber);
   e4_trade.SetDeviationInPoints(20);

   bool    uses[E4_MAX_SYMS];
   string  syms[E4_MAX_SYMS];
   double  buys[E4_MAX_SYMS];
   int     trends[E4_MAX_SYMS];
   double  exls[E4_MAX_SYMS];
   double  atrs[E4_MAX_SYMS];

   uses[0]=E4_Use1; syms[0]=E4_Sym1; buys[0]=E4_Buy1; trends[0]=E4_Trend1; exls[0]=E4_ExitL1; atrs[0]=E4_ATR1;
   uses[1]=E4_Use2; syms[1]=E4_Sym2; buys[1]=E4_Buy2; trends[1]=E4_Trend2; exls[1]=E4_ExitL2; atrs[1]=E4_ATR2;
   uses[2]=E4_Use3; syms[2]=E4_Sym3; buys[2]=E4_Buy3; trends[2]=E4_Trend3; exls[2]=E4_ExitL3; atrs[2]=E4_ATR3;
   uses[3]=E4_Use4; syms[3]=E4_Sym4; buys[3]=E4_Buy4; trends[3]=E4_Trend4; exls[3]=E4_ExitL4; atrs[3]=E4_ATR4;

   g_e4_nActive = 0;
   for(int i = 0; i < E4_MAX_SYMS; i++)
     {
      g_e4_cfg[i].use = false;
      if(!uses[i]) continue;
      string base = syms[i];
      StringTrimLeft(base); StringTrimRight(base);
      if(base == "") continue;
      string full = base + E4_SymbolSuffix;

      if(!SymbolSelect(full, true))
        {
         PrintFormat("E4 par %d: símbolo '%s' não encontrado no Market Watch - ignorado.", i+1, full);
         continue;
        }

      g_e4_cfg[i].use      = true;
      g_e4_cfg[i].symbol   = full;
      g_e4_cfg[i].buy      = buys[i];
      g_e4_cfg[i].trendMA  = trends[i];
      g_e4_cfg[i].exitLong = exls[i];
      g_e4_cfg[i].atrMult  = atrs[i];
      g_e4_cfg[i].lastBar  = 0;

      g_e4_cfg[i].hRSI     = iRSI(full, E4_Timeframe, E4_Period, PRICE_CLOSE);
      g_e4_cfg[i].hTrendMA = iMA(full, E4_Timeframe, g_e4_cfg[i].trendMA, 0, MODE_SMA, PRICE_CLOSE);
      g_e4_cfg[i].hExitMA  = iMA(full, E4_Timeframe, E4_ExitMA, 0, MODE_SMA, PRICE_CLOSE);
      g_e4_cfg[i].hATR     = iATR(full, E4_Timeframe, E4_ATRPeriod);

      if(g_e4_cfg[i].hRSI == INVALID_HANDLE || g_e4_cfg[i].hTrendMA == INVALID_HANDLE ||
         g_e4_cfg[i].hExitMA == INVALID_HANDLE || g_e4_cfg[i].hATR == INVALID_HANDLE)
        {
         PrintFormat("E4 par %d (%s): erro ao criar indicadores - ignorado.", i+1, full);
         g_e4_cfg[i].use = false;
         continue;
        }
      g_e4_nActive++;
      PrintFormat("E4 par %d ativo: %s | Buy=%.1f TrendMA=%d ExitL=%.1f ATR=%.1f",
                  i+1, full, g_e4_cfg[i].buy, g_e4_cfg[i].trendMA, g_e4_cfg[i].exitLong, g_e4_cfg[i].atrMult);
     }

   // Sem par válido não derruba o Concorde: a Estratégia 4 fica dormente.
   g_e4_enabled = (g_e4_nActive > 0);
   if(!g_e4_enabled)
      Print("E4: nenhum par ativo/válido (verifique nomes e sufixo). Estratégia 4 dormente.");
   else
      PrintFormat("E4 iniciada com %d par(es).", g_e4_nActive);
   return(INIT_SUCCEEDED);
  }

void E4_Deinit(const int reason)
  {
   for(int i = 0; i < E4_MAX_SYMS; i++)
     {
      if(!g_e4_cfg[i].use) continue;
      if(g_e4_cfg[i].hRSI != INVALID_HANDLE)     IndicatorRelease(g_e4_cfg[i].hRSI);
      if(g_e4_cfg[i].hTrendMA != INVALID_HANDLE) IndicatorRelease(g_e4_cfg[i].hTrendMA);
      if(g_e4_cfg[i].hExitMA != INVALID_HANDLE)  IndicatorRelease(g_e4_cfg[i].hExitMA);
      if(g_e4_cfg[i].hATR != INVALID_HANDLE)     IndicatorRelease(g_e4_cfg[i].hATR);
     }
  }

void E4_OnTickWork()
  {
   if(!g_e4_enabled) { g_e4_comment = "E4: dormente (sem pares válidos)"; return; }

   if(E4_FridayClose && E4_IsFridayCloseTime())
     {
      E4_CloseAllMagic();
      g_e4_comment = "E4: fechamento de sexta ativo";
      return;
     }

   for(int i = 0; i < E4_MAX_SYMS; i++)
      if(g_e4_cfg[i].use)
        {
         E4_ManageEveryTick(i);
         E4_ProcessSymbol(i);
        }

   g_e4_comment = StringFormat("E4: %d par(es) | ddLock=%s | ativa=%s",
                                g_e4_nActive,
                                (g_e4_ddLocked ? "SIM" : "não"),
                                (Estrategia4_Ativada ? "sim" : "não"));
  }

//==================================================================
//        FILTRO DE NOTÍCIAS (Concorde) - CSV backtestável + Calendário
//==================================================================

bool News_UseCalendar()
  {
   if(News_Source == NEWSSRC_CALENDAR) return true;
   if(News_Source == NEWSSRC_CSV)      return false;
   return !((bool)MQLInfoInteger(MQL_TESTER)); // AUTO
  }

// v9: fuso do servidor unificado no módulo global (auto ao vivo, DST no tester).
void News_ResolveServerOffset()
  {
   g_news_srvOffset = Concorde_SrvGmtOffset();
  }

// Converte horário do CSV/web (em News_SourceGMTOffset) para hora do servidor.
datetime News_ApplyTZ(datetime srcTime)
  {
   return srcTime + (datetime)((g_news_srvOffset - News_SourceGMTOffset) * 3600);
  }

int News_ParseImpact(string s)
  {
   StringToUpper(s); StringTrimLeft(s); StringTrimRight(s);
   if(s=="HIGH"   || s=="3" || s=="ALTO"  || s=="RED")    return 3;
   if(s=="MEDIUM" || s=="MED" || s=="2" || s=="MEDIO" || s=="MÉDIO" || s=="ORANGE") return 2;
   if(s=="LOW"    || s=="1" || s=="BAIXO" || s=="YELLOW") return 1;
   return 0;
  }

void News_ReplaceSeps(string &s) { StringReplace(s,"-","."); StringReplace(s,"/","."); }

bool News_ParseAmPm(string ts,int &hh,int &mm)
  {
   StringToLower(ts); StringTrimLeft(ts); StringTrimRight(ts);
   if(StringLen(ts)==0) return false;
   if(StringFind(ts,"all")>=0 || StringFind(ts,"tent")>=0 || StringFind(ts,"day")>=0) return false;
   bool pm=false, am=false;
   if(StringFind(ts,"pm")>=0){ pm=true; StringReplace(ts,"pm",""); }
   else if(StringFind(ts,"am")>=0){ am=true; StringReplace(ts,"am",""); }
   StringTrimLeft(ts); StringTrimRight(ts);
   string p[]; int n=StringSplit(ts,(ushort)':',p);
   if(n<1) return false;
   hh=(int)StringToInteger(p[0]); mm=(n>=2)?(int)StringToInteger(p[1]):0;
   if(pm && hh<12) hh+=12;
   if(am && hh==12) hh=0;
   if(hh<0||hh>23||mm<0||mm>59) return false;
   return true;
  }

int News_SplitTrim(string line,ushort sep,string &out[])
  {
   StringReplace(line,"\r","");
   int n=StringSplit(line,sep,out);
   if(n<=0){ ArrayResize(out,1); out[0]=line; n=1; }
   for(int i=0;i<n;i++){ StringTrimLeft(out[i]); StringTrimRight(out[i]); }
   return n;
  }

bool News_ParseSimple(string &c[],int n,NewsEvent &ev)
  {
   if(n<4) return false;
   string ds=c[0]; News_ReplaceSeps(ds);
   string dp[]; int dn=StringSplit(ds,(ushort)'.',dp);
   if(dn<3) return false;
   int y=(int)StringToInteger(dp[0]), mo=(int)StringToInteger(dp[1]), d=(int)StringToInteger(dp[2]);
   if(y<2000||mo<1||mo>12||d<1||d>31) return false;
   int hh=0,mm=0; string tp[]; int tn=StringSplit(c[1],(ushort)':',tp);
   if(tn>=1) hh=(int)StringToInteger(tp[0]);
   if(tn>=2) mm=(int)StringToInteger(tp[1]);
   if(hh<0||hh>23||mm<0||mm>59) return false;
   MqlDateTime st; st.year=y;st.mon=mo;st.day=d;st.hour=hh;st.min=mm;st.sec=0;
   ev.time=News_ApplyTZ(StructToTime(st));
   string ccy=c[2]; StringToUpper(ccy); ev.ccy=ccy;
   ev.impact=News_ParseImpact(c[3]);
   string title=(n>=5)?c[4]:""; for(int i=5;i<n;i++) title+=" "+c[i]; ev.title=title;
   return true;
  }

bool News_ParseFF(string &c[],int n,NewsEvent &ev)
  {
   if(n<5) return false;
   string ds=c[2]; News_ReplaceSeps(ds);
   string dp[]; int dn=StringSplit(ds,(ushort)'.',dp);
   if(dn<3) return false;
   int mo=(int)StringToInteger(dp[0]), d=(int)StringToInteger(dp[1]), y=(int)StringToInteger(dp[2]);
   if(y<100) y+=2000;
   if(y<2000||mo<1||mo>12||d<1||d>31) return false;
   int hh,mm; if(!News_ParseAmPm(c[3],hh,mm)) return false;
   MqlDateTime st; st.year=y;st.mon=mo;st.day=d;st.hour=hh;st.min=mm;st.sec=0;
   ev.time=News_ApplyTZ(StructToTime(st));
   string ccy=c[1]; StringToUpper(ccy); ev.ccy=ccy;
   ev.impact=News_ParseImpact(c[4]); ev.title=c[0];
   return true;
  }

void News_LoadFromCSV()
  {
   ArrayResize(g_news,0); g_news_count=0; g_news_loaded=true;
   int flags=FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ;
   if(News_CsvCommonFolder) flags|=FILE_COMMON;
   ResetLastError();
   int h=FileOpen(News_CsvFileName,flags);
   if(h==INVALID_HANDLE)
     { Print("NOTÍCIAS: não abriu '",News_CsvFileName,"' (err ",GetLastError(),") em ",
             (News_CsvCommonFolder?"Common\\Files":"MQL5\\Files")); return; }
   ushort sep=(StringLen(News_CsvDelimiter)>0)?StringGetCharacter(News_CsvDelimiter,0):(ushort)',';
   int added=0,skipped=0; string cols[];
   while(!FileIsEnding(h))
     {
      string line=FileReadString(h);
      if(StringLen(line)==0) continue;
      int nc=News_SplitTrim(line,sep,cols);
      NewsEvent ev;
      bool ok=(News_CsvFormat==NEWSFMT_FOREXFACTORY)?News_ParseFF(cols,nc,ev):News_ParseSimple(cols,nc,ev);
      if(ok){ ArrayResize(g_news,g_news_count+1); g_news[g_news_count++]=ev; added++; } else skipped++;
     }
   FileClose(h);
   if(News_VerboseLog) Print("NOTÍCIAS: ",added," eventos do CSV (",skipped," ignorados).");
   if(added==0) Print("NOTÍCIAS: ATENÇÃO 0 eventos lidos - verifique formato/encoding/delimitador do CSV.");
  }

void News_LoadFromCalendar()
  {
   ArrayResize(g_news,0); g_news_count=0; g_news_loaded=true;
   datetime from=TimeCurrent()-86400, to=TimeCurrent()+2*86400;
   MqlCalendarValue values[];
   int total=CalendarValueHistory(values,from,to,NULL,NULL);
   if(total<=0){ if(News_VerboseLog) Print("NOTÍCIAS(cal): sem dados (err ",GetLastError(),")."); return; }
   int added=0;
   for(int i=0;i<total;i++)
     {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id,event)) continue;
      string ccy=""; MqlCalendarCountry country;
      if(CalendarCountryById(event.country_id,country)) ccy=country.currency;
      StringToUpper(ccy);
      int imp=0;
      if(event.importance==CALENDAR_IMPORTANCE_HIGH)          imp=3;
      else if(event.importance==CALENDAR_IMPORTANCE_MODERATE) imp=2;
      else if(event.importance==CALENDAR_IMPORTANCE_LOW)      imp=1;
      NewsEvent ev; ev.time=values[i].time; ev.ccy=ccy; ev.impact=imp; ev.title=event.name;
      ArrayResize(g_news,g_news_count+1); g_news[g_news_count++]=ev; added++;
     }
   if(News_VerboseLog) Print("NOTÍCIAS(cal): ",added," eventos.");
  }

void News_Refresh(bool force)
  {
   if(!News_Enable) return;
   News_ResolveServerOffset();         // fuso do servidor (auto na conta real)
   if(News_UseCalendar())              // fonte ao vivo (conta real, ou CALENDAR forçado)
     {
      if(!force && (TimeCurrent()-g_news_lastRefresh)<(long)News_RefreshMin*60) return;
      News_LoadFromCalendar();         // calendário nativo do MT5 (conta real / CALENDAR forçado)
      g_news_lastRefresh=TimeCurrent(); return;
     }
   bool tester=(bool)MQLInfoInteger(MQL_TESTER);
   datetime today=(datetime)(((long)TimeCurrent()/86400)*86400);
   if(g_news_loaded && !force){ if(tester) return; if(today==g_news_lastCsvDay) return; }
   News_LoadFromCSV(); g_news_lastCsvDay=today;
  }

bool News_CcyRelevantForSymbol(string sym,string ccy)
  {
   if(StringLen(News_CurrenciesManual)>0)
     {
      string list=News_CurrenciesManual; StringToUpper(list); StringReplace(list," ","");
      return (StringFind(","+list+",",","+ccy+",")>=0);
     }
   if(!News_OnlySymbolCcy) return true;
   string b=SymbolInfoString(sym,SYMBOL_CURRENCY_BASE);   StringToUpper(b);
   string q=SymbolInfoString(sym,SYMBOL_CURRENCY_PROFIT); StringToUpper(q);
   if(ccy==b || ccy==q) return true;
   string symU=sym; StringToUpper(symU);          // fallback robusto (ex.: XAUUSD contém USD)
   if(StringLen(ccy)>0 && StringFind(symU,ccy)>=0) return true;
   return false;
  }

bool News_ComputeBlackout(string sym)
  {
   datetime now=TimeCurrent();
   long before=(long)News_MinutesBefore*60, after=(long)News_MinutesAfter*60;
   for(int i=0;i<g_news_count;i++)
     {
      if(g_news[i].impact<News_MinImpact) continue;
      if(!News_CcyRelevantForSymbol(sym,g_news[i].ccy)) continue;
      datetime t=g_news[i].time;
      if(now>=(t-before) && now<=(t+after)) return true;
     }
   return false;
  }

bool News_IsBlackoutForSymbol(string sym)
  {
   if(!News_Enable || g_news_count<=0) return false;
   datetime minute=(datetime)(((long)TimeCurrent()/60)*60);
   if(minute!=g_news_cacheMinute){ g_news_cacheMinute=minute; g_news_cacheN=0; }
   for(int i=0;i<g_news_cacheN;i++)
      if(g_news_cacheSym[i]==sym) return g_news_cacheVal[i];
   bool v=News_ComputeBlackout(sym);
   if(g_news_cacheN<16){ g_news_cacheSym[g_news_cacheN]=sym; g_news_cacheVal[g_news_cacheN]=v; g_news_cacheN++; }
   return v;
  }

// Atalho usado nos pontos de entrada de cada estratégia.
bool News_StratBlock(string sym) { return (News_Enable && News_IsBlackoutForSymbol(sym)); }

bool News_IsOurMagic(long m)
  {
   if(m==(long)E1_MagicNumber) return true;
   if(m==(long)E2_MagicNumber)  return true;
   if(m==(long)E3_MagicNumber || m==(long)E3_MagicNumber+1) return true;
   if(m==(long)E4_MagicNumber) return true;
   return false;
  }

void News_CloseBlackoutPositions()
  {
   if(!News_Enable || !News_CloseTrades) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      long m=PositionGetInteger(POSITION_MAGIC);
      if(!News_IsOurMagic(m)) continue;
      string psym=PositionGetString(POSITION_SYMBOL);
      if(!News_IsBlackoutForSymbol(psym)) continue;
      g_news_trade.SetExpertMagicNumber(m);   // [fix painel] deal de saída herda o magic da estratégia
      g_news_trade.PositionClose(t);
     }
  }

void News_RefreshAndManage()
  {
   if(!News_Enable) return;
   News_Refresh(false);
   News_CloseBlackoutPositions();
  }

void News_Init()
  {
   g_news_loaded=false; g_news_count=0; g_news_lastRefresh=0; g_news_lastCsvDay=0;
   g_news_cacheN=0; g_news_cacheMinute=0;
   g_news_srvOffset=Concorde_SrvGmtOffset();
   ArrayResize(g_news,0);
   if(!News_Enable){ Print("FILTRO NOTÍCIAS Concorde: DESATIVADO"); return; }
   News_Refresh(true);
   string fonte = News_UseCalendar() ? "CALENDÁRIO nativo" : "CSV";
   string fusoInfo = ((bool)MQLInfoInteger(MQL_TESTER))
                     ? ("tester DST=GMT+"+IntegerToString(g_news_srvOffset))
                     : ("AUTO=GMT+"+IntegerToString(g_news_srvOffset));
   Print("FILTRO NOTÍCIAS Concorde: fonte=",fonte," | fuso servidor ",fusoInfo,
         " | -",News_MinutesBefore,"/+",News_MinutesAfter,"min | impacto>=",News_MinImpact,
         " | eventos=",g_news_count," | fechar=",(News_CloseTrades?"sim":"não"));
  }

//==================================================================
//                 ORQUESTRAÇÃO PRINCIPAL DO EA
//==================================================================

int OnInit()
  {
   const int rL = E1_Init();
   if(rL != INIT_SUCCEEDED) return rL;

   const int rA = E2_Init();
   if(rA != INIT_SUCCEEDED) return rA;

   const int rB = E3_Init();
   if(rB != INIT_SUCCEEDED) return rB;

   const int rR = E4_Init();
   if(rR != INIT_SUCCEEDED) return rR;

   News_Init();

   Panel_Create();

   EventSetTimer(1);
   PrintFormat("Concorde EA inicializado: E1+E2(%s)+E3+E4 | fuso GMT+%d (auto/DST) | stopGlobal=%s %.1f%% | capPernas=%d | E3 ATR=%d",
               (Estrategia2_Ativada ? "ON" : "off"), Concorde_SrvGmtOffset(),
               (Concorde_UseStopDiarioGlobal ? "sim" : "não"), Concorde_StopDiarioGlobalPct,
               Concorde_MaxPernasMesmaDir, E3_PeriodoAtr);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   E1_Deinit(reason);
   E2_Deinit(reason);
   E3_Deinit(reason);
   E4_Deinit(reason);
   Panel_DeleteAll();
   Comment("");
  }

void OnTick()
  {
   Concorde_GlobalStopCheck();  // v9: stop diário global por equity (fecha tudo e trava o dia)
   News_RefreshAndManage();   // filtro de notícias: atualiza e fecha posições na janela
   E3_OnTick();
   E2_OnTickWork();
   E4_OnTickWork();
   Panel_Update();
   // Comment() conflitaria visualmente com o painel — só mostra quando o painel está oculto.
   if(E2_MostrarStatusGrafico && !Panel_Mostrar)
      Comment("Concorde EA\n", g_e1_comment, "\n", g_e2_comment, "\n", g_e3_comment, "\n", g_e4_comment);
  }

void OnTimer()
  {
   E1_ProcessSession();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest      &request,
                        const MqlTradeResult       &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   int    mg  = (int)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);

   // v9: TP1 do E3 detectado por evento (antes: HistorySelect da conta inteira a cada tick).
   if(sym == g_e3_sym && mg == E3_MagicNumber
      && HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      g_e3_tp1Hit = true;

   if(sym != g_e1_symbol || mg != E1_MagicNumber) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
     {
      ENUM_DEAL_TYPE dt = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
      if(dt == DEAL_TYPE_BUY)       E1_CancelPendings(ORDER_TYPE_SELL_STOP);
      else if(dt == DEAL_TYPE_SELL) E1_CancelPendings(ORDER_TYPE_BUY_STOP);
     }
   else if(entry == DEAL_ENTRY_OUT)
     {
      long   reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      string dc     = HistoryDealGetString(trans.deal, DEAL_COMMENT);
      if(reason == DEAL_REASON_TP && StringFind(dc, E1_COMMENT_TP3) >= 0)
        { g_e1_trail_armed = true; g_e1_be_done = false; }
     }
  }

//+------------------------------------------------------------------+
