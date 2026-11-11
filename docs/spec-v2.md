# CNC Editor and Simulator for Mac and iPad: Project Specification v2

Date: 2026-11-11. Status: working draft, built from the first discussion file (`cnc-editor-spec.md`, Arabic) and the decisions made since. Items marked **[verify]** are claims we have not checked yet.

## 1. Goal

Build the first professional, native CNC program editor and simulator for the Apple ecosystem, good enough to be a real alternative to CIMCO Edit for people who work on a Mac.

- **Promise:** "Check your program before it reaches the machine." Edit, compare, plot and simulate G-code, and catch mistakes and collisions before a part is scrapped.
- **Business model:** one-time purchase, no subscription, runs fully on the device, no servers of ours.
- **Launch:** developed in phases, tested privately with CNC workers throughout, and launched publicly as one complete product.

## 2. Guiding rules

1. **Apple first.** Every capability uses an Apple framework unless that approach has been tried and measurably fails on quality or precision.
2. **Open source only to close a proven gap.** Allowed only with all four of these:
   - a written test showing the Apple approach failing;
   - a license check (no GPL or AGPL; LGPL only after legal review);
   - the library sits behind our own interface so it can be replaced;
   - a pinned version.
3. **Own the core.** The G-code interpreter, simulation and collision logic are our own code. Precision is proven by tests, not by borrowed libraries.
4. **Honest about limits.** We never claim collision-proof results. The tool verifies; the operator is responsible.
5. **Workers decide.** Real CNC workers test every phase and their notes drive priorities.

## 3. Positioning against CIMCO

CIMCO's strength is breadth: many controllers, machine communication (DNC), CAM-ecosystem integration and long shop trust. We do not compete on breadth at launch. We compete on:

- **Mac-native experience.** No Mac version of CIMCO Edit exists [verify]. Ours is built for macOS and iPadOS.
- **Price and licensing.** One-time purchase, no maintenance fee, no dongle.
- **Verification as the headline.** Compare, plot, simulate and collision-check, not only text editing.
- **Quality of the interface.** Modern, fast on very large files, Quick Look previews, iPad next to the machine.

Competitors and prices in the first file (CIMCO about $299, NCPlot $179, Macro Lathe Simulator $39.99, CAMotics free and GPL, GCode EditSim open source) need checking again before we use them in marketing [verify].

## 4. Users

- **Primary at launch:** CNC programmers, operators and tool setters who work on a Mac or iPad, vocational schools and training centers, small workshops.
- **Later:** job shops through direct sales and Apple Business Manager.
- Testers recruited in Phase 0 and kept for the whole project.

## 5. Platforms and languages

- **Mac:** Apple Silicon, recent macOS. The full programming station.
- **iPad:** recent iPadOS. Workshop companion: edit with a keyboard, view and simulate (full simulation on M-series chips, reduced on others), send to the machine.
- **One purchase** for both, with a shared bundle ID (universal purchase).
- **Sync:** iCloud Drive for program files. No server of ours.
- **App languages:** English (main), German, Dutch, French, Italian.
  - Menus, messages, help and the setup-sheet template are localized.
  - G-code itself is never translated or reformatted: numbers in files always use a dot as decimal separator. Only displayed values (times, sizes, reports) follow the user's locale.
  - A glossary of CNC terms per language is checked by native-speaking testers.
  - Metric and imperial units both supported.

## 6. Controllers (launch set)

Chosen as the most widely used:

| Controller | Launch support |
| --- | --- |
| Fanuc (0i, 30i families and compatibles) | Full, including Macro B |
| Haas | Full (Fanuc-like with its own differences) |
| Siemens (840D sl) | ISO mode and the common Siemens cycles |
| Mazak | EIA/ISO mode |
| Heidenhain | ISO mode only at launch; Klartext (conversational) after launch |

Later packs: Okuma, Mitsubishi, Brother, Fagor, Heidenhain Klartext.

Each dialect is its own module in the interpreter, sharing a common core.

## 7. Features and tiers

Two tiers, one purchase each, with an upgrade from Standard to Pro. Exact split to be confirmed after the beta.

