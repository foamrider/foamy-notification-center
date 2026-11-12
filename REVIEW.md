# Foamy review guide

Review for correct behavior, clear ownership, bounded resource use and the
smallest design that meets the agreed requirements. Remove unnecessary
implementation paths while preserving requested behavior. Defensive programming
should make failures explicit and recovery predictable.

This is the shared review standard for foamy-kit and every Foamy plugin.
The canonical file lives in [foamy-kit](https://github.com/foamrider/foamy-kit).
`sync.sh` copies it to each plugin root, records its checksum in
`foamy-kit.lock` and keeps a pointer to it in the plugin's `AGENTS.md`.
Change it in foamy-kit, then sync; do not edit plugin copies. Plugin-specific
rules belong in the plugin's README or `AGENTS.md`. UI rules live in
[DESIGN.md](https://github.com/foamrider/foamy-kit/blob/main/DESIGN.md).

## Blocking checklist

A change is not ready while any of these holds:

1. Requested behavior or an agreed acceptance criterion is removed, disabled or narrowed without the user's agreement.
2. The change fails a check the repository already runs, or adds a suppression, baseline entry or exclusion to pass it.
3. External data reaches a sink (argv, a path, markup, a URL, an image, memory) without validation and bounds.
4. A process, timer, request or queued operation can fail to finish, finish twice or apply a stale result.
5. A failed lock, write, authorization or launch is reported as success or as empty data.
6. A secret can reach argv, logs, errors, fixtures, screenshots or repository files.
7. A file the user may have edited is replaced or deleted without proving ownership at the moment of mutation.
8. Privileged or system-changing work runs without an explicit user action.
9. Changed behavior has no test that fails without it, and no stated reason a test is impractical.
10. A shipped native binary lacks public provenance for the exact reviewed inputs.
11. New code duplicates an Omarchy command, host service or kit component that already fits, without a demonstrated gap.
12. A kit-owned file was edited in a plugin instead of in foamy-kit.

## Severity

- **Blocker**: an item above, or a reachable correctness, security,
  data-loss or lifecycle defect on a supported configuration. Fix it, or get
  the user's explicit acceptance, before merge.
- **Should-fix**: a real defect or gap with limited reach, such as missing
  tooling, an untested non-critical branch, unclear state ownership or an
  unneeded branch. Fix it in this change when it is related and cheap;
  otherwise record a follow-up.
- **Suggestion**: naming, structure or style that no configured tool
  enforces. Never blocks. Once only suggestions remain, stop requesting
  changes.

## Review order

1. Identify the behavior, supported environment and exact revision. Read the
   applicable instructions, architecture, tests and earlier review findings.
   Inspect `git status`, staged and unstaged diffs, and `git worktree list`;
   an active worktree may contain relevant unfinished work. Do not overwrite,
   stage or treat another worktree's changes as a verified fix.
2. Trace the real entry point through state, I/O and UI. Decide whether the
   behavior belongs here before reviewing its implementation details.
3. Run the repository's deterministic checks ([section 3](#3-run-deterministic-checks)).
   Inspect their configuration, scope and failures, then review the
   remaining design and trust boundaries.
4. Exercise the changed behavior and a relevant failure path. Check the actual
   host boundary where mocks or static tools cannot establish correctness.
5. Report findings with a severity and the validation evidence. Recheck
   affected paths after fixes, including earlier findings that a refactor
   could reintroduce.

Scale the review to the change. Documentation-only edits need document and
link checks, not UI tests or native rebuilds. For a release or marketplace
submission, include the complete shipped runtime, shared code, helpers,
dependencies and installation/removal paths in scope.

## 1. Justify the behavior and reduce complexity

- State the concrete user action or failure being addressed, its expected
  result and the evidence that it occurs on a supported configuration.
- Preserve explicit feature requests and agreed acceptance criteria, even
  when implementation is difficult. Complexity alone does not justify deleting,
  disabling or narrowing a requested feature, or calling it unnecessary.
  Push back with concrete evidence of the constraint, risks and maintenance
  cost; compare feasible alternatives and their effect on the requested
  behavior. Obtain the user's agreement before reducing scope. Continue
  independent work while that decision is pending, and record the rationale.
- First inspect the relevant Omarchy command, host service and kit component.
  Prefer that maintained interface when its behavior fits. For example,
  display brightness and text size belong to `omarchy-brightness-display` and
  `omarchy-display-text-size`; a plugin's own DDC discovery loop or text-size
  config writer needs a demonstrated gap in those commands.
- Read the command's implementation or documented contract for the supported
  host: arguments, authorization, exit behavior and side effects. A command
  name alone does not prove suitability. Keep arguments as data and handle
  failures at the caller; reuse does not remove the need for bounds.
- For each workaround, fallback, retry or compatibility branch, identify the
  affected version or capability, its reachable trigger, why the normal
  interface is insufficient, its regression test and the condition for
  removing it. Remove it when the supported path makes it redundant.
- Do not add speculative alternate backends, guessed platform support, options
  or recovery for impossible internal states. A missing optional dependency
  can be a clear unavailable state when that matches the agreed requirements;
  it must not silently replace requested support with an unsupported state.
- Respect the support range the repository's README declares. Do not add
  branches for an unsupported version, and do not remove one the README still
  promises.
- Measure complexity in states, branches, side effects and ownership, not
  line count. Split a module when responsibilities differ; avoid tiny
  wrappers and generic frameworks that make the flow harder to follow.
- Share proven common behavior through the kit. Do not copy a queue, IPC
  adapter or process supervisor into each plugin, or generalize a one-off
  operation before a second real use establishes the shared contract.

## 2. Keep structure and contracts clear

- Follow existing module boundaries and naming. Keep presentation separate
  from parsing/policy and external I/O. Prefer small pure functions for
  transformations and explicit adapters for commands, files and services.
- Give mutable state one owner. Derive values where practical; avoid parallel
  flags that can disagree, duplicated caches and UI-local copies of service
  state. Model valid states and transitions explicitly.
- Define helper requests, responses, errors and size limits at the boundary.
  Validate external JSON before using it. Rust and Python keep their strict
  types; do not hide type failures with unchecked casts or broad suppressions.
- Use the kit's established contracts: `FoamyPrefsQueue` for settings,
  `FoamyMember` for once-per-shell work, `FoamyIpc`/`FoamyPeerIpc` for IPC and
  `FoamyNative` for bundled helpers. Edit canonical kit sources, then sync.
- Keep public behavior and documentation aligned. Remove code, options,
  dependencies and tests made obsolete by the change. Preserve vendored
  sources and generated artifacts according to their owning workflow.
- Add short intent comments for bounds, concurrency, retries, caching and
  lifecycle decisions. Explain why the constraint exists; do not narrate
  assignments or keep a history of abandoned fixes in code.

### JavaScript

Foamy writes JavaScript, not TypeScript. Most of it is loaded by QML
(`.pragma library`, `.import … as Name`), so its imports are namespace objects
that no type checker sees, and the code carries no JSDoc types. A strict
`tsc --checkJs` trial over the plugins' JavaScript produced thousands of
implicit-`any` and unresolved-name errors; the remaining errors sampled were
inference artifacts, not defects. Type checking would cost more than it finds.

- Do not add `// @ts-check`, checker-oriented JSDoc or a TypeScript build step
  without an agreed proposal.
- With no static type checker, types are enforced at runtime: validate shapes
  at each boundary ([section 4](#4-defend-boundaries-and-preserve-invariants))
  and cover the accepted and rejected shapes with tests.
- Lint with Oxlint rather than ESLint when choosing or updating a linter.
  Keep an existing ESLint rule until Oxlint covers it.

## 3. Run deterministic checks

Every repository has one validation command, `tests/validate.sh`, synced
from foamy-kit with its configuration. Run `mise install` once (`mise.toml`
pins the tools), then `tests/validate.sh` on the Omarchy host. It runs every
row of the table below that applies, prints a PASS, FAIL or SKIP line for
each, and returns nonzero on any failure. The synced `checks.yml` workflow
runs `tests/validate.sh --ci` on every push and pull request; `--ci` skips,
with a stated reason, what needs the host (omarchy-plugin-validate, Qt's
qmllint and qmlformat, Quickshell). The repository's own tests run from its
`tests/suite.sh`. AI review or a successful parse does not replace linting.

- Run `tests/validate.sh` and report its summary. A repository that has not
  adopted it yet (no `tests/suite.sh`, unformatted files, no baselines) runs
  every check that exists and reports the missing ones once as a should-fix
  finding, in the first review that finds the gap or an issue, not on every
  change.
- A missing tool or an unsupported parser is a stated validation gap, never a
  passing check; `tests/validate.sh` fails when a pinned tool is missing.
- Once a check is configured, a new failure in it is a blocker.

Use the rows that apply; a QML-only plugin needs no Rust toolchain.

| Source | Target checks |
| --- | --- |
| QML | `qmllint` with the real Qt, Quickshell and host import paths, unused imports as errors (the `qmllint` check of `tests/validate.sh`, baseline in `tests/lint/qmllint-baseline.txt`); the kit design lint (`check.sh`); `qmlformat` with the shared `.qmlformat.ini`. Run the host harness for dynamic behavior. |
| JavaScript | Oxlint and a formatter check over every JavaScript file, including QML-loaded ones. |
| Python | Ruff lint and format checks, with its complexity rule (`C901`) at a configured threshold; Vulture for dead code, with reviewed dynamic entry points. |
| Shell | ShellCheck, `bash -n` and the repository's formatter check. Quoting and process handling need linting even when `bash -n` passes. |
| Rust helpers | `kit/native/build-native.sh . --test` (format, Clippy and tests); compiler unused-code diagnostics; locked dependencies and the prescribed build/verify workflow when native inputs change. |
| All plugins | `omarchy-plugin-validate <plugin>`, `bash tests/kit-check.sh`, the kit's `check.sh <plugin>`, the relevant tests, and any configured secret or dependency checks. |

- Pin tools and configuration in the developer/CI setup (`mise.toml`,
  `ruff.toml`, `.oxlintrc.json`, `.qmlformat.ini`). Review a new
  dependency's maintenance, license and security before adoption, and obtain
  approval first. Do not install scanners merely to satisfy this table, or
  run an unpinned network download during review.
- `.pragma` and `.import` lines are QML directives, not JavaScript. Confirm the
  JavaScript linter actually parses QML-loaded files; never exclude them
  silently to get a clean run.
- Configure `qmllint` import paths and warning levels deliberately. Missing
  host types are an environment gap, not proof that the file passes. Do not
  silence whole warning categories to hide new defects.
- Run formatters in check mode. Keep formatting migrations separate from
  behavior changes. Do not reformat stamped kit files in a plugin, and do not
  run `cargo fmt --all` across vendored kit code.
- Before deleting code a tool reports as unused, trace production callers
  across QML, JavaScript, IPC and native dispatch, including supported
  variants and external users of kit APIs. JavaScript and Python tools do not
  see QML imports, signal handlers, `qmldir`, manifest entry points or dynamic
  loaders. A test that uses a symbol does not prove production use; an
  unobserved runtime path does not prove dead code. Declare dynamic entry
  points narrowly, with a reason; never mass-delete scanner output or add
  blanket ignores.
- Compare complexity against the base revision with the same configuration.
  Investigate regressions; do not move code into wrappers to lower a score.
  Thresholds belong in repository configuration, with a reason.
- When adopting a tool in an existing repository, record current findings in
  a reviewed baseline and fail on new ones
  (`tests/validate.sh --update-baseline <check>` writes
  `tests/lint/<check>-baseline.txt`; review its diff). Do not silently expand
  the baseline.

## 4. Defend boundaries and preserve invariants

- Treat API responses, device/MPRIS data, notifications, clipboard offers,
  files, settings and helper output as untrusted. Validate type, range, shape,
  count and length at entry. After normalization, let internal code rely on
  that contract rather than repeatedly coercing arbitrary values.
- Use early returns and explicit errors. Distinguish empty data, unavailable
  capability, stale data and failure. Catch expected errors narrowly.
- Use safe defaults for optional preferences, but reject invalid actions,
  paths, identifiers and security state. Fail closed when a required security
  boundary cannot be established, while keeping unrelated features usable.
- Bound time, bytes, item counts, queues, workers and retained diagnostics
  independently. Enforce limits while reading and before expensive parsing
  or decoding; a timeout, or a length check after full buffering, is not a
  memory bound. Define whether overflow rejects the result or returns an
  explicitly partial one; never present truncation as complete.
- Make external writes atomic where required and preserve the previous valid
  state on failure. Cleanup and rollback must not undo a newer successful
  operation. Retry only transient, safe-to-repeat work, with bounded backoff
  and a clear stop condition.

### Process and asynchronous lifecycle

- Classify each process: finite job, owned stream/service, or user-launched
  application. A finite job needs a deadline. An application the user opened
  from the panel outlives the launch job; do not apply the job's deadline to it.
- Give each operation one completion/reset path covering success, nonzero
  exit, failed launch, timeout, cancellation and destruction. In Quickshell,
  a failed start may not emit `exited`; test the actual signals and ensure
  completion happens once. Busy flags and queued work must always settle.
- Stop owned children as well as wrappers. Verify that a timed-out writer
  cannot write a rolled-back value later. Reuse the existing bounded-process
  facilities and choose a deadline that fits the real command's contract.
- Reject stale responses after account, query, settings, leader or component
  changes, using an operation identity or generation where needed. Cancel
  obsolete work; cancellation alone does not prove its last callback cannot
  arrive.
- Serialize writes and auth mutations that share state. Sign-out and token
  refresh must not race to recreate credentials; failure to acquire a
  required lock is an error, not permission to proceed without it.
- Keep polling, helpers and IPC once per shell across monitors. Release
  watchers, timers, subscriptions and owned processes on unload or leader
  change. Gate UI-only work on visible demand; avoid overlapping polls and
  unbounded reconnect loops.

## 5. Review security at the actual sink

- Follow untrusted input all the way to its effect. Use argv arrays, fixed
  executables and validated action/option values. If a shell is necessary,
  keep the script fixed and pass values separately. Check option injection,
  path traversal and symlink behavior as well as shell metacharacters.
- Prefer `Text.PlainText` for external text. Inspect tooltips, notifications,
  menus and host-owned renderers too: Qt AutoText can interpret markup and
  image references even when the main label is safe. If a sink requires
  markup, escape for that sink and bound the text before rendering.
- Plain text alone does not bound a host tooltip's size: the bar's tooltip
  window is sized to its text, with no width, wrap or line limit. Cap
  app-controlled text in lines and characters, with a visible "…", before
  `bar.showTooltip` (`FoamyText.tooltip()`).
- A line-mode `SplitParser` or a `StdioCollector` is not a memory bound:
  Quickshell buffers the whole line or stream before QML sees it, and a
  chunk-mode parser can split a UTF-8 character. Bound the producer instead
  (a fixed `head -c` wrapper, or a helper that reads with a limit).
- Validate URL schemes, origins and redirects for the intended operation.
  Do not forward credentials across origins. Bound delivered and decompressed
  bytes and decoded image dimensions; a remote `Image.source` or an inline
  `<img>` must not bypass the bounded image pipeline.
- Use the established credential store. Review cancellation, refresh,
  account switching and logout, including the next application startup.
- Use private files and directories and safe temporary-file creation. Before
  replacement or deletion, prove the content is still owned and unchanged; a
  name or creation marker is insufficient for a tree users can edit. Preserve
  unknown or modified files and recheck ownership at mutation.
- Keep package installation, service changes and other privileged actions
  explicit user actions within the documented feature. Preserve Omarchy,
  Polkit and systemd authorization; never add background privilege escalation
  or silently change unrelated configuration.
- Review dependencies, enabled features and build workflows as executable
  inputs. Keep CI permissions narrow and untrusted PR jobs away from secrets.
  For shipped native binaries, verify both architecture builds against the
  exact reviewed inputs and the kit's provenance workflow; local hashes alone
  do not establish source-to-binary provenance.
- Ship notices for the code actually linked, including required toolchain
  and runtime notices; do not infer linked dependencies from lockfile
  membership. Attestation proves provenance, not safe runtime behavior.

## 6. Test the behavior

- Cover the agreed acceptance criteria and important production branches
  with meaningful assertions: unit tests for parsing and policy, integration
  tests for component and helper contracts, end-to-end tests for critical
  user flows. A passing unit suite alone does not prove a cross-component
  feature.
- For a fix, add a regression test that reproduces the old failure and fails
  when the fix is removed, where practical. Verify through the real boundary;
  avoid tests that assert implementation text or mirror the same algorithm.
- Exercise success and a relevant unhappy path: failed launch, malformed or
  oversized input, hung producer, cancellation, stale reply, duplicate event,
  lost lock, changed file ownership or unavailable service. Lifecycle changes
  need event-order and recovery coverage, not just the normal exit.
- Cover boundary values and supported variants; use table-driven tests when
  combinations matter. Keep tests isolated and deterministic, with controlled
  events and clocks instead of sleeps. Treat a flaky test as unresolved
  evidence: find the cause rather than rerunning or skipping it.
- Measure line and branch coverage where tooling supports it and report
  uncovered critical paths in changed code. Where coverage tools cannot see
  QML or native boundaries, map each critical behavior to its runtime test.
  Do not lower thresholds, widen exclusions or add assertion-free tests to
  improve a number; coverage supplements behavioral evidence.
- Keep tests for requested behavior unless the user agreed to change that
  behavior.
- Use temporary homes, fake commands and buses, and local fixture servers.
  Never suspend or lock the real desktop, alter real accounts, touch real
  Syncthing data, send notifications or open user dialogs from tests.
- Tests never show anything on the live desktop unless the user opts in
  (`FOAMY_TEST_DESKTOP=1` for that run): render offscreen, keep
  `WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE` and `DISPLAY` out of
  what a test starts, and keep live-compositor tests out of
  `tests/validate.sh` and `tests/suite.sh`. The kit's harness and
  `hostenv.isolate()` refuse a live display without the opt-in.
- For changed UI, inspect populated, empty, loading and error states as
  relevant, plus keyboard focus, narrow layouts, scale, supported themes, RTL
  and reduced motion. Check logs for binding and import errors. Offscreen
  evidence does not prove compositor focus, physical hardware or resume.
- Check the affected performance path: idle work, multi-monitor duplication,
  poll overlap, cache invalidation and bounded memory. Measure when a hot path
  changes; a smaller diff is not proof of lower runtime cost.
- Keep Cargo output outside watched plugin directories. Run the documented
  native test/build/verify sequence when its hashed inputs change, and inspect
  the generated pins and notices. Report unavailable target hardware honestly.

## 7. Write an evidence-based review

Report each finding with its severity, file and line, reachable trigger,
observed or source-proven consequence and a concrete correction. State
assumptions and confidence. Distinguish reproduced failures from static
findings and open questions; a plausible scenario without a reachable path is
not a confirmed vulnerability.

Use a short review record in the PR or response:

```text
Scope: revision/base, dirty worktree changes, supported host and changed flows.
Findings: severity, file:line, trigger, impact, evidence, correction.
Simplification: existing host/kit path used; any retained workaround and why.
Scope decisions: requested behavior preserved; justification and agreement for changes.
Checks: exact commands, tool versions, results, baseline/exclusions and gaps.
Tests: acceptance criteria covered, changed branches, regression evidence, gaps.
Runtime/UI: exercised states and boundaries; what remains unverified.
Disposition: ready, changes required, or incomplete with the specific gap.
```

“No findings” does not mean a complete audit. For a submission, refresh the
target SHA, validation reports, binary evidence and listing claims together.
Keep source validation, commit, push, deployment and observed live behavior
separate.

## Evidence behind these rules

These rules come from specific earlier reviews; the cited defects are not
claimed to remain in current code. Read the full thread and check its target
SHA. Add a row when a review teaches a rule that applies to every plugin, and
remove the row when its rule is retired.

| Evidence | Review lesson |
| --- | --- |
| [HANCORE: Media provenance](https://github.com/omacom/omarchy-plugin-marketplace/issues/14501#issuecomment-6755462397) | Pins and an author's local rebuild do not replace independently verifiable build evidence. |
| [HANCORE: Media tooltip](https://github.com/omacom/omarchy-plugin-marketplace/issues/14501#issuecomment-6765150976) and [Notifications tooltip](https://github.com/omacom/omarchy-plugin-marketplace/issues/13972#issuecomment-6710458899) | Follow metadata to the host's AutoText sink; safe primary labels do not protect a tooltip. |
| [HANCORE: Menu response size](https://github.com/omacom/omarchy-plugin-marketplace/issues/14144#issuecomment-6705753414) and [GitHub clipboard](https://github.com/omacom/omarchy-plugin-marketplace/issues/10938#issuecomment-6100592043) | Bound the transport before the shell buffers the body, not only the parsed value. |
| [HANCORE: Zendesk sign-out race](https://github.com/omacom/omarchy-plugin-marketplace/issues/14297#issuecomment-6765056811) and [lock-error follow-up](https://github.com/omacom/omarchy-plugin-marketplace/issues/14297#issuecomment-6766306405) | Auth mutations need shared synchronization; a failed lock must not become a successful logout. |
| [HANCORE: Syncthing ownership follow-up](https://github.com/omacom/omarchy-plugin-marketplace/issues/8971#issuecomment-5856630260) | Creation markers do not authorize deletion of later user edits. |
| [Google engineering practices](https://google.github.io/eng-practices/review/reviewer/looking-for.html) | Review overall design, concurrency and unnecessary complexity before style; avoid speculative generality. |
| [OWASP input validation](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html) | Validate external data early and distinguish syntactic from semantic validity. |
| [Qt qmllint](https://doc.qt.io/qt-6/qtqml-tooling-qmllint.html) and [qmlformat](https://doc.qt.io/qt-6/qtqml-tooling-qmlformat.html) | Use native QML analysis with correct type information and explicit warning and format settings. |
| [Oxlint](https://oxc.rs/docs/guide/usage/linter.html), [Ruff](https://docs.astral.sh/ruff/), [Vulture](https://github.com/jendrikseipp/vulture), [ShellCheck](https://github.com/koalaman/shellcheck), [Clippy](https://doc.rust-lang.org/clippy/) | Match checks to the source language; review dynamic entry points and suppressions. |
