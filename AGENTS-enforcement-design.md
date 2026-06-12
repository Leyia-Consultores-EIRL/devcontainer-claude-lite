# AGENTS enforcement design — Codex/GPT side

Codex/GPT no tiene el mecanismo de hooks de Claude Code. Por lo tanto, el enforcement no puede depender de prompt-side discipline solamente. La regla de diseno es: todo gate deterministico debe correr fuera del agente, en CI, pre-push y wrapper-side post-worker checks. `AGENTS.md` define la norma; este archivo define donde se ejecutan los dientes mecanicos.

## Objetivo

Portar el entorno de guardrails de Claude a agentes Codex/GPT con la misma semantica:

- Detectar ghost code nuevo: simbolos publicos sin call-site alcanzable desde entry-point productivo.
- Detectar ghost tests: tests que leen source y asertan substrings, paths absolutos hardcodeados, bats que inspecciona scripts sin ejecutarlos.
- Mantener baseline versionado de ghosts heredados.
- Requerir evidencia de ejecucion real para claims de done.
- Evitar que el agente cierre un worker como exitoso si los gates deterministas fallan.

## Que se puede mover tal cual

Estos scripts son bash plano y no dependen de Claude:

```bash
.claude/hooks/integration-gate.sh
.claude/hooks/ghost-test-guard.sh
.claude/hooks/lang/*.sh
.claude/hooks/project.conf
.claude/ghost-baseline.txt
```

Tambien pueden ejecutarse desde la fuente template si el target aun no instalo `.claude/`:

```bash
guardrails/.claude/hooks/integration-gate.sh
guardrails/.claude/hooks/ghost-test-guard.sh
```

`integration-gate.sh` mantiene el contrato importante:

- exit 0: no hay ghosts nuevos, o solo ghosts heredados en baseline.
- exit 1: setup/config incompleto. En CI debe fallar como config error; en worker local debe reportarse `CANNOT RUN`.
- exit 2: ghosts nuevos. Debe bloquear merge/push/worker success.

`ghost-test-guard.sh` mantiene:

- exit 0: sin patrones de ghost tests en tests nuevos/modificados.
- exit 2: bloquear por test estructural falso.

## Que no se mueve tal cual

`new-symbol-guard.sh` esta atado a Claude `PostToolUse`: lee JSON por stdin con el `file_path` editado. Codex no emite ese protocolo. No se porta como hook directo.

Reemplazos aceptables:

1. Correr `integration-gate.sh` despues de cada worker, como hard gate.
2. Opcional: wrapper Codex puede implementar su propio post-edit watcher y pasarle el archivo editado a un script nuevo, pero no es requisito para paridad dura.
3. CI/pre-push son ground truth. El warning inmediato es ergonomia; el bloqueo final es enforcement.

`ghost-report.sh` es `SessionStart` informativo. En Codex puede correrse al inicio de worker para imprimir inventario, pero no es gate. Su funcion queda cubierta mecanicamente por `integration-gate.sh` al final.

## Punto natural de montaje: host-side-audit.sh

El fleet debe tratar `host-side-audit.sh` como el punto de montaje canonico. Ese script corre en el host, despues de que un worker termina y antes de marcarlo successful, subir PR o pasar el siguiente stage.

Responsabilidades de `host-side-audit.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

unset ANTHROPIC_API_KEY OPENAI_API_KEY

ROOT="${1:-$(pwd)}"
cd "$ROOT"

if [ -x ".claude/hooks/integration-gate.sh" ]; then
  bash .claude/hooks/integration-gate.sh
elif [ -x "guardrails/.claude/hooks/integration-gate.sh" ]; then
  bash guardrails/.claude/hooks/integration-gate.sh
else
  echo "host-side-audit: integration gate missing" >&2
  exit 1
fi

if [ -x ".claude/hooks/ghost-test-guard.sh" ]; then
  bash .claude/hooks/ghost-test-guard.sh
elif [ -x "guardrails/.claude/hooks/ghost-test-guard.sh" ]; then
  bash guardrails/.claude/hooks/ghost-test-guard.sh
else
  echo "host-side-audit: ghost-test guard missing" >&2
  exit 1
fi
```

El wrapper debe interpretar exit code distinto de 0 como worker failed. En particular, exit 2 no es "warning": es bloqueante.

## CI design

Agregar un job obligatorio, antes de merge:

```yaml
name: guardrails

on:
  pull_request:
  push:
    branches: [main]

jobs:
  fakework-gates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Guardrail config present
        run: |
          test -f .claude/hooks/project.conf
          test -f .claude/ghost-baseline.txt

      - name: Integration gate
        run: bash .claude/hooks/integration-gate.sh

      - name: Ghost test guard
        run: bash .claude/hooks/ghost-test-guard.sh
```

Para repos donde los guardrails viven bajo `guardrails/.claude/` y aun no estan instalados en `.claude/`, el job debe primero instalar o copiar la config target. El objetivo final recomendado es versionar en el target:

