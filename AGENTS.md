# AGENTS.md — guardrails obligatorios para agentes Codex/GPT

Este repo es el entorno canonico de guardrails para agentes que NO leen `CLAUDE.md` ni ejecutan hooks de Claude Code. Para Codex/GPT, estas reglas viven aca y son obligatorias. No hay imports externos: todo lo necesario para trabajar con los mismos dientes esta en este archivo.

## Regla #-1: no quemar saldo API

Al inicio de todo worker Codex/GPT, antes de leer codigo o ejecutar tests:

```bash
unset ANTHROPIC_API_KEY OPENAI_API_KEY
```

Los workers deben consumir la suscripcion o credencial deliberada del entorno de agente, no claves API del proyecto por accidente. Si un comando necesita explicitamente una key real, pedirla o documentar que no se pudo correr; no reutilizar variables heredadas.

## Definition of Done no negociable

Un simbolo publico, feature, endpoint, modulo, adapter o fix NO esta done hasta que todo esto sea cierto:

1. **Call-site productivo.** Existe al menos una invocacion del simbolo publico alcanzable desde el entry-point de produccion. No cuenta un caller en tests, fixtures, lab, ejemplos, `if __name__ == "__main__"` usado como test, `#[cfg(test)]`, ni una flag off-by-default sin toggle CLI documentado.
2. **Evidencia de ejecucion real.** El PR, commit o reporte incluye output pegado de ejecutar el binario, servidor, app o worker productivo con un comando que ejercita la feature. Debe haber un log, trace, respuesta HTTP, conteo de storage o salida que solo pueda aparecer si el nuevo path corrio.
3. **Cero placeholders ghost.** El diff no puede agregar matches de:

```bash
TODO|FIXME|placeholder|not.yet.implemented|not yet implemented|DEV SKIPPED|available when connected|Coming soon|mock data|not.yet.wired|\[0u8;\s*\d+\]|changeme|bytes\(\[0\]
```

4. **Sin bypass de seguridad en release.** Constantes de crypto, licensing, auth, permisos o integridad no pueden ser arrays de cero, claves dummy, verificaciones `SKIPPED`, checks dev-only ni rutas de seguridad apagadas en production build.
5. **Documentacion consistente.** Si README, AGENTS, docs, memoria, issue o PR dicen "implementado", debe existir verificacion E2E o integracion contra el camino productivo. Un test que instancia el modulo aislado no alcanza.
6. **Test de integracion no es test unitario agrupado.** Archivos llamados `*_integration.*`, `test_integration_*`, `*.e2e.*` o equivalentes no cuentan como integracion si crean el componente directamente (`Adapter::new()`, `Adapter()`, `new Adapter()`) evitando el entry-point productivo.
7. **Fixes de sistemas externos requieren ejecucion real.** Si toca DB, red, filesystem, subprocess, modelo/LLM o servicio externo, el fix exige roundtrip live o test de integracion con input adversarial. Ejemplos: SQL con `"' OR 1=1; DROP TABLE --"`, FS con espacios/caracteres raros, red forzando el fallo real, LLM/modelo con input de tamano real, subprocess con argumentos que antes rompian.

Si algo de lo anterior falla, no uses `feat:` ni digas "complete", "done", "ready", "working", "shipped", "fixed" o equivalente. Usa `wip:` o `scaffold:` y reporta exactamente que falta.

## Antipatrones prohibidos

Estos patrones no son tests aceptables ni evidencia de done:

1. **Mockear el componente que falla.** Si el bug es "el modelo real devuelve vacio en timeout", no sirve parchear `model.generate = lambda: ""`. Eso verifica el mock, no el sistema.
2. **Leer source y asertar substrings.** `read_text()`, `open()`, `readFileSync()` o `grep` contra codigo fuente mas `assert "retry_logic" in source` prueba que existe texto, no que corre.
3. **Paths absolutos hardcodeados en tests.** Nada de `/home/...`, `/tmp/*-work-*`, `/workspace/.worktrees/...`. Usar fixtures relativas, `tmp_path`, env vars o paths derivados del repo.
4. **Issues de instrumentar/cablear/observar con tests estructurales.** Para "instrument", "wire", "observe", "verificar que X esta presente", forzar la condicion y asertar una senal runtime: flag `degraded`, estado de breaker, log con nivel correcto, campo de respuesta, metric emitida. No substring del source.

