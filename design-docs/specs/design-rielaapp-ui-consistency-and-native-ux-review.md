# RielaApp UI Consistency and Native macOS UX Review

Status: review-findings design draft (specification only; no implementation
ships with this document)

This design documents deficiencies found in a UI/UX review of RielaApp and
specifies improvements for each. The guiding principle throughout is:
**RielaApp panes must behave and look like macOS System Settings and other
first-party macOS apps** (Mail, Finder, Xcode preferences). Where the app
invents its own pattern today, this design replaces it with the closest
native convention.

The review has two layers:

- **R1–R4**: four user-reported failures, plus **A1–A6** found while
  investigating them.
- **B1–B13**: a journey-wide review simulating a user from first launch
  through daily operation (onboarding → creating instances → running and
  observing → editing configuration → recovering from failures).

The scope is the macOS RielaApp targets:

- `Sources/RielaApp` (windows, panes, prompts, assistant panel, viewer)
- `Sources/RielaAppSupport` (assistant settings model, state persistence —
  only where a UI change needs a small support-surface addition)
- `Sources/RielaAdapters`, `Sources/CodexAgent` (assistant error
  classification — R4 only)
- `Tests/RielaAppSupportTests` (regression tests)

This design builds on and does not revert
`design-docs/specs/design-rielaapp-workflow-instances.md` and
`design-docs/specs/design-rielaapp-ux-onboarding-improvements.md`. The
Source/Instance mental model and the shared Settings-style row treatment
defined there remain in force; several findings below are places where the
implementation has not yet caught up with those specs.

## Problem — user-reported failures

### R1. Workflow source detail and instance detail are visually inconsistent

Both detail panes are built from the same shared row system
(`rielaAppSettingsSection`, `settingRow`, `actionRow` in
`Sources/RielaApp/RielaAppSettingsRowStyle.swift` and
`DaemonWorkflowWindowController+Rows.swift`), but they diverge in structure:

- The instance detail pane shows two bold section headers, `Current Settings`
  and `Manage Instance`, built by a custom `detailHeaderRow()` helper
  (`DaemonWorkflowWindowController+DetailView.swift:6-11, 160-171`). The
  workflow source detail pane has **no section headers at all** — its summary
  and action groups flow into the scroll view unlabeled
  (`DaemonWorkflowWindowController+SourcesPane.swift:299-320`).
- The header labels themselves are bare `NSTextField`s in a plain
  `NSStackView` with no relationship to the grouped-section background
  treatment used by the rows beneath them
  (`RielaAppSettingsRowStyle.swift:384-483`). System Settings renders section
  headers as small, secondary-colored captions attached to their group; the
  current headers read as detached bold titles.
- The workflow graph pane is placed **first** in the instance detail document
  stack (`DetailView.swift:112-118`) but **last** in the workflow source
  detail stack (`SourcesPane.swift:248-251`), so the two panes scan in a
  different order for no reason.
- Instance detail has an in-pane removal confirmation
  (`instanceDetailPane == .removalConfirmation`,
  `DaemonWorkflowWindowController+Navigation.swift:37-39`); workflow source
  detail has no removal affordance and a different navigation flag
  (`isShowingWorkflowSourceDetail`, `Navigation.swift:49-51`), so back
  navigation behaves differently between the two panes.

The result is that the two most-used detail screens feel like they were built
by different apps, violating the "one shared AppKit row treatment" rule in
`design-rielaapp-workflow-instances.md` (lines 413-417).

### R2. Variable and Environment editors look unfinished

The `Workflow Variables` and `Environment Variables` editors
(`DaemonWorkflowWindowController+ConfigurationEditors.swift:7-48`) present a
bare `NSTextView` with no guidance:

- The text view is created with a **hard-coded 520×190 frame**
  (`ConfigurationEditors.swift:302`), so in narrow or tiled windows the
  editor overflows or floats against the trailing edge — this is the
  "text box pushed to the right, unclear what to do" report. The spec already
  forbids this: `design-rielaapp-workflow-instances.md` (lines 448-455)
  requires a bounded, Settings-style editor accessory rather than a fixed
  520px panel; that requirement is unimplemented.
- There is no placeholder, no example, and no format hint. The user must
  already know the `KEY=value` line format (and, for variables, the
  `KEY:=<json>` form handled in `ConfigurationEditors.swift:371-381`) —
  nothing on screen teaches it.
- There is no empty state. A first-time user sees a blank monospaced box.
- Validation is deferred to Save and reported through an inline red label
  (`ConfigurationEditors.swift:360-362`); nothing flags a malformed line
  while typing.
- The `Variable Settings` section and `Current Lines` summary row required by
  `design-rielaapp-workflow-instances.md` are absent.

### R3. The Riela Assistant panel has no Clear action

The assistant panel's controls consist of only a title stack, a fold button,
a prompt field, and a send button
(`WorkflowViewerWindowController+Assistant.swift:39-47`). Transcript state is
persisted in `RielaAppAssistantSettings.messages` (up to 80 messages,
`Sources/RielaAppSupport/RielaAppProfileModels.swift:48-136`), so a stale or
failed conversation follows the user across launches with no way to start
over short of editing the profile state on disk.

### R4. Codex backend reports a missing binary as an authentication failure

Typing into the assistant with the codex-cli backend selected while the
`codex` binary is not installed produces:

```
Assistant error: codex-agent authentication is unavailable: env: codex: No such file or directory
```

Three defects compound here:

