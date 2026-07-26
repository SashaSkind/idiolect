# Working in this Jac project

This project is written in Jac. Before writing or editing `.jac` files, consult
the compiler reference with `jac guide`. At minimum, read
`jac-core-cheatsheet`; use `jac-cl-components` and `jac-cl-js-interop` for UI,
and `jac-node-edge-patterns` plus `jac-walker-patterns` for graph code.

Primary upstream references:

- https://github.com/jaseci-labs/jac
- https://docs.jaseci.org/
- https://docs.jaseci.org/llms.txt

Prefer the docs matching the installed compiler, then verify behavior with the
compiler and a running app. Do not infer Jac syntax from Python or JavaScript.

Validate changes with:

- `.venv/bin/jac check main.jac`
- `.venv/bin/jac start --dev main.jac`
- `.venv/bin/jac browse open localhost:8000`

Project constraints:

- Mac / Apple Silicon; use MLX and Metal, never CUDA.
- Track A owns `pipeline/asr.py` and `pipeline/rerank.py`.
- Track B must preserve `transcribe(audio_path)` and
  `rerank(candidates, vocab, context)`.
- The UI is Jac client code (`.cl.jac`), not React/TypeScript.
- This project deliberately sets `plugins.scale.microservices.enabled = false`.
  Keep the demo as one local full-stack process; do not let `sv import`
  auto-extract the walker module into a separate service.
