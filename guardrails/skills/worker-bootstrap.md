---
name: worker-bootstrap
description: Read this skill at the START of every worker session before writing any code. Covers the non-negotiable Definition of Done rules including the "real-execution" gate for external-system fixes (DB/net/FS/subprocess/model/LLM). Prevents the most common sources of fake-work false-greens.
---

# worker-bootstrap — leer al arrancar

Leer este skill antes de escribir cualquier código, test, o commit.

## Definition of Done — resumen ejecutivo

Un símbolo / feature / fix NO está done hasta que (checklist completo en `guardrails/docs/DEFINITION_OF_DONE.md`):

1. **Call-site productivo.** ≥1 invocación desde el entry-point de producción.
2. **Evidencia de ejecución.** Output real pegado en el PR.
3. **Sin placeholders ghost.** 0 matches de `TODO|FIXME|placeholder|not yet implemented|DEV SKIPPED|available when connected`.
4. **Sin bypass de seguridad en release.**
5. **Documentación consistente.** Si README dice "implementado", el E2E corre contra el binario productivo.
6. **Test de integración ≠ test unitario agrupado.** Constructor directo bypassing entry-point no cuenta.

## Regla extra: fixes de sistemas externos → ejecución real obligatoria

Si el fix toca **DB, red, filesystem, subprocess, modelo/LLM o servicio externo**:

- Un test mockeado o estructural **NO es suficiente**.
- Requiere un test de integración / roundtrip live con **input adversarial** (string con comillas + `$()` para SQL; input de tamaño real para modelo; forzar fallo de red, etc.).
- Si la ejecución real es genuinamente inviable → nota explícita de por qué + registro de verificación manual.

**Cuatro anti-patrones prohibidos:**

| # | Anti-patrón | Por qué falla |
|---|---|---|
| a | Mock del mismo componente que el issue dice que falla | Verifica el mock, no el sistema real |
| b | `read_text` / grep sobre source + assert substring | Verifica el texto del archivo, no que la lógica corra |
| c | Paths absolutos hardcodeados en tests | Rompe fuera de la máquina del autor |
| d | Issue de wiring/presence → assert substring en source en vez de test behavioral | No detecta si el código nuevo se ejecuta realmente |

**Para tipo (d) — issues de "instrumentá/cableá/hacé observable/verificá que X está presente":**
Forzar la condición, mockear el sistema externo para que levante la excepción, y asertar sobre la señal de runtime (flag degraded, estado del circuit-breaker, campo en la respuesta). No leer el source.

**Casos reales que motivan esta regla:**
- EP#1614: modelo lento mockeado → respuesta vacía en prod con input real.
- fleet#406: bats grep-source verde → `:'var'`+`-c` rompía el cache real en ejecución.

## Referencias

- `guardrails/docs/DEFINITION_OF_DONE.md` — norm completa (bloque para CLAUDE.md)
- `guardrails/skills/verify-done.md` — procedimiento de self-check con evidencia
- `guardrails/skills/surfacing-fakework.md` — cómo surfacear fakework durante el trabajo
- `guardrails/docs/FAKE_WORK_AUDIT.md` — caso real (60% fake-work con 205 tests verdes)