1. **Misclassification.** The codex auth preflight runs
   `codex login status` without first checking that the binary exists
   (`Sources/CodexAgent/CodexAgentAdapter.swift:136-153`). Any spawn failure
   — including "executable not found" — is caught by the same `catch` and
   wrapped as `"codex-agent authentication is unavailable: …"`
   (`CodexAgentAdapter.swift:150-153`). By contrast, the claude-code and
   cursor adapters run `--version` first and report
   `"… CLI is unavailable"` separately from auth failures
   (`ClaudeCodeAgentAdapter.swift:153-192`,
   `CursorCLIAgentAdapter.swift:150-175`). Codex skips that step.
2. **Raw system error leaks to the UI.** `agentPreflightErrorDetail`
   passes `error.localizedDescription` through nearly verbatim
   (`Sources/RielaAdapters/AdapterUtilities.swift:65-81`), so the shell-level
   `env: codex: No such file or directory` string reaches the transcript via
   `"Assistant error: \(error.message)"`
   (`EntryPoint+Assistant.swift:80`).
3. **No preflight at selection time.** The vendor popup lets the user pick
   any backend without checking availability
   (`DaemonWorkflowWindowController+Assistant.swift:24-37`); the failure only
   surfaces after the user composes and sends a message.

## Problem — findings from code inspection (A1–A6)

### A1. Assistant panel uses hard-coded dark-theme colors

`RielaAssistantMiniChatStyle.swift:17-18, 138-164` uses
`NSColor(calibratedWhite:)` values (0.08, 0.17, 0.22, 0.64, 0.90, 0.94)
instead of semantic system colors, so the panel is a fixed dark island that
does not adapt to light mode and does not match any other pane in the app.

### A2. Error presentation is inconsistent and leaks raw strings

Errors surface variously as inline red labels
(`ConfigurationEditors.swift:360-362`,
`WorkflowViewerWindowController+Assistant.swift:11-14`), status-banner text
with interpolated `error.localizedDescription`
(`EntryPoint.swift:63, 333, 377`), and raw interpolated errors
(`"Workflow graph unavailable: \(error)"`,
`DaemonWorkflowWindowController+SourcesPane.swift:205`). There is no single
rule for when an alert, a banner, or an inline caption is used, and technical
strings (paths, JSON parse errors, shell errors) reach end users.

### A3. Keyboard support is minimal

Prompts handle only Escape and Return
(`DaemonWorkflowWindowController+Prompts.swift:116`). There is no Cmd-[ /
Cmd-] or Escape support for the in-window back navigation, no Cmd-N for
adding an instance, and — because the app is a status-bar accessory — no
main menu to host and advertise shortcuts.

### A4. Destructive and lossy actions are inconsistently guarded

Instance removal has an in-pane confirmation and profile removal has a
warning-style `NSAlert` (`ProfileSelectWindowController.swift:394`), but
saving over environment/variable values and relinking sources have no
confirmation and there is no undo anywhere.

### A5. Long-running operations lack progress feedback

Instance states include transient `Starting`/`Stopping`/`Reloading` values
(`DaemonWorkflowWindowController.swift:32-39`) but no spinner or progress
indicator accompanies them, so the app looks frozen during slow transitions.

### A6. Terminology drifts between panes

The same objects are called "workflow", "instance", "source", and (in logs)
"daemon" depending on the screen (`DaemonWorkflowWindowController.swift:361`,
`ProfileSelectWindowController.swift:30`, `EntryPoint.swift:65-79`). The
Source/Instance vocabulary from `design-rielaapp-workflow-instances.md` is
not applied uniformly.

## Problem — journey-wide review (B1–B13)

These findings come from walking the app end-to-end as a user would: first
launch, first instance, watching it run, editing its configuration, and
recovering when things break.

### First run and mental model

### B1. First launch is invisible and the core concepts are never defined

The app launches as a menu-bar accessory (`setActivationPolicy(.accessory)`,
`EntryPoint.swift:50`): no Dock icon, no window, no first-run notice — just a
small icon in the menu bar with tooltip `"Riela workflow instances"`
(`EntryPoint+Menu.swift:12`). A first-time user may conclude the app failed
to launch. When they do find the Instances window, the empty state
(`DaemonWorkflowEmptyStateView.swift:9-13`) walks through three steps but
leans on four terms the app never defines anywhere: **workflow source**,
**instance**, **profile**, and **.env file**. "Profile" in particular
appears in the status menu (`Profile default`) and the Profiles pane with
only the circular explanation `"Create a saved profile for another instance
set"` (`ProfileSelectWindowController.swift:368`). The label
"Workflow Sources" is also used both for the sidebar pane (the collection)
and for each row in it (an individual workflow/package), so the word "source"
does double duty.

### B2. Starter workflows need secrets, and the user learns this too late

First launch silently installs four starter workflows (Discord/Telegram/
Slack/Mail bots, `RielaAppDefaultProfileBootstrapper.swift`), all of which
require sensitive environment variables (`DISCORD_BOT_TOKEN`,
`OPENAI_API_KEY`, … — lines 121-132). Nothing in the sources list, the
create-instance flow, or the empty state tells the user these are templates
that will not run without credentials; the requirement only surfaces as a
runtime failure after the instance starts. The `Required Env` list does
appear in the Configure Instance dialog
(`DaemonWorkflowWindowController+Prompts.swift:526-531`) but as static text,
with no indication of which requirements are currently satisfied.

### Creating instances

### B3. The Configure Instance form has ambiguous fields and a hidden default

- The **Instance ID** field is empty with a placeholder and the caption
  `"Leave empty to use a generated instance ID."`
  (`Prompts.swift:490-513`). Empty-means-generated is a programmer
  convention; a user cannot tell whether the placeholder is a value or a
  hint, and nothing explains what an instance ID is for.