## Cinco clases de fake-work que debes buscar

1. **Ghost code.** Compila y puede tener tests, pero ningun entry-point productivo lo llama. Sintomas: simbolo publico sin caller, builder method nunca invocado, endpoint que devuelve stub.
2. **Contract drift.** Productor y consumidor estan cableados, pero el schema diverge: `snake_case` vs `camelCase`, campo faltante, envelope distinto, tipo incompatible, endpoint inexistente.
3. **Storage continuity rota.** Hay tabla, cache, bucket, collection o directorio, pero no hay productor alcanzable, hay cero filas despues de un run, o writer y reader usan paths/keys distintos.
4. **Identity collision.** Un campo per-scope de display (`page_number`, `subdoc_id`, indice local) se usa como identidad global: React key, Set/Map/dict key, cache key, FK, UUID/hash seed. Produce colisiones y corrupcion silenciosa.
5. **Soft fallback.** Un fallo devuelve `[]`, `None`, `{}`, `success=false` ignorado o respuesta normal sin `raise`, sin `log.error`/`warning`, sin `degraded=true` y sin senal visible al usuario.

## Protocolo permanente: surfacing fake-work

Durante cualquier tarea, si ves fake-work, no lo anotes mentalmente y no agregues un TODO. Abri un issue o deja un registro equivalente con evidencia y sigue con la tarea original.

Se debe surfacear de inmediato si aparece:

```text
[ ] handler vacio, noop o listener sin efecto
[ ] simbolo exportado con 0 callers productivos
[ ] route/API/UI devolviendo stub: {}, status ok teatral, pending, available when connected
[ ] env var documentada pero no leida
[ ] catch/except que traga el error o retorna vacio
[ ] placeholder o Coming soon en superficie de usuario
[ ] feature detras de flag siempre falsa o sin toggle real
[ ] tabla/cache con read sin write o write sin read
[ ] drift de schema productor-consumidor
[ ] ID local usado como key global
[ ] cualquier mismatch entre "esto anuncia una feature" y "la feature funciona end-to-end"
```

Formato minimo del registro: evidencia exacta con archivo:linea, repro o comando para confirmar, impacto, fix sugerido. Un finding por issue. No absorber findings separados dentro del PR actual sin registrarlos.

En cada reporte final incluir:

```text
New issues filed (live mode):
- None - no additional fakework discovered in reviewed scope: <files/areas>
```

o la lista de issues creados.

## Checklist verify-done

Usar antes de afirmar que una feature, endpoint, modulo o simbolo esta done.

1. **Entry-point y config.** Identifica el entry-point productivo real: `src/main.rs`, `cmd/app/main.go`, `__main__.py`, script `pyproject`, `package.json` `main`/`bin`/`start`, route registry, Android `MainActivity`/`Application`, etc.
2. **Reachability de dependency tree.** Ejecuta el comando apropiado y pega output:

```bash
# Rust
cargo tree -p <main-crate> | grep <new-module-or-crate>

# Python
python -c "import ast; tree=ast.parse(open('<entrypoint>').read()); print([n for n in ast.walk(tree) if isinstance(n, (ast.Import, ast.ImportFrom))])" | grep <module>

# Node/TS
pnpm exec tsc --listFiles --project <tsconfig> 2>/dev/null | grep <module-path>

# Go
go list -deps ./cmd/<app> | grep <package>

# Java/Kotlin
grep -r "import.*<NewClass>\|<NewClass>" src/main app/src/main
```

3. **La feature se ve desde el binario/servidor/app.**

```bash
<binary> --help | grep -i <feature>
python -m <pkg> --help | grep -i <feature>
pnpm <script> --help 2>&1 | grep -i <feature>
curl -s http://localhost:<port>/<route>
```

La respuesta no puede ser `{}`, `pending`, `Coming soon`, `available when connected` ni una nota teatral.

4. **Call-site fuera de tests.**

```bash
grep -r "\b<SYM>\b" <src-dirs> --include='*.<ext>' \
  | grep -v -E '(__tests__|\.test\.|\.spec\.|/tests?/|/lab/|/examples/)' \
  | wc -l
```

