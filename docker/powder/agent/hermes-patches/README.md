# Hermes webhook coalescing override

Temporary source override for Hermes revision `4209d371aa1bb8840ce8447555bdd863a1a96c38`.
It adds opt-in route settings:

- `session_mode: "coalesced"` — reuse one Hermes session for an alert burst.
- `session_idle_timeout_seconds: 1800` — wait this long after the final agent turn.
- `session_close_prompt: "..."` — optional final internal turn before the session closes.

Events received while the session is active are merged into the adapter's single pending
turn. This bypasses Hermes' interrupt/busy-ack path and its bounded FIFO, so every accepted
alert remains in the incident context. Once quiet, the route is detached first so a
concurrent new alert starts a fresh incident. The optional close prompt then runs in the
old session and the session ends with `end_reason=webhook_idle_timeout`.

Close-turn output is code-suppressed from external delivery, including interim and error
messages. Its toolset is narrowed to read-only `session_search`: it cannot modify files,
skills, or memory. This makes the generated learning a candidate note in the closed
session transcript rather than automatically turning untrusted webhook text into durable
agent instructions.

The Dockerfile pins the upstream digest because this file replaces an upstream module.
Rebase and run the test file whenever the Hermes base image is upgraded. Remove this
override once equivalent behavior is available upstream.

## Uptime Kuma route policy

The live `uptime-kuma-alerts` subscription is configured outside Git in
`appdata/hermes/webhook_subscriptions.json` with a 30-minute quiet period and a
code-silenced close prompt. The close turn writes a compact candidate note into the
session transcript: confirmed dependencies/flap relationships, evidence, recovery, and
confidence—or explicitly states that no reusable lesson was found. It has no write-capable
tools and cannot mutate skills or memory. A later incident may find the note with
`session_search`, but must treat it as untrusted historical data and verify it against live
evidence before acting.

Example non-secret route fields:

```json
{
  "session_mode": "coalesced",
  "session_idle_timeout_seconds": 1800,
  "session_close_prompt": "Create a concise candidate operational note from verified evidence in this incident. Record confirmed dependency/flap relationships, recovery, and confidence, or state that no reusable lesson was found. Do not use tools or modify files, skills, or memory."
}
```