- The **Start immediately** checkbox is pre-checked (`Prompts.swift:501-502`)
  with no caption, so creating an instance silently spawns a serve process —
  surprising for a user who expected to configure first, run later.
- The `.env File` and `Working Directory` fields say only `"Optional .env
  path"`; the file-existence check surfaces as a bare red `"File not found"`
  caption (`Prompts.swift:44-68, 493-498`) with no hint about what the file
  is for.

### B4. Source recovery ("Needs Source" / relink) is a loop with no narration

When a saved instance's source disappears, the row shows `"Needs Source"`
and the detail pane hides every setting, leaving one `Relink Source` action
and the terse caption `"Missing source"` plus the stored identity
(`DaemonWorkflowWindowController+InstanceRows.swift:457, 824-834`). Nothing
tells the user *what happened* (the directory was moved or deleted), *where
the source used to be*, or *what relinking will do*. Worse, the relink flow
is a literal `while true` retry loop
(`DaemonWorkflowWindowController+Prompts.swift:570-580`): if no sources are
available, the user is bounced to an import dialog, and after importing, the
relink picker **reappears with no explanation** — it looks like the dialog is
stuck rather than intentionally retrying.

### B5. URL import accepts only GitHub URLs but never says so, and fails opaquely

The import-from-URL prompt shows the placeholder
`"https://github.com/owner/repo/tree/main/path"`
(`Prompts.swift:658-674`) but nothing states that only GitHub URLs are
supported (the materializer is `RielaAppGitHubSourceMaterializer`,
`EntryPoint+DaemonSourceURLImport.swift:16`). Failures produce one generic
banner, `"Failed to import URL: {error.localizedDescription}"`
(`EntryPoint+DaemonSourceURLImport.swift:23`), which does not distinguish
network failure, a wrong path, an unsupported host, or an invalid package.

### Running and observing

### B6. Diagnosing a failed instance is a dead end in the main window

A failed instance shows a red `Failed` state, and the only failure detail is
squeezed into the row subtitle alongside profile and workflow name
(`"Profile default | my-workflow | bind: address already in use"`,
`InstanceRows.swift:459-460`). The instance detail pane's settings section
shows a `Status` row but offers no "why did this fail" affordance and no path
to logs — the user must know to open the Viewer and find the Run Log tab.
There is also no automatic retry and no guidance for common causes (port
conflict, missing env).

### B7. The Viewer window mislabels its own contents

- The header label is initialized to `"Choose Workflow"`
  (`WorkflowViewerWindowController.swift:21, 512`) and in several states is
  never replaced, so a loaded viewer can still read as an unfinished picker.
  The window title is the generic `"Riela Workflow Viewer"` — never the
  instance name.
- The first tab is named **Edit** but contains only read-only metadata text
  (`configureReadOnlyTextView()`, `WorkflowViewerWindowController.swift:274-276,
  326`).
- The session popup's empty item says `"No Runs"`
  (`WorkflowViewerWindowController.swift:501`) while every populated item says
  `"Session …"` (line 70 of the rendering extension) — two words for one
  concept.
- The override controls expose raw internal vocabulary: a row titled
  `"Effort"` (meaning reasoning effort, line 199) and buttons for
  `"Node Patch"` (lines 201, tooltips `"Save Node Patch"` /
  `"Clear Node Patch"`) with no explanation of what a patch is or when it
  applies.
- Disabled setting rows are indicated only by 0.55 alpha and a tooltip
  (`WorkflowViewerWindowController+Controls.swift:37-40`), which is easy to
  miss.

### B8. The Viewer is static while the workflow is live, and mute when it waits

- Execution state (step timeline, durations shown as `"running"`,
  `WorkflowViewerWindowController+Rendering.swift:165-173`) only updates when
  the user clicks the refresh button — even though the main window already
  polls daemon state every 2 seconds (`EntryPoint.swift:82`).
- A workflow paused waiting for manager input is indistinguishable from one
  merely idle: the Messages section renders inbox/outbox history
  (`Rendering.swift:56-60`) but nothing says "this workflow is waiting for a
  response", and there is no way to respond from the app even though the
  GraphQL control plane supports `sendManagerMessage`.
- When the underlying instance stops or disappears, the viewer stays open
  with stale data; a failed refresh only swaps the header to
  `"Unable to load workflow"` (`WorkflowViewerWindowController.swift:472-496`).
- Only one viewer window can exist (`EntryPoint+Viewer.swift:11-12` reuses a
  single controller), so opening a second instance's viewer silently
  repurposes the first, and there is no window-frame restoration.

### B9. The workflow graph has no zoom, no legend, and is absent from the Viewer

`DaemonWorkflowGraphPaneView.swift` renders a fixed-scale node grid inside a
scroll view with no zoom or fit-to-view control (content can reach
4000×2400, line 349), no legend for its state colors and edge styles, and a
single `"No workflow steps"` string for every empty/error case (line 250).
The graph exists only in the main window's detail panes; the Viewer — the
window dedicated to inspecting a workflow — has no graph at all, only the
outline tree.

### Editing configuration

### B10. Saving configuration silently restarts the running instance

Changing the .env file, working directory, environment, or variables of a
running instance triggers `restartActiveDaemonWorkflowAfterConfigurationChange`
with no warning that the instance will restart (in-flight sessions
interrupted). The Save button gives no hint that it is also a restart button.

### B11. Modal editors block the whole app and discard edits silently