Pasa solo si el conteo es mayor que 0 en codigo productivo.

5. **Call-graph trazable.** Escribe la cadena con archivos y lineas:

```text
entrypoint
  -> buildApp()/main()/router registration
    -> route/service/usecase
      -> nuevo modulo/simbolo
```

Falla si algun hop falta o esta detras de una flag no habilitada.

6. **Placeholder scan del diff.**

```bash
git diff <base-branch>...HEAD --unified=0 \
  | grep -iE 'TODO|FIXME|placeholder|not.yet.implemented|not yet implemented|DEV SKIPPED|available when connected|Coming soon|mock data|not.yet.wired|\[0u8;\s*\d+\]|changeme|bytes\(\[0\]' \
  | head -20
```

Pasa solo con 0 matches en lineas agregadas.

7. **Runtime trace.** Arranca el camino productivo, ejercita la feature y pega log/salida con timestamp o valor unico del nuevo modulo:

```bash
curl -X POST http://localhost:<port>/<route> -H 'Content-Type: application/json' -d '<payload>'
grep '<unique-string-from-new-code>' <log-file>
```

Si no se puede correr por falta de DB, secretos, device o red, reporta `CANNOT RUN` con razon concreta. No lo marques PASS.

Veredicto obligatorio:

```text
DoD verdict for <feature/symbol>:
  1. deps-tree-reachable: PASS/FAIL/CANNOT RUN - evidence
  2. binary-mentions:     PASS/FAIL/CANNOT RUN - evidence
  3. grep-outside-tests:  PASS/FAIL - evidence
  4. call-graph-trace:    PASS/FAIL - chain
  5. no-placeholders:     PASS/FAIL - evidence
  6. runtime-trace:       PASS/FAIL/CANNOT RUN - evidence

Verdict: DONE / NOT DONE.
```

## Checklist verify-contract

Usar antes de decir que un endpoint, metodo gRPC, query GraphQL, mensaje, archivo serializado o integracion cross-layer esta completa.

1. **Producer schema ground truth.**

```bash
# Pydantic v2
python -c "from <module> import <Model>; import json; print(json.dumps(<Model>.model_json_schema(), indent=2))"

# FastAPI
curl -s http://localhost:<port>/openapi.json | python3 -m json.tool | grep -A 40 '"<Model>"'

# GraphQL
curl -s http://localhost:<port>/graphql -d '{"query":"{ __schema { types { name fields { name type { name kind } } } } }"}'

# Protobuf / Rust / Go
grep -A 40 'message <Model>\|struct <Model>\|type <Model> struct' <schema-or-src-files>
```

2. **Consumer types enumerados.**

```bash
grep -R "interface <Type>\|type <Type>\|class <Type>(TypedDict)\|struct <Type>" apps src packages --include='*.ts' --include='*.tsx' --include='*.py' --include='*.rs' --include='*.go'
```

Falla si el consumidor usa `any`, dict raw o `JSON.parse` sin contrato.

3. **Diff campo por campo.** Comparar nombres, tipos, shape, envelope y optionality. Flags obligatorios: naming drift sin transform verificado, envelope drift, optionality drift, type drift, missing field.
4. **Path registrado.**

```bash
curl -s http://localhost:<port>/openapi.json \
  | python3 -c "import sys,json; spec=json.load(sys.stdin); print('\n'.join(spec.get('paths',{}).keys()))" \
  | grep -F "<endpoint>"
```

Adaptar para router Express/Fastify, Django `show_urls`, gRPC `grpc_cli ls`, GraphQL introspection.

5. **Live fixture con asserts de campos.** No basta HTTP 200.

```bash
python3 - <<'PY'
import httpx, sys
resp = httpx.get("http://localhost:<port>/<endpoint>")
assert resp.status_code == 200, (resp.status_code, resp.text)
body = resp.json()
required = ["field_a", "field_b"]
missing = [f for f in required if body.get(f) is None]
if missing:
    print("FAIL missing:", missing, "actual keys:", list(body.keys()), file=sys.stderr)
    raise SystemExit(1)
print("PASS", {k: type(body[k]).__name__ for k in required})
PY
```

