# Agentic spreadsheet workflows — research report

**Prepared for:** the captain (via firstmate)
**Verified:** 2026-11-05 (UTC) — every URL below was fetched and read on this date; machine facts were checked on the actual rig.
**Scope:** knowledge only. No installs, no code changes, no workbook edits were made.

---

## Executive summary (plain language)

**Your instinct is right, and your diagnosis is exactly correct.** The problems you've seen with Hermes's spreadsheet work are not a model problem — they are a *file format and tooling* problem, and it has a known, well-documented fix.

**Why spreadsheets get rewritten and broken today:** a CSV file has no formulas, no styling, no multiple sheets, no charts, no pivot tables — none of the things that make an Excel workbook valuable. When an agent "edits" your spreadsheet by way of CSV, it must *rebuild* the workbook from scratch on the other side, and everything that can't survive the CSV round-trip is silently gone or recomputed. Worse, the agent usually has to re-create your formulas from memory, so previously-fixed things break again. Nothing was wrong with the model; the pipeline was lossy by construction. Microsoft's own file format documentation and the openpyxl project's warnings spell out exactly what gets lost ([1], [2]).

**What exists to fix it:** there is now a mature family of tools that open the real `.xlsx` file, change *only* the cells you asked about, and save it back — leaving formulas, styles, other sheets, charts, and macros alone. The best of these today is the openpyxl-based `excel-mcp-server` (4,300+ stars, very active, cross-platform, explicitly built so that "editing a workbook keeps what the tools cannot change" [8]). Python's openpyxl, Rust's umya-spreadsheet, Node's exceljs and xlsx-populate, and Go's excelize all offer the same edit-in-place class of operation at library level. Your pi workers can drive them directly, or through MCP servers, with your Z.AI GLM models as the brain — no Excel required ([8], [9], [3]).

**The one thing no Linux library can do:** *recalculate formulas*. Libraries store formulas as text; they never compute results. If an agent changes an input cell, the dependent totals in the saved file are stale until a real spreadsheet engine recalculates. Microsoft's own agents skip this by using real Excel; on Linux the practical answer is a LibreOffice headless recalculation step — Anthropic's official xlsx skill ships exactly such a script (`recalc.py`) and mandates it after every edit ([2]). **Your rig has OnlyOffice but no LibreOffice today** — LibreOffice is the one well-supported install that completes this picture. OnlyOffice's Document Builder is a credible second recalculation/editing engine (verified: it opens existing files and saves them back through the ONLYOFFICE engine, free under AGPL for personal use), though it is more of a scripting engine than a mature agent tool surface yet ([12], [13]).

**Excel-side add-ins are real but locked to Excel somewhere:** Microsoft 365 Copilot and Anthropic's Claude for Excel are both generally available and genuinely capable (Claude for Excel is GA on Claude Pro/Max/Team/Enterprise plans [15]), and GPT for Excel (now "Autosheet") can even use custom/self-hosted API endpoints, which is the realistic door for your GLM keys inside Excel [16]. But every one of them requires Excel itself on Windows, macOS, or the web — they do nothing for your Linux desktop except when you're in your Windows lane or a browser.