`RielaAppSettingsEditorWindowController` runs its editors with
`NSApp.runModal()` (`RielaAppSettingsEditorWindowController.swift:141`),
freezing every other window — including the instances list the user might
want to consult while editing. Closing the window or pressing Cancel
discards all edits with no confirmation (lines 22-24). Native macOS practice
is a window-attached sheet, scoped to one window, with a dirty-state check
on dismissal.

### B12. Event sources are configured through a bare JSON editor

The per-instance event source editor asks the user to paste raw source and
binding JSON with no schema, examples, or kind-specific guidance; validation
errors are generic (`"Event source kind X is not supported"`,
`EntryPoint+EventSources.swift:14-26`). The concept "event source" is never
explained in the UI.

### Small trust-eroding details

### B13. A collection of small inconsistencies undermines confidence

- **Status banner is single-slot and transient**: a new message replaces the
  current one, and info messages auto-dismiss after 5 seconds
  (`RielaAppStatusBannerView` usage, controller lines 504-518). Outcomes are
  easy to miss and impossible to review afterwards.
- **Assistant overview summary shows `"N characters configured"`**
  (`DaemonWorkflowWindowController+OverviewSummaries.swift:9-11`) — a
  character count of the prompt text says nothing about whether the
  assistant is usable (vendor, model, availability).
- **Environment value masking leaks short lengths**: bullets repeat
  `min(max(count,1),8)` times (`RielaAppEnvironmentValueFormatter.swift:19`),
  so 1–7 character values reveal their exact length while longer ones don't.
- **Environment source annotations use three labels** — `(.env)`, `inline`,
  `(inline override)` (`EntryPoint+Environment.swift:86-96`) — for two
  concepts.
- **No About item** in the status-bar menu (`EntryPoint+Menu.swift:16-33`),
  so version information is unreachable.
- **Corrupt state silently becomes an empty app**: a failed state-file decode
  falls back to `RielaAppDaemonWorkflowState()`
  (`DaemonWorkflowSupport.swift:290`), so the user's instances vanish with no
  explanation and the old file is overwritten on next save.

## Design

### Implementation slice for issue-resolution workflow

The current issue-resolution workflow implements the narrow, directly
testable slice first:

1. **R1/F1:** align workflow source detail and instance detail around one
   settings-section header helper and one document order:
   settings/summary, actions, graph.
2. **R2/F2:** replace the fixed-width variable/environment editors with
   bounded guided editors, placeholders, line counts, and live `KEY=value`
   validation that disables Save.
3. **R3/F3:** add an Assistant Clear control that is disabled for empty
   transcripts, confirms before deleting persisted messages, refreshes the
   transcript, and cancels any in-flight assistant work before clearing.
4. **R4/F4:** make codex preflight run `codex --version` before
   `codex login status`, so a missing binary is reported as CLI
   unavailable with a PATH remedy rather than as an authentication failure
   or a raw `env:` spawn error.

Focused B/F work may be included only when it is local to the same files and
can be verified in the same turn. In this slice, F5 is eligible because the
assistant color audit is directly verified by searching for
`NSColor(calibratedWhite:)` under `Sources/RielaApp`. Broader B/F items
remain specified below but should not displace R1-R4.

### Adapter behavior boundaries

CLI behavior stays isolated behind adapter modules. UI code consumes stable
availability/authentication categories and recovery text; it must not parse
raw shell output or vendor-specific stderr.

- **codex adapter:** mirrors the Cursor and Claude two-phase preflight shape
  but keeps codex-specific commands in `CodexAgentAdapter.swift`:
  `codex --version` checks binary availability, then `codex login status`
  checks authentication.
- **cursor adapter:** remains the reference for separating CLI
  availability from authentication, but Cursor-specific commands, labels,
  and messages stay in `CursorCLIAgentAdapter.swift`.
- **shared utilities:** executable-not-found normalization belongs in
  `Sources/RielaAdapters/AdapterUtilities.swift` so all CLI adapters render
  missing-binary errors consistently without copying vendor logic into the
  AppKit assistant UI.

This intentionally diverges from the observed codex-agent failure mode where
a missing `codex` binary was wrapped as authentication unavailable. The
RielaApp behavior should match the already-better Cursor/Claude adapter
shape, not preserve the codex-specific misclassification.

### F1. Unify detail-pane structure on the System Settings pattern (fixes R1)

Define one canonical detail-pane skeleton and make both detail panes (and the
removal confirmation) instances of it:

1. **Shared section-header row.** Add a
   `rielaAppSettingsSectionHeader(_ title: String)` helper next to the
   existing row helpers in `RielaAppSettingsRowStyle.swift`. It renders the
   System Settings convention: an 11pt `.secondaryLabelColor` caption in
   sentence case (`Settings`, `Actions` — not bold 13pt titles), leading-
   aligned with the grouped section's content inset, with fixed 6px spacing
   to the section below it. Replace `detailHeaderRow()` in
   `DetailView.swift:160-171` with this helper and delete the custom
   implementation.
2. **Headers on both panes.** The workflow source detail pane adopts the same
   headers: `Source` above its summary section and `Actions` above its
   action section (`SourcesPane.swift:299-320`). Every grouped section in a
   detail pane is preceded by a header from F1.1; unlabeled groups are no
   longer allowed in detail panes.
3. **Consistent document order.** Both detail panes order their document
   stack identically: header/summary text, settings sections, actions
   section, then the workflow graph pane last. (Graph-last matches the
   sources pane today and keeps actionable rows above the fold; instance
   detail moves its graph pane from first to last.)