Veredicto: `CONTRACT VERIFIED` solo si schema productor, tipo consumidor, diff, path y live fixture pasan.

## Checklist verify-storage

Usar antes de decir que una tabla, cache, bucket, collection, indice o capa persistente funciona.

1. **Enumerar todas las capas.**

```bash
# SQLite
python3 -c "import sqlite3; c=sqlite3.connect('<db>'); print('\n'.join(r[0] for r in c.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")))"

# Postgres
psql "$DATABASE_URL" -c "\dt"

# Qdrant
curl -s http://localhost:6333/collections | python3 -m json.tool | grep '"name"'

# Redis
redis-cli --scan --pattern '*' | sed 's/:.*//' | sort -u | head -20

# FS
find . -type d \( -name 'cache' -o -name '.cache' -o -name 'ocr_*' -o -name 'fts_*' \) | head -50
```

2. **Productor presente para cada capa.**

```bash
grep -rn "INSERT INTO <table>\|upsert.*<collection>\|put_object\|upload_file\|\.set(\|write_bytes\|write_text\|json.dump" src app mcp_server packages --include='*.py' --include='*.ts' --include='*.rs' --include='*.go' | grep -v 'test\|spec\|migration\|schema'
```

3. **Productor alcanzable desde entry-point.** Trazar:

```text
entrypoint -> ingest/route/job -> pipeline -> producer function -> INSERT/upsert/write
```

Falla si el productor existe pero no se llama.

4. **Live count despues de fixture real.**

```bash
# Ejecutar ingest/CLI/job real con fixture
python -m <pkg>.cli ingest --file tests/fixtures/sample.pdf --case-id fixture-001

# Contar
python3 -c "import sqlite3; c=sqlite3.connect('<db>'); print(c.execute('select count(*) from <table>').fetchone()[0])"
curl -s http://localhost:6333/collections/<collection> | python3 -m json.tool | grep points_count
find ./cache/<dir> -type f | wc -l
redis-cli --scan --pattern '<prefix>*' | wc -l
```

Pasa solo con conteo mayor que 0 para cada capa esperada.

5. **Consistencia de migracion.** Si el PR cambio path/key/table de escritura, grep de read-sites antiguos debe dar 0:

```bash
grep -rn "<old_key_or_path_or_table>" src app mcp_server packages --include='*.py' --include='*.ts' | grep -iE 'get|read|load|fetch|open|SELECT'
```

Veredicto: `STORAGE VERIFIED` solo si hay productor, reachability y conteo live. Cero filas es failure aunque los logs digan "indexed".

## Checklist verify-identity

Usar antes de decir que IDs, keys, dedupe, deterministic UUIDs o cache keys son estables o collision-free.

1. **Enumerar usos del campo como identidad.**

```bash
grep -rn "key={.*<field>\|new Map\|new Set\|\.set(<field>\|\.has(<field>" apps src --include='*.ts' --include='*.tsx'
grep -rn "uuid5\|uuid3\|hashlib\|md5\|sha\|PointStruct\|upsert\|PRIMARY KEY\|JOIN.*<field>\|WHERE <field>" src app mcp_server --include='*.py' --include='*.ts' --include='*.sql'
grep -rn "set(.*<field>\|\.add(<field>\|{.*<field>.*for.*in" src mcp_server --include='*.py'
```

2. **Tabla de scope completeness.** Para cada uso, listar campos en la key, dimensiones requeridas y dimensiones faltantes. Ejemplo: `(case_id, page_number)` falla si la pagina es unica solo dentro de `(case_id, subdoc_id, page_number)`.
3. **Schema-level uniqueness.** Verificar UNIQUE/PK/index o constraint equivalente si se usa como identidad global:

```bash
python3 -c "import sqlite3; c=sqlite3.connect('<db>'); print(list(c.execute(\"SELECT sql FROM sqlite_master WHERE type in ('table','index') AND tbl_name='<table>'\")))"
```

4. **Audit UUID/hash seed.** Mostrar el cuerpo de la funcion o AST/unparse del call y confirmar que incluye todas las dimensiones.
5. **Regression con dos scopes.** La prueba debe demostrar que el generador viejo colisionaria y el nuevo no:

