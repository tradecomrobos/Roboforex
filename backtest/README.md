# Backtest: Airbus e Concorde

Pasta pronta para rodar no Strategy Tester do MetaTrader 5 (RoboForex) os dois EAs e os 4 perfis da apresentação.

## O que tem aqui

```
backtest/
├── MQL5/
│   ├── Experts/
│   │   ├── Airbus.mq5          ← Concorde_RF com só E1 + E3 ligadas (padrão = Airbus Moderado)
│   │   └── Concorde_RF.mq5     ← EA original, 4 estratégias (cópia idêntica do arquivo da raiz)
│   └── Profiles/Tester/
│       ├── Airbus_Conservador.set
│       ├── Airbus_Moderado.set
│       ├── Airbus_Agressivo.set
│       └── Concorde_Normal.set
├── tester_ini/                 ← opcional: rodar pela linha de comando (1 ano e 2 anos)
└── gerar_backtest.py           ← regera EAs, presets e inis a partir do Concorde_RF.mq5 da raiz
```

| Preset | EA | Estratégias | Risco por perna | Stop diário global / E3 | Referência no RESULTADOS.md |
|---|---|---|---|---|---|
| Airbus_Conservador | Airbus | E1 + E3 | E1 0,4% / E3 0,6% | 8% / 6% | C13 |
| Airbus_Moderado | Airbus | E1 + E3 | E1 0,4% / E3 1,2% | 8% / 6% | C22 (degrau A) |
| Airbus_Agressivo | Airbus | E1 + E3 | E1 0,4% / E3 1,8% | 12% / 9% | C23 (degrau B) |
| Concorde_Normal | Concorde_RF | E1 + E2 + E3 + E4 | 0,8% / 0,8% / 1,2% / 2,0% | 8% / 6% | C1 (1 ano) e C4 (2 anos) |

Os 4 presets têm os 180 inputs completos. Os demais valores são os padrões do código, com `Panel_Mostrar=false` e `News_Enable=true`, como nos testes da campanha.

## Passo a passo

1. **Copiar os arquivos.** No MT5: *Arquivo > Abrir pasta de dados*.
   - `MQL5/Experts/*.mq5` → `MQL5\Experts\`
   - `MQL5/Profiles/Tester/*.set` → `MQL5\Profiles\Tester\`
2. **Compilar.** Abra os dois `.mq5` no MetaEditor e aperte F7. O resultado deve ser 0 erros.
3. **Notícias (importante).** No tester, o filtro de notícias lê `news.csv` (formato ForexFactory) da pasta **Common\Files** (*Abrir pasta de dados* > subir 2 níveis > `Common\Files`). Copie para lá o `news.csv` do kit no VPS. Sem esse arquivo, o EA roda sem filtro de notícias e o resultado sai diferente do da campanha. O log mostra `NOTÍCIAS: não abriu 'news.csv'`.
4. **Configurar o Strategy Tester** (Ctrl+R):

| Campo | Valor |
|---|---|
| Expert | `Airbus` ou `Concorde_RF` |
| Símbolo / período | XAUUSD, M15 |
| Datas | 1 ano: 2025.09.20 a 2026.09.19 · 2 anos: 2024.09.20 a 2026.09.19 |
| Modelagem | Cada tick baseado em ticks reais |
| Depósito | 10000 USD |
| Alavancagem | 1:1000 |
| Atraso | Sem atraso (como na campanha) |

5. **Carregar o preset.** Na aba *Parâmetros*: botão direito > *Carregar* > escolha o `.set` do perfil.
6. Clique em **Iniciar**.

### Linha de comando (opcional)

Os `.ini` de `tester_ini/` já trazem tudo do passo 4. O `.set` precisa estar em `MQL5\Profiles\Tester\`. Com o MT5 fechado:

```
terminal64.exe /config:"C:\caminho\backtest\tester_ini\Airbus_Moderado_1ano.ini"
```

O relatório sai em `reports\<perfil>_<1ano|2anos>.htm`, dentro da pasta de dados do MT5, e o terminal fecha no fim.

## Resultados esperados (campanha da RoboForex, depósito 10.000)

| Perfil | 1 ano (set/25 a set/26) | 2 anos | Maior queda (2 anos) |
|---|---|---|---|
| Airbus Conservador | ~+66% (2º ano do teste de 2 anos) | +129,7% | 14,5% |
| Airbus Moderado | ~+170% (2º ano do teste de 2 anos) | +348,5% | 20,5% |
| Airbus Agressivo | ~+286% (2º ano do teste de 2 anos) | +723,9% | 27,7% |
| Concorde Normal | +411,7% (teste de 1 ano, C1) | +64,0% (C4, 1º ano −64%) | 66,5% |

Diferenças pequenas são normais: dependem do histórico de ticks baixado e do `news.csv`. Diferença grande quase sempre vem de três coisas: o `news.csv` faltando, a modelagem diferente de "ticks reais", ou o preset errado.

## Observações

- **Airbus.mq5** é o `Concorde_RF.mq5` (v3.03) com só estas mudanças: nome no cabeçalho e no painel, `Estrategia2_Ativada=false`, `Estrategia4_Ativada=false` e `E1_RiscoPorPernaPct=0.4`. A lógica de operação é a mesma. Os magics também são os mesmos: E1 202512 e E3 202533/202534.
- No VPS, o kit roda a v3.04 (v3.03 + SurvivalGuard). A campanha confirmou que o backtest é idêntico ao da v3.03. O guardião (SurvivalGuardian) é um EA separado, não está nesta pasta e não age no tester.
- **Concorde_Normal** com E4 opera também EURUSD, USDCAD, USDJPY e AUDUSD. O tester baixa esses símbolos sozinho, e o primeiro teste demora mais.
- **Horário das notícias:** o `news.csv` em GMT é convertido com um único fuso, o do início do teste. Em testes que começam no horário de verão europeu, as notícias de inverno ficam 1 h atrasadas (RESULTADOS.md 5.6). Para reproduzir o C22 corrigido, use o `news_lab_srv.csv` do kit (já na hora do servidor) como `News_CsvFileName` e ponha em `News_SourceGMTOffset` o fuso do servidor no início do teste: 3 no horário de verão, 2 no inverno.
- Não compilei aqui (este ambiente não tem MetaEditor). As mudanças no Airbus são só valores padrão e textos, mas confira no passo 2 que a compilação sai sem erros.
