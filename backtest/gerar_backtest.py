"""Monta a pasta backtest/: EAs Airbus e Concorde_RF, presets .set e inis do tester."""
import pathlib, re

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "Concorde_RF.mq5"
OUT = ROOT / "backtest"
EXP = OUT / "MQL5" / "Experts"
SETS = OUT / "MQL5" / "Profiles" / "Tester"
INIS = OUT / "tester_ini"
for d in (EXP, SETS, INIS):
    d.mkdir(parents=True, exist_ok=True)

src = SRC.read_text(encoding="utf-8-sig")

# ---------- enums ----------
ENUMS = {
    "PERIOD_M1": 1, "PERIOD_M5": 5, "PERIOD_M15": 15, "PERIOD_M30": 30,
    "PERIOD_H1": 16385, "PERIOD_H4": 16388, "PERIOD_D1": 16408,
    "CORNER_LEFT_UPPER": 0, "CORNER_LEFT_LOWER": 1, "CORNER_RIGHT_LOWER": 2, "CORNER_RIGHT_UPPER": 3,
}
for name, val in re.findall(r"^\s*([A-Z0-9_]+)\s*=\s*(\d+)\s*,?\s*(?://.*)?$", src, re.M):
    ENUMS.setdefault(name, int(val))

# ---------- inputs (ordem do fonte) ----------
INPUT_RE = re.compile(r"\binput\s+(?!group\b)(\w+)\s+(\w+)\s*=\s*([^;]+);")
inputs = []
for line in src.splitlines():
    for typ, name, val in INPUT_RE.findall(line):
        inputs.append((typ, name, val.strip()))


def norm(typ, val):
    if typ == "string":
        return val.strip().strip('"')
    if typ == "bool":
        return val.lower()
    if typ.startswith("ENUM_"):
        return str(ENUMS[val]) if val in ENUMS else val
    return val


DEFAULTS = {n: (t, norm(t, v)) for t, n, v in inputs}
assert len(DEFAULTS) == len(inputs), "input duplicado"

# ---------- perfis ----------
COMUM = {"Panel_Mostrar": "false", "News_Enable": "true"}
AIRBUS = {"Estrategia1_Ativada": "true", "Estrategia2_Ativada": "false",
          "Estrategia3_Ativada": "true", "Estrategia4_Ativada": "false"}
PERFIS = {
    "Airbus_Conservador": ("Airbus", {**COMUM, **AIRBUS, "E1_RiscoPorPernaPct": "0.4", "E3_RiscoPorPernaPct": "0.6",
                                      "Concorde_StopDiarioGlobalPct": "8.0", "E3_StopDiarioPercent": "6.0"},
                           "C13: E1 0,4% / E3 0,6% por perna, stops diarios 8% / 6%"),
    "Airbus_Moderado": ("Airbus", {**COMUM, **AIRBUS, "E1_RiscoPorPernaPct": "0.4", "E3_RiscoPorPernaPct": "1.2",
                                   "Concorde_StopDiarioGlobalPct": "8.0", "E3_StopDiarioPercent": "6.0"},
                        "C22 / degrau A: E1 0,4% / E3 1,2% por perna, stops diarios 8% / 6%"),
    "Airbus_Agressivo": ("Airbus", {**COMUM, **AIRBUS, "E1_RiscoPorPernaPct": "0.4", "E3_RiscoPorPernaPct": "1.8",
                                    "Concorde_StopDiarioGlobalPct": "12.0", "E3_StopDiarioPercent": "9.0"},
                         "C23 / degrau B: E1 0,4% / E3 1,8% por perna, stops diarios 12% / 9%"),
    "Concorde_Normal": ("Concorde_RF", {**COMUM},
                        "C1: 4 estrategias, E1 0,8% / E2 0,8% / E3 1,2% / E4 2,0%, stops diarios 8% / 6%"),
}