```bash
python3 - <<'PY'
import uuid
case = "case-1"
old_a = uuid.uuid5(uuid.NAMESPACE_DNS, f"{case}:1")
old_b = uuid.uuid5(uuid.NAMESPACE_DNS, f"{case}:1")
new_a = uuid.uuid5(uuid.NAMESPACE_DNS, f"{case}:tomo-a:1")
new_b = uuid.uuid5(uuid.NAMESPACE_DNS, f"{case}:tomo-b:1")
print("OLD COLLISION:", old_a == old_b)
print("NEW COLLISION:", new_a == new_b)
PY
```

Veredicto: `IDENTITY VERIFIED` solo si ningun uso global depende de un identificador per-scope incompleto.

## Checklist verify-honest-failure

Usar antes de decir que errores, fallback, health checks o degraded mode estan bien manejados.

1. **Enumerar soft returns en produccion.**

```bash
grep -rn "return \[\]\|return None\|return {}\|return null\|return undefined\|success.*false\|catch.*return\|except.*:" src app mcp_server packages --include='*.py' --include='*.ts' --include='*.tsx' | grep -v 'test\|spec'
```

2. **Signal audit.** Para cada candidato: debe haber `raise`, `throw`, `log.error`, `logger.warning`, `degraded=true`, `success=false` propagado y chequeado, HTTP 5xx/4xx, o error visible al usuario. Si el caller trata `[]` como exito normal, falla.
3. **Agent tool handling.** Si hay agentes/tools, verificar `result.success`, `is_error` o equivalente. Un error de tool y una busqueda legitima sin resultados no pueden producir el mismo mensaje.
4. **Health check real.** El handler de `/health` o `/ready` debe conectar a dependencias declaradas:

```bash
curl -s http://localhost:<port>/health | python3 -m json.tool
grep -rn "health\|ready" src app mcp_server --include='*.py' --include='*.ts'
grep -rn "get_collections\|list_buckets\|ping\|execute\|connect\|redis\|qdrant\|minio" src app mcp_server --include='*.py' --include='*.ts'
```

Un dict hardcodeado `{status: "ok"}` no es health check.

5. **Degraded mode visible.** Toda rama fallback por ImportError, timeout, connection error o dependencia faltante debe loguear warning/error, setear `degraded=True` o equivalente, y exponerlo en schema/respuesta.

Veredicto: `HONEST FAILURES VERIFIED` solo si cada error path produce una senal observable y distinguible.

## Gates mecanicos obligatorios para Codex/GPT

Codex/GPT no ejecuta hooks `Stop`, `PostToolUse` ni `SessionStart` de Claude. Por eso:

1. Antes de cerrar un turno con claims de done, ejecutar manualmente si existen:

```bash
bash .claude/hooks/integration-gate.sh
bash .claude/hooks/ghost-test-guard.sh
```

2. Si el repo usa `guardrails/.claude/hooks/` como fuente y aun no esta instalado en `.claude/hooks/`, ejecutar los equivalentes desde `guardrails/.claude/hooks/` o instalar los guardrails antes de afirmar done.
3. `integration-gate.sh` exit 2 significa: nuevos simbolos publicos sin call-site productivo vs baseline. Accion default: wirear desde entry-point o borrar. No agregar al baseline para terminar rapido.
4. `ghost-test-guard.sh` exit 2 significa: tests nuevos/modificados verifican texto de source, paths absolutos o bats estructural. Accion default: convertir a test de comportamiento.
5. Si un gate no puede correr por config ausente, reportar `CANNOT RUN` y no convertir eso en PASS.

## Disciplina de reporte

Un reporte final de Codex/GPT que diga done debe incluir:

```text
Verification:
- unset ANTHROPIC_API_KEY OPENAI_API_KEY: done
- DoD verdict: DONE / NOT DONE
- integration-gate: PASS / FAIL / CANNOT RUN
- ghost-test-guard: PASS / FAIL / CANNOT RUN
- verify-contract/storage/identity/honest-failure: PASS / N/A / FAIL, segun aplique
- Runtime evidence: comando + salida clave
- New issues filed (live mode): ...
```

Si la evidencia no existe, el trabajo no esta done aunque todos los unit tests pasen.
