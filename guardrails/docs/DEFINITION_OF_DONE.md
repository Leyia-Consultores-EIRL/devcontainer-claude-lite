# Definition of Done — snippet listo para pegar en `CLAUDE.md`

> **Instrucciones para el humano o AI que instala estos guardrails**:
> copia el bloque entre los marcadores `<!-- begin -->` y `<!-- end -->` al
> final del `CLAUDE.md` en la raíz del proyecto target. El bloque es
> agnóstico al lenguaje — el único ajuste específico vive en
> `.claude/hooks/project.conf`.

<!-- begin: paste this block into your project's CLAUDE.md -->

## Definition of Done (no negociable)

Un símbolo público, feature, endpoint, módulo o adapter NO está "done" hasta que:

1. **Call-site productivo.** Existe ≥1 invocación del símbolo público alcanzable
   desde el entry-point de producción (ver `.claude/hooks/project.conf:ENTRY_POINTS`),
   NO detrás de `#[cfg(test)]` / `if __name__ == "__main__"` de test, NO detrás
   de flag off-by-default sin CLI toggle documentado.

2. **Evidencia de ejecución.** El PR o commit incluye output pegado de:
   - Ejecutar el binario/servidor productivo con un comando que ejercita la feature
   - Log real mostrando el código path nuevo ejecutado (tracing/log con
     identificador único del módulo)

3. **Sin placeholders ghost.** Grep sobre el diff del PR devuelve 0 matches de:
   ```
   TODO|FIXME|placeholder|not.yet.implemented|DEV SKIPPED|available when connected|\[0u8;\s*\d+\]
   ```

4. **Sin bypass de seguridad en release.** Constantes de crypto/licensing no
   son arrays de ceros (`[0u8; N]`, `bytes([0] * N)`, etc.). Production build
   ejecuta verificaciones reales, no paths dev-only.

5. **Documentación consistente.** Si README o CLAUDE.md lista la feature como
   "implementada", el test E2E correspondiente existe y corre contra el
   binario productivo, no contra el módulo aislado.

6. **Test de integración ≠ test unitario agrupado.** Cualquier archivo en
   `*_integration.rs` / `test_integration_*.py` / `*.e2e.ts` que instancie el
   módulo a través del constructor directo (`Adapter::new()` / `Adapter()` /
   `new Adapter()`) bypassing el entry-point **no cuenta como integración**.
   Tests de integración deben ejercer el camino productivo.

**NO hagas commit con prefijo `feat:` si algo de lo anterior falla.**
Usa `wip:` o `scaffold:` hasta cumplir DoD.

**Antes de reportar "complete" a memoria o al humano**, ejecuta:
```bash
bash .claude/hooks/integration-gate.sh && echo "DoD verified"
```
Si falla (exit != 0), el trabajo no está done — independiente de cuántos
tests pasen.

### Protocolo de verificación manual (6 preguntas)

Antes de aceptar "done" de Claude, el humano debe poder ver output real de:

1. Dependency tree del entry-point mencionando el módulo
2. `--help` del binario mostrando la feature
3. `grep <símbolo>` fuera de tests (≥1 match en código productivo)
4. Call-graph trazable desde `main()` hasta el módulo
5. `grep` de placeholders (`TODO|DEV SKIPPED|[0u8;]`) → 0 matches
6. Trace/log real del módulo ejecutándose en un run productivo

Si alguna pregunta queda sin output → no es done.

### Referencias

- Caso real que motivó este DoD: `guardrails/docs/FAKE_WORK_AUDIT.md`
- Hooks que enforce este DoD: `.claude/hooks/integration-gate.sh`
- Mecanismo por lenguaje: `.claude/hooks/lang/`

### Fixes de sistemas externos requieren verificación de ejecución real

Un fix que toca **DB, red, filesystem, subprocess, modelo/LLM o servicio externo** NO está done con tests estructurales o mockeados. El DoD exige **ejecución real**: un test de integración o roundtrip live que ejercite el sistema real con un **input adversarial** (ejemplos: SQL fix → `put`/`get` con string venenoso `' OR 1=1; DROP TABLE --`; modelo/timeout → correr el modelo real sobre input de tamaño real; red → forzar el fallo real; FS → path con caracteres especiales). Si la ejecución real es genuinamente inviable, se requiere una nota explícita de por qué + registro de verificación manual.

**Prohibido explícitamente en estos fixes:**

- **(a) Mockear el componente que falla.** Si el issue dice "el modelo X devuelve vacío en timeout", un test que parchea `model.generate = lambda: ""` está mockeando justo lo que falla — no verifica nada.
- **(b) `read_text` / grep sobre el source y asertar substrings.** `assert "retry_logic" in open("agent.py").read()` verifica que el texto existe en el archivo, no que la lógica corre.
- **(c) Paths absolutos hardcodeados en tests.** `/home/usuario/proyecto/archivo.csv` rompe en cualquier otra máquina.
- **(d) Issues de tipo "instrumentá / cableá / hacé observable / verificá que X está presente" → exigir test behavioral.** Forzar la condición, mockear el sistema externo para que lance la excepción, y asertar sobre la señal de runtime: flag degraded, estado del breaker, campo de respuesta — NO asertar substring en source.

**Por qué**: EP#1614 (modelo lento mockeado → respuesta vacía en prod); fleet#406 (bats grep-source verde → `:'var'`+`-c` rompía el cache real). La única prueba que valió fue un roundtrip live contra el sistema real.

<!-- end: paste above into CLAUDE.md -->