**Recommendation in one line:** keep Hermes for *creating* new spreadsheets from scratch (that's its strength), move all *modification* of existing workbooks to a cell-level edit lane (openpyxl via MCP or script) with a mandatory recalculate-and-verify step, keep a copy-then-edit-then-diff guardrail, and structure recurring workflows as *template + agent fills data cells only*. Details and the concrete "start here" setup are in section 9.

---

## 1. Root cause: why CSV-based generation damages spreadsheets

**The CSV round-trip is lossy by design.** A `.csv` file stores a flat grid of text. An `.xlsx` file is a ZIP package of XML parts holding, separately: formulas, cached formula results, cell and number formatting, themes, multiple sheets, defined names, tables, charts (with their own cached data), pivot tables (with their own data caches), images, shapes, comments, data validation, conditional formatting, and optionally VBA macros ([1]). There is no way to express any of that in CSV. So when a tool or agent uses CSV as its working format for an existing workbook, the practical sequence is:

1. **Export** the workbook to CSV → everything except one sheet's *displayed values* is discarded.
2. Agent modifies values in the CSV.
3. **Rebuild** a new workbook from the CSV → the new file has no formulas (or formulas the model re-invented from what it saw), no styles, no other sheets, no charts, no pivots, no names.

Every "edit" is therefore a **whole-file rewrite with a lossy intermediate**, which is precisely the behavior you observed: "Hermes completely rewrites spreadsheets and then I find I have to fix things that were already fixed." The rewrite is nondeterministic (the model regenerates content), so previously-correct formulas and formatting come back wrong or missing. Nothing about this is a limitation of the model itself — Anthropic's own engineering guidance for spreadsheet skills is built entirely around avoiding it: use openpyxl to edit cells in place, "write only there [the designated input cells], and leave every existing formula untouched" ([2], "Editing an existing file: match its conventions exactly").

Library-level tools have the same class of hazard when they don't round-trip faithfully: openpyxl's documentation warns plainly that it "does currently not read all possible items in an Excel file so shapes will be lost from existing files if they are opened and saved with the same name" ([1] — tutorial warning), and its `data_only=True` read mode "is destructive if you save" because the loaded workbook has no formulas left ([2]). This is why the lane choice matters, not just the format choice.

**Practical corollary:** CSV→xlsx is fine for *creating brand-new* files (nothing to preserve — this is why Hermes is good at creation and bad at modification). It should simply never touch an existing workbook.

---

## 2. Direct xlsx manipulation lanes (edit-in-place)

All of the following run natively on Linux, work on the real `.xlsx`, and edit at cell/range granularity. None of them recalculates formulas (see section 3).

| Tool | Language | Formula preservation | Style preservation | Recalculation | Charts / pivots | Maturity & Linux |
|---|---|---|---|---|---|---|
| **openpyxl** 3.1.5 | Python | Yes (stored as strings) | Yes (cell styles, number formats) | No | Creates charts; **shapes lost on round-trip** [1]; pivot read-support only | The de-facto standard; installed on this rig (3.1.5) |
| **exceljs** | Node.js | Yes (formula objects, stored not computed) | Yes (fonts, fills, borders, rich text, number formats, conditional formatting [7]) | No | Creates; rich but partial round-trip | Very widely used; Linux native |
| **xlsx-populate** | Node.js | Yes; explicit design goal: "keeping existing workbook features and styles in tact" [5] | Yes (supported-styles subset) | No | Images yes; charts not supported | Stable but **last upstream push 2024-03** [5] |
| **SheetJS (community)** | JS/TS | Reads/writes; no evaluation (evaluation is Pro) | Community is data-focused; **styling/images/graphs/pivots are Pro features** [6] | No (Pro evaluates) | Pro only | The most battle-tested *parser*; free tier best for reading/extraction |
| **excelize** | Go | Yes (stored; workbook `CalcMode` property settable: manual/auto/autoNoTable [10]) | Yes (extensive styling API) | No | Creates charts, pictures, pivot tables; high-compatibility rewrite | Very active (21k stars); Linux native |
| **umya-spreadsheet** | Rust | Yes | Yes (style read/edit) | No | Charts/images read & edit ("still might be inconvenient" for drawings) [4] | Active (4.x beta); MIT; WASM-capable |

**The packaged agent lane — excel-mcp-server (haris-musa):** worth calling out separately because it is openpyxl *wrapped in exactly the guardrails you want*. Version 2.x is a single `uvx excel-mcp-server stdio --allow-dir <folder>` command that exposes cell/range reads and writes, formatting, tables, charts, real PivotTables (built from a snapshot; Excel refreshes them on open), slicers, goal seek, and a formula-audit engine, with: **atomic saves** ("never leave a half-written file"), folder confinement, read-only mode, formula-safety checks, and an explicit preservation contract: "Editing a workbook keeps what the tools cannot change: sparklines, extended conditional formats and validation, slicers and timelines, newer charts, threaded comments, shapes, form controls, linked data types and custom XML stay as Excel saved them" ([8]). Runs on Windows/macOS/Linux; needs no Excel. This is the strongest turnkey candidate on your rig today.

**Excel via COM (the genuine-Excel lanes)** — `negokaz/excel-mcp-server` (Node; cross-platform read/write of values, formulas, and formatting, with Windows-only *live editing* of a real open Excel instance [9]) and `sbroenne/mcp-server-excel` (.NET; 437 operations driving real Excel COM — Power Query, DAX, VBA, pivot refresh, recalculation — explicitly "Requires Windows … not intended for Linux" [11]). These are the fidelity ceiling, but they need Excel on Windows; on this rig they'd only apply inside a Windows VM/dual-boot session.

---

## 3. The recalculation problem (read this one twice)

**The mechanic:** an `.xlsx` stores each formula twice — the formula text *and* the last-computed value ("cached value") Excel wrote when it last saved. All the edit-in-place libraries preserve or replace formula text but **never compute anything**. openpyxl's docs state it directly: `data_only` "controls whether cells with formulae have either the formula (default) or **the value stored the last time Excel read the sheet**" ([1]); Anthropic's skill says it bluntly: "openpyxl writes formulas as strings **with no cached values**. Until you recalculate, every formula cell reads back as `None` to anything reading cached values" ([2]).

**What breaks if you skip it:**

- Every tool that reads *values* (pandas, previews, another agent pass with `data_only=True`, Hermes reading the file) sees **stale or missing numbers** with no warning.
- Excel or OnlyOffice will recalculate *when they open the file and the user edits something*, but a file handed to a colleague or consumed programmatically can carry wrong totals indefinitely.
- **Chart caches and pivot caches** are separate stored snapshots. They do not refresh because a cell changed; charts redraw and pivots refresh only when a real engine recalculates/refreshes them (Excel refreshes haris-musa-created PivotTables "from the live source data" on open [8]). A library-edited workbook with new numbers can still chart the old numbers until a real engine touches it.
- The **fix used in practice**: force a full recalculation on open (`openpyxl` can set the workbook's `fullCalcOnLoad` calculation property [3]) and/or run a real engine headlessly. The canonical Linux pattern is LibreOffice headless executing a tiny Basic macro — `ThisComponent.calculateAll()` then `store()` — which is precisely what Anthropic's `recalc.py` does, including scanning the result for `#REF!/#NAME?/#VALUE!`-class errors and reporting a per-cell error summary ([2]).

**LibreOffice-specific recalc trap:** LibreOffice's default for xlsx is *not* to recalculate on load — the config schema sets `OOXMLRecalcMode = 1` ("Recalc never"; 0 = always, 2 = ask) ([14]). So a naive `soffice --convert-to xlsx` does **not** refresh stale values; you need the macro path (or set the option). Anthropic's skill adds a second LibreOffice reality: its function coverage lags Excel — e.g. `XLOOKUP`/`FILTER`/`SORT` "cannot be evaluated under *any* prefix", and a function it can't parse comes back `#NAME?` baked into your file — so the skill recommends Excel-2007-era functions (`SUMIFS`, `INDEX/MATCH`, `IFERROR`, `SUMPRODUCT`) for anything that will be recalculated on Linux ([2]).

**Pure-Python alternative:** the `formulas` library (PyPI) parses and computes an entire workbook in Python and can write calculated values back ([17]) — useful for validation/preview, but its Excel coverage is partial; treat it as a checker, not the authority.

---

## 4. The LibreOffice headless lane

*(Not installed on your rig today — verified: no `soffice`, no `/usr/lib/libreoffice`. Everything below is what an install would add; it's the standard Arch package or `libreoffice-fresh`.)*

**Pros**
- A **real recalculation engine** — the only free one that fits this rig's gap (section 3), via the headless macro pattern proven in Anthropic's `recalc.py` ([2]).
- **Headless conversion** as a Swiss-army knife: `libreoffice --headless --convert-to pdf/xlsx/ods ...` ([18]).
- **UNO scripting**: full programmatic control (open, edit, calculateAll, save as xlsx). On Arch the convenient form is `unoserver`/`unoconvert` (AUR `python-unoserver`), a persistent LibreOffice listener built for exactly this automation ([18]). Macro recording and Basic scripting are also available.
- Free, mature, cross-platform.

**Cons (honest)**
- **Style-fidelity drift on xlsx round-trips.** LibreOffice re-serializes the file through its own filter; complex formatting, conditional-format edge cases, charts, and pivot layouts can shift subtly. This is the well-known cost of using a different engine to write Excel files — acceptable for data-centric edits, risky for pixel-perfect workbooks.
- **Function coverage lags Excel** — post-2007 functions need `_xlfn.` prefixes and several modern ones don't evaluate at all ([2]).
- Recalc-on-load defaults to "never" for xlsx ([14]) — the macro (or option change) is mandatory, not optional.
- Headless quirks: can't open password-protected files; needs workarounds with some window managers; concurrent CLI invocations need `unoserver` or separate user profiles ([18]; `recalc.py` uses an isolated `-env:UserInstallation` profile per run [2]).

**Role in the recommended stack:** not the editor — openpyxl-class tools are better editors. LibreOffice is the **recalculator and error-checker**: edit with openpyxl → recalc+verify with headless LibreOffice → done. This exact division of labor is what Anthropic's own production spreadsheet skill implements ([2]).

---

## 5. The OnlyOffice lane (your preferred editor)

You already run ONLYOFFICE Desktop Editors on this rig (verified: `/usr/bin/onlyoffice-desktopeditors`, engine files under `/opt/onlyoffice/desktopeditors/`, including the internal **x2t converter** at `/opt/onlyoffice/desktopeditors/converter/x2t`). Here's what is scriptable, verified today:

**ONLYOFFICE Document Builder** — the official headless scripting engine, and the direct answer to "is there native agentic tooling in OnlyOffice":
- Cross-platform (Windows/Linux/macOS); scripts in JavaScript executed by the ONLYOFFICE engine; official **Python wrapper** (`pip install document-builder`, v10.0.0.170) ([13]).
- **Editing existing files is supported**: the documented flow is `builder.OpenFile("file.xlsx")` → modify through the ONLYOFFICE **Office API** ("the same API used by the editors' macros and plugins") → `builder.SaveFile("xlsx", ...)`. `ExecuteCommand` runs JavaScript inside the engine for bulk edits and can return values ([13]). Spreadsheets (XLSX/XLS/XLSM-family, ODS, CSV, XLTX) are first-class supported formats ([13a]).
- **License:** the repo is **AGPL-3.0**, and ONLYOFFICE describes it as dual-licensed with commercial use requiring a paid license ([12]). For your personal use: free. **No separate license tier is needed for xlsx editing specifically.**
- Honest assessment: it's a *scripting engine*, not an agent surface. It has no cell-read API returning JSON the way an MCP tool does; an agent would write a `.docbuilder`/Python script per task. Recalculation: the ONLYOFFICE engine computes formulas in its editing model, but I could **not verify today** how a load→save round-trip handles recalculation or cached values — flagged in section "Unverified". Practically you'd combine it with the `fullCalcOnLoad` property or verify diffs.
- **x2t** is the internal conversion engine behind Desktop Editors (present on your rig); it converts between formats but is an internal, undocumented interface — usable by wrappers, but I don't recommend building on it.

**Desktop Editors itself (GUI)**: macros are JavaScript against the same Office API ([13b]) — a nice place for *you* to codify a repetitive edit by hand, but there is no official headless macro execution for Desktop Editors.

**Community agent bridges for Desktop Editors** (both young, treat as experimental):
- `maximlefebvre/onlyoffice-claude-bridge` — an OnlyOffice plugin + local MCP server; an agent edits the **open document live** (cell read/write/format, sheets, charts; `run_script` for any of the ~2,600 Office API methods) ([19]). Because the *editor itself* does the work, recalculation and fidelity are handled by the real engine. Currently packaged as a Claude Code plugin (works with a Claude subscription, no API key), but the MCP server is plain Node — usable from pi/GLM too.
- `camilin7483/mcp-onlyoffice` — Go/Python MCP with a Desktop plugin bridge (port 2021) plus openpyxl-based document creation ([20]). Low adoption (3 stars).

---

## 6. MCP servers (what exists, what it actually does)

Verified today, with maintenance status; "in-place" means the server edits the existing file rather than rebuilding it:

| Server | What it really is | Edits in place? | OS | Status |
|---|---|---|---|---|
| **haris-musa/excel-mcp-server** (4,278★, pushed 2026-11-04) | openpyxl + formula engine + charts/pivots/slicers; atomic saves; read-only mode; folder confinement | **Yes** (section 2 details [8]) | Win/mac/**Linux** | Very active; **runs on this rig via `uvx` (uv already installed)** |
| **negokaz/excel-mcp-server** (1,046★) | Node; values/formulas/formatting read-write; Windows-only *live* Excel editing + screen capture | Yes (file mode); live mode = real Excel | Cross (file), Windows (live) | Maintained (last push 2025-07) [9] |
| **sbroenne/mcp-server-excel** (848★, active) | Real Excel via COM: recalculation, Power Query, DAX, VBA, pivots | Yes, via Excel | **Windows only** | Very active [11] |
| **harshithb3304/libre-office-mcp** (17★) | Docker; **LibreOffice is the engine**; 51 Calc tools; atomic saves; no macros run | Yes (LO re-saves the file) | Linux (Docker) | Active (2026-10) [21] |
| **quazardous/nelson-mcp** (41★) | LibreOffice *extension*: MCP server inside the running GUI app; ~50 Calc tools; `=PROMPT()` in cells | Yes (live in open doc) | Wherever LO runs | Active (2026-11) [22] |
| **ONLYOFFICE/docs-mcp** (official) | MCP for ONLYOFFICE **Document Server** (the self-hosted web suite) — not Desktop Editors | Via Docs server | Server-side | Official; early [23] |
| **camilin7483/mcp-onlyoffice** (3★) | Go+Python creator/editor + Desktop plugin bridge | Partly; engine = openpyxl | Linux-capable | Experimental [20] |
| **maximlefebvre/onlyoffice-claude-bridge** | Desktop Editors plugin + local MCP; live editing of open docs | Yes (live, real engine) | Linux-capable | New/personal project [19] |
| **PSU3D0/spreadsheet-mcp** | umya-spreadsheet-based analysis/editing | Yes | Rust, cross-platform | Community [24] |

**Fit with your rig:** pi workers support MCP servers natively (`pi mcp add …` for stdio and HTTP servers; per-command env vars supported) ([25]) — so the haris-musa server runs *inside your pi workers* today with GLM as the model, and the same server can be attached to Claude Code. Hermes could consume the same MCP server if its runtime supports MCP.

---

## 7. Excel-side agent surfaces (all require Excel somewhere)

**The OS constraint first, honestly:** you're on Linux/Omarchy. Every add-in below lives *inside Excel*, which means Excel on Windows, macOS, or the web. Your dual-boot/Windows lane (and Excel Web in a browser) is the only place they can run. None of them help a Linux-native agent directly — their value to you is as the *fidelity ceiling* when you deliberately work inside Excel.

**Microsoft 365 Copilot in Excel** — GA; included with M365 Copilot licensing. Verified capabilities: add/rename/delete worksheets; insert and modify cell values and ranges; conditional formatting; create/edit charts, PivotTables, and shapes; build dashboards and templates; identify insights ([26]). It uses real Excel, so recalculation/pivot refresh are native. Needs an M365 Copilot license; not available on Linux.

**Claude for Excel (Anthropic add-in)** — **generally available on Claude Pro, Max, Team, and Enterprise plans** (a Claude subscription, not an API key) ([15]). Verified capabilities: question answering with cell-level citations; "adjust assumptions while **keeping formula relationships intact**"; error debugging with root causes; generate models or fill templates; multi-tab workbooks; connectors for external data. Verified **limitations**: unsupported capabilities are **data tables and macros/VBA operations**; does not run on Excel 2016/2019 perpetual, iPad (no SharedRuntime), Android, or older M365 builds ([15]). **Models:** the add-in is part of the Claude product — it sends your conversations and workbook content to Anthropic, and there is **no documented option to point it at other providers** such as Z.AI GLM ([15]; the "Models available" section of the docs page is JS-rendered and I could not extract its exact wording — flagged). So: Anthropic-only, subscription-gated.

**GPT for Excel → "Autosheet" (Talarian)** — the rebrand is verified: "GPT for Work is now Autosheet… an AI agent that works inside Google Sheets and Microsoft Excel… runs on models from several AI providers, not only OpenAI's" ([16a]). Its Excel product advertises "**Configure custom API keys and endpoints**" and "models from OpenAI, Azure, Anthropic, Perplexity, xAI or Deepseek, **or self-hosted LLMs**" ([16b]). Self-hosted/custom endpoints are exactly the shape of Z.AI's OpenAI-compatible API (verified: Z.AI documents calling `https://api.z.ai/api/paas/v4/chat/completions` with the **OpenAI Python/Node/Java SDKs**; current flagship example model `glm-5.3`) ([27]). **Flag:** "custom endpoint" + "OpenAI-compatible" strongly suggests GLM works inside Excel through Autosheet, and Z.AI's endpoint is SDK-compatible — but the add-in's exact endpoint-config mechanics are behind its paid product docs, which I could not verify from public pages. Commercial add-in (paid plans). There is also an Autosheet **MCP** server product emerging ([16a]).

**Python in Excel** — orthogonal but relevant to your "I'll learn what's needed" streak: Python runs *inside* Excel cells (`=PY()`), on Windows/Web/Mac with a qualifying M365 subscription; premium compute needs a paid add-on ([28]). `sbroenne/mcp-server-excel` can even run `=PY()` cells via COM ([11]).

---

## 8. Hybrid patterns for reliability (what mature practitioners actually do)

1. **Workbook-as-interface.** Formulas, styles, and layout are *human-owned*; the agent owns only designated data cells. Anthropic's skill states the discipline: find the designated input cells first, "write only there, and leave every existing formula untouched" ([2]). For your own templates, mark input cells visually (the financial-modeling convention the same skill uses: blue text = inputs, black = formulas) so both you and the agent can see the boundary.
2. **Copy → edit → verify-unchanged → replace.** Never edit the only copy. The robust variant on Linux: snapshot the *semantic* state of untouched regions before the edit (cell formulas + styles + values via openpyxl), apply the edit, re-read, and **diff region by region**; byte checksums of the whole file will always change (xlsx re-serializes), so compare content, not bytes. Report the diff, not just "done". The haris-musa server institutionalizes half of this: atomic saves so a failed edit never leaves a half-written file, plus "never silently overwrites an existing workbook" ([8]).
3. **Template + data split.** For recurring workflows (expense reports are the canonical case): a hand-built xlsx template with formulas/styles you own, and the agent's job is *fill designated cells + save-as-new-file*. The creation-from-scratch path (where Hermes is strong) becomes a one-time template build; every run after that is a controlled fill. Anthropic's skill even requires a "legend naming which cells to edit" plus one example row in workbooks built for humans to fill ([2]).
4. **Staged review.** Agent proposes (read-only pass produces the intended diff) → you approve → tool applies. The haris-musa server's `--read-only` mode exists precisely to make the "propose" stage safe ([8]); the same read→diff→apply loop is easy with openpyxl directly.
5. **Mandatory recalc-and-check gate.** After every edit that touches inputs to formulas: recalculate headlessly and scan for error values — the exact contract of Anthropic's `recalc.py` ("Zero formula errors. Never ship while `recalc.py` reports `errors_found`… A green recalc proves your formulas *evaluate*, not that they are *right*") ([2]). Add 2–3 spot checks of expected numbers before trusting a build-out.
6. **Never round-trip through CSV.** CSV only as an *import format into* a controlled lane (the haris-musa server even ships `import_csv` with Excel-grade typing rules and formula-escaping so pasted text can't execute as formulas [8]) — never as the editing intermediate for an existing workbook.
7. **Confinement and least-privilege.** Folder allow-lists, read-only mode by default, macro execution off (LibreOffice MCP lane: "Macros never run" [21]; haris-musa: VBA writing opt-in, never runs macros [8]).

---

## 9. Recommendation matrix and "start here"

**By workflow type:**

| Workflow | Recommended lane | Why / honest failure modes |
|---|---|---|
| **Expense reports** (recurring, template-shaped) | **Template + fill** (section 8.3): your xlsx template + openpyxl/excel-mcp-server writes receipts/data into input cells only → recalc gate | Failure modes: model mislabels a category (spot-check totals); recalc gate catches broken formulas; dates need explicit format handling |
| **Modify an existing workbook** ("change B7, add a column") | **Edit-in-place** (openpyxl / excel-mcp-server), never CSV; copy→diff guardrail | Failure modes: openpyxl drops shapes on round-trip [1]; wide structural edits (insert rows crossing pivot/array formulas) are where haris-musa v2 explicitly refuses or needs care [8] |
| **Create new spreadsheets from scratch** | Hermes (CSV→xlsx) is fine here, or excel-mcp-server/openpyxl for anything with formulas | No preservation risk when nothing exists to preserve |
| **Analysis on existing files** (read-only Q&A) | haris-musa `--read-only`, or its built-in formula engine / `formulas` lib for values without a spreadsheet install | Values come from cache or its ~260-function calculator; unsupported functions returned as null, never guessed [8] |
| **Anything needing real-Excel fidelity** (VBA, Power Query, pivot *refresh*, data tables, exotic functions) | Excel + Claude for Excel / M365 Copilot / Autosheet in your **Windows or web Excel** lane; sbroenne COM server if scripting Windows | Nothing on Linux replicates the Excel engine; this remains the ceiling |

**Start here — minimal reliable setup on this rig (Linux + OnlyOffice + pi + GLM), no purchases:**

1. **Editing lane:** `excel-mcp-server` in your pi workers: `pi mcp add excel -- uvx excel-mcp-server stdio --allow-dir /home/jason/Work/spreadsheets` — `uv`/`uvx` are already installed on this rig (verified); the server self-installs via uvx on first run. Same server attachable to Claude Code later ([8], [25]).
2. **Recalculation gate:** install LibreOffice (`libreoffice-fresh`, standard Arch package — *requires your say-so since it's an install*) and adopt Anthropic's `recalc.py` pattern (LibreOffice headless + `calculateAll()` macro + error scan) as the mandatory post-edit step ([2], [14]).
3. **Guardrails:** copy-before-edit + semantic diff of untouched ranges; read-only mode for exploration; folder confinement ([8], section 8).
4. **Template program:** convert your recurring expense-report layout into a template with blue-input/black-formula convention; agents only fill inputs ([2], section 8).
5. **OnlyOffice's role:** stays your human editor (it is not lost — the Desktop plugin bridges and Document Builder are the growing agent doors [12], [13], [19]); optionally trial `document-builder` (pip) for OnlyOffice-engine scripting where you want OnlyOffice fidelity instead of LibreOffice's.

**What this stack still cannot do (vs. Excel-on-Windows):**
- No **genuine Excel recalculation** on Linux — LibreOffice computes, with its function-coverage limits ([2]); Excel-only functions and behaviors can differ.
- No **pivot-cache refresh, Power Query refresh, DAX/Data Model, VBA execution, data tables** — those require Excel (COM lanes) or the in-Excel add-ins ([11], [15]).
- Chart/pivot *caches* only refresh when a real engine or Excel touches the file (section 3); the practical mitigation is the recalc gate plus opening in OnlyOffice/Excel when caches matter.
- openpyxl-class lanes **drop shapes** and have partial fidelity on exotic content ([1]) — the haris-musa preservation contract covers a lot of it ([8]), but pixel-perfect human workbooks still deserve the copy→diff guardrail.

---

## Verification limits (flagged, as of 2026-11-05)

- **Could not verify today:** the exact wording of Claude for Excel's "Models available" docs section (JS-rendered page); Autosheet's exact custom-endpoint configuration UI (paywalled product docs); how OnlyOffice Document Builder / x2t handle recalculation and cached values on an xlsx→xlsx round-trip; LibreOffice/UNO binding specifics for the exact Arch package split at install time. All are marked inline where they matter.
- **Environment blocks:** web.archive.org is blocked on this network (AT&T filter), which prevented checking historical versions of moved pages (e.g. Anthropic's original announcement URL now 404s; the live docs page was used instead).
- **Local rig facts verified directly:** OnlyOffice Desktop Editors installed with x2t at `/opt/onlyoffice/desktopeditors/converter/x2t`; LibreOffice absent; `openpyxl` 3.1.5 present in system Python; `uv`/`uvx` present.

## Sources

[1] openpyxl tutorial — data_only semantics, keep_vba, shapes-lost warning: https://openpyxl.readthedocs.io/en/stable/tutorial.html
[2] Anthropic official xlsx skill (SKILL.md) and recalc script: https://github.com/anthropics/skills/blob/main/skills/xlsx/SKILL.md and https://github.com/anthropics/skills/blob/main/skills/xlsx/scripts/recalc.py
[3] openpyxl workbook calc properties (fullCalcOnLoad): https://openpyxl.readthedocs.io/en/stable/api/openpyxl.workbook.properties.html
[4] umya-spreadsheet (Rust): https://github.com/MathNya/umya-spreadsheet
[5] xlsx-populate (Node): https://github.com/dtjohnson/xlsx-populate ; agent skill precedent: https://github.com/zgldh/xlsx-populate-skill
[6] SheetJS community vs Pro: https://github.com/SheetJS/sheetjs and https://sheetjs.com/pro
[7] exceljs (Node) features incl. styles/conditional formatting/defined names: https://github.com/exceljs/exceljs
[8] excel-mcp-server (haris-musa) v2 README — preservation contract, safety, limits: https://github.com/haris-musa/excel-mcp-server
[9] negokaz/excel-mcp-server README: https://github.com/negokaz/excel-mcp-server
[10] excelize (Go) + CalcMode property: https://github.com/xuri/excelize and https://pkg.go.dev/github.com/xuri/excelize/v2
[11] sbroenne/mcp-server-excel (Windows COM): https://github.com/sbroenne/mcp-server-excel
[12] ONLYOFFICE Document Builder repo (AGPL-3.0, dual license, features): https://github.com/ONLYOFFICE/DocumentBuilder ; product page: https://www.onlyoffice.com/document-builder.aspx
[13] document-builder Python wrapper (OpenFile / ExecuteCommand / SaveFile / Office API): https://pypi.org/project/document-builder/
[13a] Document Builder supported formats: https://api.onlyoffice.com/docs/document-builder/get-started/supported-formats/
[13b] ONLYOFFICE macros docs (JS, per-editor incl. Spreadsheet editor): https://api.onlyoffice.com/docs/macros/get-started/overview/
[14] LibreOffice OOXMLRecalcMode schema (default 1 = "Recalc never"): https://github.com/LibreOffice/core/blob/master/officecfg/registry/schema/org/openoffice/Office/Calc.xcs
[15] Claude for Excel docs (GA plans, features, limitations, data handling): https://claude.com/docs/office-agents/excel ; tutorial: https://academy.claude.com/tutorials/getting-started-with-claude-in-excel
[16] GPT for Excel / Autosheet: https://gptforwork.com/gpt-for-excel ; rebrand announcement: https://gptforwork.com/gpt-for-work-is-becoming-autosheet
[17] formulas (Python recalculation library): https://pypi.org/project/formulas/ / https://github.com/vinci1it2000/formulas
[18] Arch Wiki — LibreOffice (headless convert, unoserver/unoconvert): https://wiki.archlinux.org/title/LibreOffice
[19] onlyoffice-claude-bridge (Desktop plugin + MCP, Office API breadth): https://github.com/maximlefebvre/onlyoffice-claude-bridge
[20] mcp-onlyoffice (Go/Python + Desktop plugin bridge): https://github.com/camilin7483/mcp-onlyoffice
[21] libre-office-mcp (Docker, LibreOffice engine): https://github.com/harshithb3304/libre-office-mcp
[22] nelson-mcp (in-LibreOffice MCP extension): https://github.com/quazardous/nelson-mcp
[23] ONLYOFFICE docs-mcp (official, Document Server): https://github.com/ONLYOFFICE/docs-mcp
[24] spreadsheet-mcp (umya-based): https://github.com/PSU3D0/spreadsheet-mcp
[25] pi coding agent — MCP server support: https://github.com/earendil-works/pi (docs/mcp.md)
[26] Copilot in Excel (capabilities, licensing): https://support.microsoft.com/en-us/excel/copilot/get-started-with-copilot-in-excel
[27] Z.AI API — OpenAI SDK compatibility, endpoint, glm-5.3: https://docs.z.ai/api-reference/introduction
[28] Python in Excel (platforms, licensing): https://support.microsoft.com/en-us/excel/python/introduction-to-python-in-excel