```text
.claude/hooks/project.conf
.claude/hooks/*.sh
.claude/hooks/lang/*.sh
.claude/ghost-baseline.txt
AGENTS.md
```

CI debe fallar si `project.conf` falta. Un gate sin config no protege nada.

## Pre-push hook

Instalar `.git/hooks/pre-push` local o gestionarlo via tooling del repo:

```bash
#!/usr/bin/env bash
set -euo pipefail

unset ANTHROPIC_API_KEY OPENAI_API_KEY

bash .claude/hooks/integration-gate.sh
bash .claude/hooks/ghost-test-guard.sh
```

Este hook es defensa local, no reemplaza CI. Un humano puede saltarlo; CI no.

## Wrapper post-worker contract

Cada worker Codex/GPT del fleet debe terminar con este contrato:

1. El wrapper ejecuta `unset ANTHROPIC_API_KEY OPENAI_API_KEY` antes de iniciar el worker.
2. El worker puede modificar codigo.
3. Al terminar, el wrapper ejecuta `host-side-audit.sh <repo>`.
4. Si el audit falla, el worker se marca failed y su salida final debe incluir stderr del gate.
5. Si el audit pasa, el wrapper permite commit/PR o siguiente etapa.

El worker no decide si ignora `integration-gate.sh`. El host decide.

## Baseline policy

`.claude/ghost-baseline.txt` representa deuda heredada aceptada al momento de instalar guardrails. No es una lista para silenciar ghosts nuevos.

Reglas:

- Debe estar versionado y revisado en PR.
- `integration-gate.sh` crea baseline en primer run si falta; ese cambio debe revisarse y commitearse como setup.
- Agregar un simbolo nuevo al baseline exige justificacion en PR: por que es intencional, quien lo reviso, cuando se elimina.
- Cuando ghosts heredados se arreglan, refrescar baseline en PR separado o en el mismo PR con nota clara.

## Evidence policy

Los gates mecanicos detectan dos clases, pero no pueden validar todo el DoD. El wrapper/CI debe exigir que el PR o worker report incluya evidencia textual para:

- comando productivo ejecutado;
- salida clave o log con identificador unico del modulo;
- veredicto `verify-done`;
- veredicto `verify-contract`, `verify-storage`, `verify-identity` o `verify-honest-failure` cuando aplique;
- razon concreta para cualquier `CANNOT RUN`.

Un PR con gates verdes pero sin evidencia de runtime no cumple `AGENTS.md`.

## Mapping Claude -> Codex/GPT

| Claude layer | Funcion original | Codex/GPT enforcement |
|---|---|---|
| `CLAUDE.md` DoD | Norma declarativa | `AGENTS.md` autocontenido |
| Skills `verify-*` | Checklists invocados por Claude | Checklists inline en `AGENTS.md`; worker debe ejecutarlos antes de done claims |
| `ghost-report.sh` SessionStart | Inventario informativo | Opcional al inicio de worker; no bloqueante |
| `new-symbol-guard.sh` PostToolUse | Warning inmediato por simbolo nuevo | No portable tal cual; reemplazado por post-worker `integration-gate.sh`, opcional watcher propio |
| `integration-gate.sh` Stop | Hard gate exit 2 por ghosts nuevos | CI, pre-push y `host-side-audit.sh` obligatorio |
| `ghost-test-guard.sh` Stop | Hard gate exit 2 por tests falsos | CI, pre-push y `host-side-audit.sh` obligatorio |

## Failure handling

Si `integration-gate.sh` falla:

1. Leer los simbolos reportados.
2. Para cada uno, wirear desde entry-point productivo o borrar el simbolo.
3. No pedir permiso para elegir wire-vs-delete si el scope es claro.
4. No agregar al baseline salvo excepcion intencional revisada.

Si `ghost-test-guard.sh` falla:

1. Reescribir el test para ejecutar comportamiento real.
2. Para Bats, usar `run bash <script>` y asertar `$status`/`$output`.
3. Reemplazar paths absolutos por fixtures relativas o `tmp_path`.
4. Reemplazar source-grep por senales runtime.

Si falta config:

1. Instalar guardrails o crear `.claude/hooks/project.conf`.
2. Definir `LANG`/`ENTRY_POINTS` o `LANGS`/`ENTRY_POINTS_<lang>`.
3. Inicializar baseline con el checker real.
4. Fallar el audit hasta que exista config.

## Decision final

El enforcement Codex-side no debe confiar en que el modelo recuerde correr checklists. La prosa en `AGENTS.md` es necesaria para orientar al agente, pero los dientes viven en el host:

- `host-side-audit.sh` para todo worker;
- pre-push para feedback local;
- CI como autoridad de merge;
- baseline versionado para separar deuda heredada de ghosts nuevos.

Ese diseno preserva la semantica del entorno Claude sin depender de hooks de Claude.
