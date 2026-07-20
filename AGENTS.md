# Agent Instructions

- Ask at most 1–3 clarifying questions only when missing information would change the implementation, API, data model, UX, security posture, or irreversible actions; otherwise proceed with stated assumptions.
- Do not do manual installations inside lock files, use the tooling commands where possible.
- Do not write unecessary comments in the code.
- For small, basic, mostly one liner changes do not run build commands. Only when you think would be good idea.
- Run Flutter tests from `apps/` with `$HOME/fvm/versions/stable/bin/flutter test --reporter expanded`; bypass the FVM proxy so agent command capture receives the output.
- Keep `flutter_rust_bridge_codegen` on the exact Dart and Rust `flutter_rust_bridge` version.
- After changing Rust bridge APIs, run `flutter_rust_bridge_codegen generate --stop-on-error` from `apps/`; never edit `apps/lib/src/rust/` or `rust/src/frb_generated.rs` by hand.
- Do not start or restart the dev servers or apps itself.
- When adding packages/libraries use the cleanest CLI commands for this project unless that's not possible. If not, do not do any implementation or installation and reply with why.
- Skip writing unnecessary test files. Only when very needed
- There is no backend service, everything is local except for APIs for tooling, LLM models etc.
- Don't be reluctant to use web search tools for solving things, looking up latest docs etc. before implementing things unless the problem is very simple.

## Frontend Components

- no rules for now
