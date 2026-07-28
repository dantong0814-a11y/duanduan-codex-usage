# Privacy

Duanduan Codex Usage is a local macOS menu-bar and floating-panel app.

- It does not ask for or store an OpenAI password, API key, or access token.
- It reads usage through the locally installed Codex `app-server`, which uses
  the active ChatGPT/Codex sign-in.
- It stores only a small local alert marker in `UserDefaults` so the 10%
  warning is not repeated during the same reset window.
- When conversation monitoring is enabled, it reads structured metadata from
  local Codex rollout files to identify thread ID, workspace name, task state,
  timestamps, and tool category.
- It does not display or transmit full prompts, assistant messages, reasoning
  content, command output, tool output, or file contents.
- It stores only local preferences for monitoring, voice announcements, and
  completed activities that the user has already opened.
- Voice announcements use the macOS on-device speech synthesizer.
- It does not include telemetry, analytics, advertising, or a project-owned
  server.
- The account-level Codex endpoint exposes total daily token activity. It does
  not expose an input/output/cached-token breakdown, so the app does not invent
  one.

Codex `app-server` and the local rollout event format may change in a future
Codex release.

This project is independent and is not affiliated with or endorsed by OpenAI.
Codex, ChatGPT, and OpenAI are trademarks of OpenAI.
