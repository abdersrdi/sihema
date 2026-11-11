# Sihema

Native CNC program editor and simulator for Mac and iPad. Specification: `cnc-editor-spec-v2.md` (kept in `D:\cnc-editor-spec`).

## Rules

1. Apple frameworks first. Open source only to close a gap that was tried and measurably fails.
2. The interpreter, simulation and collision logic are our own code, proven by a reference corpus.

## Layout

- `Sources/SihemaCore`: platform-neutral Swift (tokenizer, Fanuc interpreter, toolpath, dexel simulation). No Apple-only imports, so tests run on Linux.
- `Sources/SihemaBench`: benchmark of the core on a 1 million line program.
- `Tests/SihemaCoreTests`: unit tests.
- `App/Shared`: the SwiftUI app for macOS and iOS (editor, Metal toolpath view, report). Generated project via XcodeGen (`project.yml`).

## Phase 0 status

Done in this repository: tokenizer, Fanuc subset interpreter, arc math, cycle time, 3-axis dexel CPU reference, benchmark, app shell with Metal toolpath view.

Known limits in Phase 0:
- Work offsets (G54-G59), G28, G92, cutter compensation, canned cycles, subprograms and macro variables are recognized and reported but not applied.
- Axis values without a decimal point are read as whole units (calculator style). Controller-specific handling comes with the dialect modules.
- Editor is plain text. Syntax coloring for the visible range is Phase 1, once the benchmark shows what it has to keep up with.
- Bundle ID `dev.sihema.spike` is a placeholder.

## Builds

- `Core` workflow (Linux): builds, tests and benchmarks on every push.
- `App` workflow (macOS): run by hand, builds both apps and benchmarks on Apple Silicon.