**Standard: edit and check**

- Editor for files with millions of lines, dialect-aware coloring, line numbers, find and replace, transformations (rotate, mirror, shift, scale).
- 2D and 3D toolpath view, two-way link between a line and its path, distance measurement.
- Milling and turning cycles: drilling cycles, G70 to G76 turning cycles, threading.
- Fanuc Macro B execution with a debugger, breakpoints and variable watch.
- Side-by-side file compare that ignores formatting-only differences.
- Cycle time using machine acceleration and deceleration.
- Machine limit check: warns before an axis leaves its range.
- Cutter radius compensation (G41/G42) with geometric accuracy.
- Local explanation of a line or cycle with Foundation Models, clearly labelled as assistive and available only on devices that support it.

**Pro: simulate and produce**

- Physical material removal with the real tool size.
- Collision check for tool, holder and vise, especially on rapid moves.
- Tool and holder library with real shapes.
- Send to machine: Ethernet, FTP, RS-232 (Mac).
- Setup sheet PDF: tools, cycle time and zero point.
- Version history: who changed what and when.

**After launch (post-launch packs):** comparison against CAD models (STEP), 4- and 5-axis, mill-turn, Heidenhain Klartext, more controller packs, direct sales for multi-seat shop licenses.

## 8. Architecture

Swift and SwiftUI throughout, Swift C++ interop only if an approved exception requires it.

| Layer | Approach |
| --- | --- |
| Interface | SwiftUI, AppKit where needed on Mac |
| Editor | TextKit 2 with our own incremental tokenizer (G-code is line-based). Tree-sitter only if a benchmark on million-line files fails |
| Interpreter | Own Swift code, one module per dialect, deterministic, fully unit-tested |
| Drawing and 3D | Metal and MetalKit |
| Material removal (3-axis) | Metal Compute with our own dexel (height-map) model. Voxel libraries (OpenVDB) only if 5-axis or complex shapes require them and a test proves it |
| Cutter compensation | Own simd math for lines and arcs, as the controller does. Clipper2 only if precision tests fail |
| Collision | simd, Accelerate and our own bounding-volume hierarchy on Metal |
| File compare | `CollectionDifference` |
| Machine communication | Network.framework. Serial through POSIX termios (no wrapper library unless needed) |
| Setup sheet | PDFKit |
| Storage and history | `FileDocument` and SwiftData, iCloud Drive |
| Previews | Quick Look extension |
| Line explanations | Foundation Models |
| STEP files | **Genuine Apple gap.** OCCT, post-launch, after a legal review of LGPL |
| Boolean solid operations | **Genuine Apple gap.** Manifold or equivalent, post-launch if needed |
| DXF export | Own exporter (libdxfrw is GPL) |

## 9. Accuracy and testing

Accuracy is proven by a reference corpus, not claimed.

1. **Reference programs** per dialect with known results, gathered from beta testers and real machines (what the machine actually did).
2. **Automated tests** on the full corpus for every interpreter change, run in CI.
3. **Cycle-time calibration** against measured times on real machines.
4. **Edge cases:** arcs with R and I/K, cutter compensation at inside corners, nested cycles, subprograms, macro loops.
5. **Performance tests** on programs with millions of lines generated by CAM.
6. **Regression rule:** a bug a tester reports becomes a test before it is fixed.

## 10. Beta program

- Recruit CNC workers (programmers, operators, school instructors) before Phase 1 ends.
- Distribute with Mac TestFlight and iPad TestFlight.
- In-app "Send feedback with this program" button, with the user's consent to attach the file.
- Testers receive builds in four waves, not one phase at a time. Wave A (phases 0 and 1, the interpreter and precision foundation) goes to a small group first, because later phases depend on it. Wave B is phases 2 and 3 (milling and turning simulation), Wave C is phases 4 and 5 (machine connection and iPad), Wave D is phases 6 and 7 (extra controllers and hardening).
- Testers' programs and their real machine results feed the reference corpus.
- Feedback tracked in one list with a status for each note.

## 11. Business model