4. **Consistent navigation.** Both panes push and pop through the same
   navigation state so the back control behaves identically, and both
   respond to Escape and Cmd-[ (see F6). The removal-confirmation pane
   remains instance-only but uses the same skeleton (message section +
   action section, each with a header).

### F2. Rebuild the Variable and Environment editors as guided forms (fixes R2)

Keep the multiline `KEY=value` editor as the storage format, but present it
the way System Settings presents a complex value editor:

1. **Kill the fixed frame.** Remove the 520×190 hard-coded frame
   (`ConfigurationEditors.swift:302`). The editor's scroll view pins to the
   pane's readable content width (leading and trailing margins equal to the
   grouped-section insets), with `heightAnchor` between 120 and 260 and
   scrolling beyond that. On narrow windows it shrinks with the pane instead
   of overflowing right.
2. **Settings-style structure.** Render the editor pane with the F1 skeleton:
   - a `Variable Settings` (or `Environment`) section header;
   - a read-only `Current Lines` summary row ("3 variables configured" /
     "No variables configured") that doubles as the empty-state signal;
   - an `Editor` row containing the bounded text editor.
   This is the structure already specified in
   `design-rielaapp-workflow-instances.md` (lines 448-455); this design makes
   it binding.
3. **Teach the format in place.** When the editor is empty, show placeholder
   text inside the text view (drawn in `.placeholderTextColor`, cleared on
   first keystroke):
   - Environment: `KEY=value — one per line`
   - Variables: `name=text value` and `count:=42 — use := for JSON values`
   Below the editor, a permanent one-line caption states the format rule so
   it stays visible while typing.
4. **Live validation.** Parse on every text change. Show a count of invalid
   lines in the caption (`Line 2 is not KEY=value`) and disable Save while
   any line is invalid. The existing save-time error label
   (`ConfigurationEditors.swift:360-362`) remains only as a fallback for
   errors that can occur solely at save time (e.g. persistence failures).
5. **Environment editor parity.** The `Effective Configured Environment`
   read-only view (`ConfigurationEditors.swift:312-334`) becomes a grouped
   section with its own header above the inline editor section, using the
   same bounded-width rules, so the two halves of the pane align.

### F3. Add Clear to the assistant panel (fixes R3)