def set_line(name, typ, val):
    if typ == "string":
        return f"{name}={val}"
    if typ == "bool":
        return f"{name}={val}||false||0||true||N"
    if typ.startswith("ENUM_") or typ in ("int", "long", "ulong", "uint"):
        v = int(val)
        return f"{name}={v}||{v}||1||{v*10 if v else 10}||N"
    v = float(val)
    step = v / 10 if v else 0.1
    stop = v * 10 if v else 1
    return f"{name}={val}||{val}||{step:g}||{stop:g}||N"


for perfil, (ea, over, desc) in PERFIS.items():
    unknown = set(over) - set(DEFAULTS)
    assert not unknown, unknown
    lines = [f"; {perfil} - {desc}", f"; EA: {ea}.mq5 | XAUUSD M15 | deposito 10000 USD | alavancagem 1:1000"]
    for _, name, _ in inputs:
        typ, val = DEFAULTS[name]
        lines.append(set_line(name, typ, over.get(name, val)))
    (SETS / f"{perfil}.set").write_bytes(("\r\n".join(lines) + "\r\n").encode("utf-16"))

    for tag, (de, ate) in {"1ano": ("2025.09.20", "2026.09.19"), "2anos": ("2024.09.20", "2026.09.19")}.items():
        ini = f"""; Backtest {perfil} ({tag}) - rodar: terminal64.exe /config:"<caminho>\\{perfil}_{tag}.ini"
[Tester]
Expert={ea}.ex5
ExpertParameters={perfil}.set
Symbol=XAUUSD
Period=M15
Model=4
ExecutionMode=0
Optimization=0
FromDate={de}
ToDate={ate}
ForwardMode=0
Deposit=10000
Currency=USD
Leverage=1000
Visual=0
ReplaceReport=1
Report=reports\\{perfil}_{tag}
ShutdownTerminal=1
"""
        (INIS / f"{perfil}_{tag}.ini").write_text(ini.replace("\n", "\r\n"), encoding="utf-8")

# ---------- EAs ----------
(EXP / "Concorde_RF.mq5").write_bytes(SRC.read_bytes())

air = src
for name, val in {**AIRBUS, "E1_RiscoPorPernaPct": "0.4", "E3_RiscoPorPernaPct": "1.2"}.items():
    pat = re.compile(rf"(\binput\s+\w+\s+{name}\s*=\s*)([^;]+)(;)")
    air, n = pat.subn(lambda m: m.group(1) + val + m.group(3), air)
    assert n == 1, name
REPL = [
    ("//|                                                     Concorde.mq5 |",
     "//|                                                       Airbus.mq5 |"),
    ("//|        EA multi-estratégia: 4 estratégias independentes (E1-E4), |",
     "//|  Airbus = Concorde_RF com só E1 (madrugada) e E3 (europeia)     |\n"
     "//|  ligadas por padrão (E2 e E4 desligadas), riscos do degrau A.    |\n"
     "//|        EA multi-estratégia: 4 estratégias independentes (E1-E4), |"),
    ('#property copyright "Concorde EA"', '#property copyright "Airbus EA (base Concorde EA)"'),
    ('#property description "Concorde EA - 4 estratégias independentes num único EA."',
     '#property description "Airbus EA - Concorde_RF com E1 + E3 (E2 e E4 desligadas por padrão)."'),
    ('"✈  CONCORDE EA"', '"✈  AIRBUS EA"'),
    ('PrintFormat("Concorde EA inicializado:', 'PrintFormat("Airbus EA inicializado:'),
    ('Comment("Concorde EA\\n"', 'Comment("Airbus EA\\n"'),
]
for a, b in REPL:
    assert air.count(a) == 1, a
    air = air.replace(a, b)
(EXP / "Airbus.mq5").write_bytes(b"\xef\xbb\xbf" + air.encode("utf-8"))

print(len(inputs), "inputs;", sorted(p.name for p in OUT.rglob("*") if p.is_file()))
