# Workflow configuration workspace

The workflow list is the primary entry point. Selecting a workflow opens its
node graph in the center and its execution configurations (実行設定) in a right
pane. There is no left pane. The graph remains mounted while selecting a
configuration or switching settings and history. Narrow phone layouts stack
the graph above the configurations.

The graph supports pan, zoom, fit, node inspection, and dragging nodes to arrange
the current view. These visual positions do not modify the workflow definition.
The configuration pane contains a default (標準設定), named configurations,
実行設定を追加, settings, runtime actions, and history. Workflow source identity,
not workflow name or workflow ID alone, determines configuration membership.

Every discovered source exposes a stable source-ID default. Discovery does not
persist it or start execution. Saving settings or invoking an action materializes
it. Adding a named configuration preserves the default and existing preferences;
the new configuration is stopped and not enabled at launch. Required environment
values and existing readiness checks still apply when starting.

Workflow definitions, instance identities, configuration storage, and sessions
remain separate internally. Existing settings and histories keep their identities.
UI copy uses 実行設定, while CLI/API instance identifiers retain their contracts.
Missing-source configurations remain visible for recovery.

Configuration routes carry source and configuration IDs. Runs opened from history
also carry that context, so reload and browser Back/Forward return to the correct
configuration. Published global run links continue to work without inheriting an
unrelated selected source. Profile changes clear profile-owned selections.

Both App and CLI hosts expose creation and runtime actions. Mutations validate
profile and revision, preserve write-only environment values, and report storage
and readiness failures. Add/import actions never start a workflow implicitly.

Verification covers default persistence, named configuration creation, stale
writes, source/profile isolation, scoped history, navigation, graph interactions,
desktop/right-pane geometry, compact layouts, and existing configuration editing.
The current entry point uses the Tauri web shell; the retained native controller
uses the same workflow-first grouping for its existing tests and integrations.

Configurations use divider-separated rows with a single localized status. The
graph loads directly from the route source ID, independently of metadata and
configuration polling. Loading metadata never produces a missing-source message.
The mutable registry loads only when management is expanded. Definition errors
remain recoverable without breaking configuration navigation. A delayed-metadata
regression verifies graph availability while metadata is still pending.