1. Add a `Clear` button to the assistant controls stack
   (`WorkflowViewerWindowController+Assistant.swift:39-42` and the daemon
   window's equivalent), placed before the fold button, using a standard
   template image (`trash` SF Symbol) with an accessibility label
   `Clear conversation`.
2. Clearing empties `RielaAppAssistantSettings.messages`, persists through
   the existing `onSaveAssistantSettings` path, refreshes the transcript, and
   returns focus to the prompt field. Any in-flight request is cancelled
   first.
3. Because the transcript is persisted and clearing it is not undoable, the
   button asks for confirmation only when the transcript is non-empty, via a
   small confirmation popover anchored to the button (not a modal alert —
   this matches lightweight destructive actions in first-party apps like
   Notes' "Delete note"). The button is disabled when the transcript is
   empty.

### F4. Separate "CLI missing" from "not authenticated" in the codex adapter (fixes R4)

1. **Version preflight first.** `runCodexDefaultAuthPreflight`
   (`CodexAgentAdapter.swift:121-162`) adopts the same two-phase structure as
   the claude-code and cursor adapters: run `codex --version` first; if that
   spawn fails or exits nonzero, throw
   `"codex-agent CLI is unavailable: …"` and never reach the login-status
   phase. Only a failing `codex login status` after a successful version
   check may produce `"codex-agent authentication is unavailable"`.
2. **Human-readable detail.** `agentPreflightErrorDetail`
   (`AdapterUtilities.swift:65-81`) maps the executable-not-found spawn
   failure to a stable message —
   `the 'codex' command was not found on PATH` — instead of forwarding
   `env: codex: No such file or directory`. Other spawn errors keep their
   strerror text but are prefixed with `could not run 'codex':` so the user
   sees which action failed. Apply the same mapping to all three CLI
   adapters so their messages stay parallel.
3. **Assistant-side rendering.** The assistant error path
   (`EntryPoint+Assistant.swift:67-84`) renders CLI-unavailable errors with a
   remedy line: `The codex CLI is not installed or not on PATH. Install it or
   choose another assistant backend.` Auth-unavailable errors likewise gain
   their remedy (`Run 'codex login' in a terminal, then retry.`).
4. **Selection-time preflight.** When the user picks an explicit vendor in
   the popup (`DaemonWorkflowWindowController+Assistant.swift:24-37`), the
   app runs the cheap PATH check (`executablePath(named:)`,
   `EntryPoint+Assistant.swift:241-248`) immediately and, if the binary is
   missing, shows the availability caption in the assistant header
   (`codex CLI not found`) while still allowing the selection. The full auth
   preflight remains at first-message time. The `.automatic` resolution order
   (`EntryPoint+Assistant.swift:86-109`) is unchanged.

### F5. Adopt semantic colors and native materials in the assistant panel (fixes A1)

Replace every `NSColor(calibratedWhite:)` in
`RielaAssistantMiniChatStyle.swift` with semantic equivalents:
`.controlBackgroundColor` / `.underPageBackgroundColor` for surfaces,
`.labelColor` / `.secondaryLabelColor` for text, and
`.quaternaryLabelColor` for hairlines. The panel container uses an
`NSVisualEffectView` with `.popover`-style material rather than a painted
dark rectangle, and the corner radius drops to the 12px used by
`RielaAppSettingsSectionView` (`RielaAppSettingsRowStyle.swift:401`) so the
assistant looks like part of the same app in both appearances.

### F6. One error-presentation rule and baseline keyboard support (fixes A2, A3)

1. **Error rule.** Three tiers, applied everywhere:
   - *Field-scoped* problems (invalid line, missing file) → inline caption
     next to the field, as in F2.4.
   - *Operation failures* the user just triggered (start/stop/save/import
     failed) → the existing status banner
     (`RielaAppStatusBannerView.swift`), with a message written for users;
     `error.localizedDescription` may appear only as a second sentence, never
     as the whole message.
   - *Blocking* failures (profile cannot be prepared, data would be lost) →
     `NSAlert` with a recovery suggestion.
   Interpolating a bare Swift error into user-visible text
   (`"… unavailable: \(error)"`, `SourcesPane.swift:205`) is prohibited;
   every call site maps to one of the three tiers.
2. **Keyboard baseline.** Escape and Cmd-[ pop the in-window navigation when
   a detail pane is showing; Cmd-W closes the window; Cmd-N adds an instance
   when the instances pane is frontmost; Return/Escape continue to work in
   prompts. Shortcuts are attached via key equivalents on the existing
   controls so they work without a main menu; introducing a full menu bar is
   out of scope for this design.

### F7. Make the first run visible and define the vocabulary (fixes B1, B2)

1. **Open the Instances window on first launch.** When the default profile
   is bootstrapped for the first time (the branch that installs starter
   workflows, `EntryPoint.swift:828-830`), the app also opens the Instances
   window and activates as a regular app, exactly as the existing
   `--open-workflows` path does (`EntryPoint.swift:412-421`). Subsequent
   launches keep today's quiet accessory behavior.
2. **Definitions live in the empty state, not a manual.** The empty-state
   view (`DaemonWorkflowEmptyStateView.swift`) gains one-line definitions
   under its heading, phrased for someone who has never seen Riela:
   - *A workflow is a set of automated steps. Sources are the folders and
     packages workflows are loaded from. An instance is one configured,
     runnable copy of a workflow.*
   The word **profile** is defined where it appears: the Profiles pane
   header gains the caption *Each profile is an independent set of sources
   and instances.* replacing the circular "another instance set" copy
   (`ProfileSelectWindowController.swift:368`).
3. **Disambiguate "source".** The sidebar pane keeps the name
   `Workflow Sources`; individual rows are labeled as workflows (title = the
   workflow's display name, subtitle = where it comes from: `Starter package`,
   `User package`, `Project workflow`, `Imported folder`). "Source" refers
   only to the *origin*, never to the workflow itself, across all panes and
   prompts.
4. **Starter workflows declare their requirements.** Source rows and the
   Choose Workflow list show a requirement badge when the workflow declares
   required environment variables (`requiredEnvironment`,
   `DaemonWorkflowSupport.swift:688`): `Needs 3 environment values`. The
   starter rows also carry the subtitle `Starter template — requires
   credentials` so nobody expects them to run out of the box.

### F8. Clarify the Configure Instance form (fixes B3, part of B2)

1. **Pre-fill the generated ID.** The Instance ID field is pre-filled with
   the generated ID as real, editable text; the caption becomes
   `Identifies this instance in menus and logs.` The empty-means-generated
   convention and its shifting placeholder (`Prompts.swift:490-513`) are
   removed.
2. **Requirement checklist.** The `Required Env` block becomes a live
   checklist: each required variable shows a checkmark or a warning dot
   depending on whether the selected .env file plus inline values currently
   provide it. Creation is still allowed with unmet requirements, but the
   Create button caption warns `2 required values are missing — the instance
   may fail to start.`
3. **Honest start control.** The `Start immediately` checkbox keeps its
   default-on state but gains the caption `Runs the instance as soon as it is
   created.` If unchecked, the post-create banner says `Created {name} —
   start it from the list when ready.`
4. **Field guidance.** `.env File` caption becomes `Optional file of
   KEY=value lines loaded when the instance starts.`; `Working Directory`
   caption becomes `Where the workflow's steps run. Defaults to the
   workflow's folder.`

### F9. Narrate source recovery and remove the silent relink loop (fixes B4)

1. **Explain "Needs Source".** The needs-source detail pane replaces the bare
   `"Missing source"` caption with a short explanation section:
   `This instance's workflow can no longer be found. It was loaded from:
   {stored identity / path}. Relink it to a workflow in your sources, or
   import the workflow again.` The two actions — `Relink Source` and
   `Import Workflow…` — sit in the actions section below it.
2. **Replace the retry loop with explicit state.** The `while true` relink
   loop (`Prompts.swift:570-580`) becomes an explicit flow: when the user
   imports from within relink, the relink picker reappears **with a status
   line** — `Imported {name}. Select it below to relink.` — and the newly
   imported source is pre-selected at the top of the list. Cancelling at any
   point returns to the instance detail pane, never to another dialog.

### F10. Disclose URL-import constraints and classify its failures (fixes B5)

1. The import-from-URL prompt states its contract in the caption:
   `Enter a GitHub URL to a workflow or package directory
   (https://github.com/owner/repo/tree/branch/path).`
2. The materializer's failures are classified before display (per the F6
   error rule): unsupported host → `Only GitHub URLs are supported.`;
   network failure → `Could not download from GitHub. Check your
   connection.`; path not found / not a workflow → `That URL does not point
   to a workflow or package directory.` The banner keeps the URL so the user
   can see what was attempted.
3. During download, the prompt shows an indeterminate progress indicator and
   disables the import button (also the first concrete instance of the A5
   progress-feedback gap).

### F11. Make failure diagnosis reachable from the main window (fixes B6)

1. **Status row carries the failure.** In the instance detail pane, the
   `Status` row of a failed instance shows the state detail as its value
   (`Failed — bind: address already in use`) instead of burying it in the
   list row's subtitle.
2. **`View Run Log` action.** Failed (and running) instances gain a
   `View Run Log` action row that opens the Viewer directly on the Run Log
   tab of the latest session, so the path from "it's red" to "here's why" is
   one click.
3. **Known causes get remedies.** The two most common failures are mapped to
   remedy text under the F6 rule: port-in-use → `Another process is using
   this port. Stop it or change the instance's port.`; missing required
   env → `Required environment values are missing: {names}. Set them in
   Environment Variables.`

### F12. Truth-in-labeling and live state for the Viewer (fixes B7, B8, B9)

1. **Identity.** The viewer window title becomes
   `{instance display name} — Riela Viewer`; the header label always shows
   the loaded workflow's display name and never the `"Choose Workflow"`
   placeholder (`WorkflowViewerWindowController.swift:21, 512-522`).
2. **Tab renames.** `Edit` → `Overview` (it is read-only metadata). The
   session popup's empty item becomes `No Sessions` to match the
   `Session …` item naming; "run" disappears from viewer vocabulary except
   in the `Run Log` tab name, which stays (it names the log of a session's
   run).
3. **Plain-language overrides.** The `Effort` row is retitled
   `Reasoning Effort`. The `Node Patch` buttons become `Save Override` /
   `Remove Override`, with a section caption `Overrides change this node's
   model settings for future sessions of this instance.` Disabled override
   rows show their reason as a visible caption (reusing the tooltip text,
   `Controls.swift:37-40`) instead of alpha-only dimming.
4. **Live refresh.** While the viewed instance is running, the viewer
   subscribes to the same 2-second poll the main window already uses
   (`EntryPoint.swift:82`) and refreshes the outline states, step timeline,
   and durations automatically. The manual refresh button remains for
   stopped instances.
5. **Waiting-for-input is a first-class state.** When the latest session has
   a pending manager question, the viewer shows a prominent banner above the
   tabs: `This workflow is waiting for a response.` with a `Respond…` button
   that opens a reply field posting through the existing GraphQL
   `sendManagerMessage` path. If the reply plumbing is deferred, the banner
   ships anyway with instructions for responding via the CLI — silence is
   the one unacceptable option.
6. **Stale-instance banner.** If the viewed instance stops or disappears,
   the viewer keeps its data but shows a banner `This instance is no longer
   running — showing the last loaded state.` instead of only swapping the
   title to `"Unable to load workflow"`.
7. **Graph improvements (bounded).** The graph pane gains a fit-to-view
   button and pinch/Cmd-scroll zoom, a small legend popover (state colors,
   edge kinds), and distinct empty-state strings for "no workflow loaded" vs
   "workflow has no steps" vs "graph unavailable: {reason}"
   (`DaemonWorkflowGraphPaneView.swift:250`). Embedding the graph into the
   Viewer as a fifth tab (`Graph`) reuses the same pane component. A minimap
   and multi-window viewers are out of scope (see below).

### F13. Honest configuration-edit semantics (fixes B10, B11, B12)

1. **Say when Save restarts.** When the edited instance is running, the
   editor's primary button is titled `Save & Restart Instance` and the
   footer caption reads `Saving applies the change by restarting this
   instance.` For stopped instances the button stays `Save`.
2. **Sheets, not app-modal windows.** `RielaAppSettingsEditorWindowController`
   presents as a sheet attached to the owning window
   (`beginSheet(_:completionHandler:)`) instead of `NSApp.runModal()`
   (`RielaAppSettingsEditorWindowController.swift:141`), so the rest of the
   app stays readable. Choice dialogs ("Choose Action") likewise become
   sheets.
3. **Dirty-state guard.** Cancelling or closing an editor with unsaved
   changes asks `Discard changes?` (Discard / Keep Editing) — the standard
   lossy-dismissal guard, and the concrete fix for the A4 finding's
   editor half.
4. **Event sources get a form.** The event source editor becomes a two-level
   UI: a kind picker (webhook, cron, chat, …) that inserts a commented
   template for the chosen kind into the editor, with the raw JSON editor
   retained as the body. A caption links the concept in one line: `Event
   sources trigger this instance's workflow from outside — webhooks, timers,
   or chat messages.` Validation errors name the field that failed rather
   than only the kind.

### F14. Restore trust in the small details (fixes B13, parts of A5)

1. **Banner history.** The status banner keeps its single-slot presentation
   but records the last 20 messages; clicking the banner (or a small history
   button in it) shows the recent list in a popover. Error banners continue
   to require manual dismissal; info banners keep the 5-second auto-dismiss.
2. **Meaningful assistant summary.** The overview summary
   (`OverviewSummaries.swift:9-11`) reports vendor/model and availability
   (`Codex CLI — gpt-5.2` / `Not configured` / `codex CLI not found`)
   instead of a character count.
3. **Fixed-width masking.** Masked environment values always render exactly
   8 bullets regardless of length (`RielaAppEnvironmentValueFormatter.swift:19`
   drops the `max(value.count, 1)` term), so no value leaks its length.
4. **Two source labels.** Environment value annotations collapse to
   `(.env)` and `(inline)` everywhere (`EntryPoint+Environment.swift:86-96`).
5. **About item.** The status-bar menu gains `About Riela` (name, version
   from `VERSION`, link to the repository) above `Quit`
   (`EntryPoint+Menu.swift:16-33`).
6. **Corrupt state is quarantined, not erased.** When the state file fails
   to decode (`DaemonWorkflowSupport.swift:290`), the app renames it to
   `daemon-workflows.json.corrupt-{timestamp}`, starts with empty state, and
   shows a blocking alert (F6 tier 3): `Riela could not read this profile's
   saved instances. The unreadable file was kept at {path}.` The old file is
   never silently overwritten.
7. **Transient-state spinners.** Rows in `Starting` / `Stopping` /
   `Reloading` states show a small `NSProgressIndicator` (spinning style)
   next to the state label, resolving the A5 finding for the instance list.

### Out of scope

Deferred to follow-up designs, with their evidence recorded above:

- **Undo support** (A4, beyond the F13.3 dirty-state guard) — needs runtime
  plumbing beyond UI work.
- **Terminology sweep** (A6) — should be executed as a single vocabulary
  audit against `design-rielaapp-workflow-instances.md` rather than
  piecemeal edits; F7.3 and F12.2/F12.3 fix only the worst offenders.
- **Multiple simultaneous viewer windows and viewer window-frame
  restoration** (B8) — requires reworking the single-controller ownership in
  `EntryPoint+Viewer.swift`.
- **Graph minimap / large-graph navigation beyond zoom and fit** (B9).
- **State-file locking for concurrent app instances** (B13) — a persistence
  design, not a UI one; until then last-write-wins remains.
- **A full main menu bar** (A3) — key equivalents on controls cover the
  baseline; a menu bar is worth doing but changes the app's activation
  model.

## Acceptance criteria

- Workflow source detail and instance detail render section headers with one
  shared helper, in the same visual style, and order their document stacks
  identically (settings → actions → graph). No detail pane contains an
  unlabeled grouped section. (F1)
- The Variable and Environment editors have no hard-coded width; at any
  window width down to the window's minimum, the editor is fully visible and
  leading-aligned with the other grouped sections. (F2.1)
- An empty Variable or Environment editor shows placeholder text with the
  expected line format, and a persistent caption states the format while
  editing. Invalid lines disable Save and are named in the caption. (F2.3,
  F2.4)
- The assistant panel shows a Clear control that empties the persisted
  transcript after confirmation, cancels in-flight requests, and is disabled
  when the transcript is empty. (F3)
- With no `codex` binary on PATH, sending an assistant message with the
  codex backend produces a message that says the CLI is not installed and how
  to fix it; it does not contain the words "authentication" or the raw
  `env:` shell error. `codex login status` failing after a successful
  `codex --version` still reports an authentication problem. (F4)
- Selecting a vendor whose binary is missing immediately shows a
  "CLI not found" caption in the assistant header. (F4.4)
- `RielaAssistantMiniChatStyle.swift` contains no
  `NSColor(calibratedWhite:)` values, and the assistant panel is legible in
  both light and dark appearance. (F5)
- No user-visible string is produced by interpolating a raw Swift error as
  the entire message. (F6.1)
- Escape and Cmd-[ navigate back from detail panes; Cmd-W closes the window.
  (F6.2)
- On the launch that first bootstraps the default profile, the Instances
  window opens automatically; on later launches it does not. The empty state
  defines workflow, source, and instance in one sentence each. (F7.1, F7.2)
- Every source row whose workflow declares required environment variables
  shows a requirement badge, and starter rows are labeled as templates
  requiring credentials. (F7.4)
- The Configure Instance form pre-fills the generated instance ID as
  editable text, shows a live satisfied/missing checklist for required
  environment variables, and captions the pre-checked start toggle. (F8)
- A needs-source instance's detail pane states where the workflow was
  loaded from and what relinking does; importing a source during relink
  returns to the picker with the imported source pre-selected and a status
  line — never an unexplained repeated dialog. (F9)
- The URL import prompt states that only GitHub URLs are accepted, shows
  progress during download, and distinguishes unsupported-host, network, and
  not-a-workflow failures in its error banner. (F10)
- A failed instance's detail pane shows the failure reason in its Status row
  and offers a `View Run Log` action that opens the Viewer on the latest
  session's Run Log tab. (F11)
- The viewer window title contains the instance name; no state shows the
  `Choose Workflow` placeholder after a workflow is loaded; there is no tab
  named `Edit` whose content is read-only; the reasoning-effort row and
  override buttons use the F12.3 labels; disabled override rows display a
  visible reason caption. (F12.1–F12.3)
- While the viewed instance runs, the step timeline and outline states
  update without pressing refresh; a session with a pending manager question
  shows a waiting banner; a stopped/vanished instance shows a stale-state
  banner. (F12.4–F12.6)
- The graph pane offers fit-to-view and zoom, a legend, and three distinct
  empty/error strings; the Viewer has a Graph tab rendering the same pane.
  (F12.7)
- Editing configuration of a running instance shows `Save & Restart
  Instance` as the primary button; editors present as window sheets, and
  dismissing a dirty editor asks before discarding. (F13.1–F13.3)
- The event source editor offers per-kind templates and a one-line concept
  caption. (F13.4)
- The status banner exposes a history of recent messages; the assistant
  overview summary reports vendor/model/availability; masked environment
  values always render 8 bullets; environment source annotations use exactly
  two labels; the status-bar menu has an About item; a corrupt state file is
  quarantined with an alert instead of silently replaced; transient instance
  states show a spinner. (F14)
- Regression tests in `Tests/RielaAppSupportTests` cover: section-header
  helper output for both panes, variable/environment line validation
  results, codex preflight error classification (missing binary vs. auth
  failure), assistant clear behavior on the settings model, URL-import error
  classification, required-environment checklist evaluation, masking width,
  environment source labeling, and corrupt-state quarantine naming.
