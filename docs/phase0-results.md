# Phase 0 results

Measured 2026-11-11 on the development PC (Windows, x86_64, Swift 6.4.2, release build). Mac and iPad numbers
come from the `App` workflow once it has run.

## Core tests

46 unit tests, all passing: tokenizer (13), interpreter (24), dexel simulation (9).

## Benchmark: synthetic 1 million line program (20 MiB of zig-zag passes with arcs)

| Step | Result | Note |
| --- | --- | --- |
| Tokenize | 0.059 s | 1,000,000 lines, 4,009,929 words, 17.0 M lines/s |
| Interpret (Fanuc subset) | 0.091 s | 999,993 moves, 10.9 M moves/s |
| Flatten arcs (0.005 mm chord error) | 0.013 s | 1,034,818 straight pieces |
| Dexel CPU simulation | 0.054 s | 20,000 moves into 440 x 440 columns at 0.25 mm, 6 mm flat tool |

## What this means

- **Editor:** the tokenizer is fast enough to tokenize an entire million-line file in well under a tenth of a second.
  Syntax coloring does not need an external parser library (Tree-sitter) on speed grounds. The open question for
  Phase 1 is TextKit 2's own scrolling and layout speed on huge files, which can only be measured on a Mac.
- **Interpreter:** a million moves per 0.09 s leaves a large margin for the extra work coming later (cutter
  compensation, macros, acceleration-limited cycle time).
- **Simulation:** the CPU reference handles hundreds of thousands of short moves per second on a small grid. A Metal
  version is still needed for large stock and long programs, and it must reproduce the CPU results exactly.

## Not measured or not verified yet

- The Mac and iOS app targets and the Metal renderer have never been built (needs macOS; CI is blocked by GitHub
  billing).
- TextKit 2 behaviour with a million-line file.
- Accuracy against real machine results (needs the tester reference corpus).
- Dexel benchmark moves are short and cut shallow; heavy roughing programs will cost more per move.

## Local development on Windows

`tools/win-swift.ps1` builds and tests the core with the Swift Windows toolchain. The Visual Studio C++ build tools
and Swift are installed on C:. `D:` is a FAT32 removable drive, which Visual Studio refuses and which is a poor fit for
build output, so the build folder lives on C:.