- Free download with a 14-day trial, then a one-time unlock (non-consumable in-app purchase). The trial is app logic and can be bypassed; accepted.
- Two tiers, with a Standard to Pro upgrade priced as the difference. Apple has no built-in "pay the difference", so Pro is granted when the user owns Pro, or Standard plus the upgrade product.
- Controller packs sold separately after launch where it makes sense.
- Initial test range from the first file: $59 to $79 Standard, $149 to $199 Pro. **Decide after beta**; the market decides, so prices must be easy to change.
- Direct sales (notarized Mac build) later for multi-seat licenses and education.

## 12. Compliance and risks

- **Publisher:** an Organization developer account in the company's name, which needs a D-U-N-S number. Start early, it can take weeks.
- **Names:** no manufacturer names or logos in the app name, icon or screenshots. Controller names appear only to describe compatibility.
- **No accuracy or collision-safety claims** in the listing, onboarding or marketing. The terms say the operator is responsible.
- **Mac sandbox:** serial access and network access need entitlements planned from the start.
- **Excluded licenses:** GPL and AGPL, including LinuxCNC, CAMotics, libdxfrw. GCode EditSim's license is checked before any use.

| Risk | Effect | Response |
| --- | --- | --- |
| Simulation error causes a real crash | Damage and reputation | Reference corpus, clear warnings, disclaimers |
| Too many dialects | Delay | Launch with the set in section 6, the rest as packs |
| Wrong AI explanation of a line | Real harm if trusted | Labelled assistive, never auto-applied |
| Simulation speed on older iPads | Slow | Full simulation only on M-series chips |
| CIMCO ships a Mac version | Direct competition | Lower price, native feel, one purchase |
| Scope too large for one launch | Never ships | Phase gates and tester feedback; scope cut at gates |
| Open-source gap larger than expected | Dependency risk | Four-condition rule in section 2 |

## 13. Phases and exit criteria

| Phase | Content | Exit criteria |
| --- | --- | --- |
| 0. Spike | Tokenizer on a 1M-line file, Fanuc parser, Metal toolpath view, small 3-axis dexel prototype | Benchmarks recorded; testers recruited; first reference programs collected |
| 1. Edit | Editor, Fanuc and Haas, plot, compare, cycle time, limit check, radius compensation | Reference corpus passes; testers use it on real work |
| 2. Simulate | Material removal, tool library, collision with holder and vise | Simulation matches tester machines within agreed tolerance |
| 3. Turn | G70 to G76 cycles, threading, turning simulation | Lathe reference programs pass |
| 4. Connect | Ethernet, FTP, serial, setup sheets, version history | Tested on real machines with testers |
| 5. Platforms | iPad companion, Quick Look, iCloud Drive, five-language localization review | Native-speaker testers sign off each language |
| 6. Siemens and Mazak | Extra dialect modules | Reference corpus passes for each |
| 7. Hardening and launch | Performance, accessibility, legal review, App Store submission | Beta bugs closed, listing and terms reviewed |

Launch scope as proposed here: phases 0 to 7. Post-launch: STEP comparison, 5-axis, mill-turn, Klartext. Confirm or change at the first gate.

## 14. Open decisions

- [x] App name: **Sihema** (chosen 2026-11-11). Invented name built from fragments of controller names, no manufacturer name in it and no known meaning in English, German, Dutch, French or Italian. Checked: no clash in the US, UK, FR, ES and IT App Stores, `.com` looked free. Rejected: Siehma and Hasiem (too close to Siemens, or a blend of Haas and Siemens), Hash and Hashiem (existing word and names). **Still to do before committing:** trademark search (USPTO, EUIPO, WIPO) in the software and machine-tool classes; native-speaker check in German, Dutch, French and Italian; reserve the name in App Store Connect; domain on a non-`.com` extension if needed. Subtitle carries the keywords, for example "CNC Editor & Simulator".
- [ ] Final tier split and prices (after beta)
- [ ] Minimum macOS and iPadOS versions
- [ ] Which testers and how many per phase
- [ ] Which Siemens and Mazak cycles are in the launch set
- [ ] Whether STEP comparison stays post-launch
- [ ] Date for direct sales outside the App Store
- [ ] Verify the market facts marked [verify]
