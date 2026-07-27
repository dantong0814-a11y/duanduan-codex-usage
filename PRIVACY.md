# Privacy

Duanduan Codex Usage is a local macOS menu-bar and floating-panel app.

- It does not ask for or store an OpenAI password, API key, or access token.
- It reads usage through the locally installed Codex `app-server`, which uses
  the active ChatGPT/Codex sign-in.
- It stores only a small local alert marker in `UserDefaults` so the 10%
  warning is not repeated during the same reset window.
- It does not include telemetry, analytics, advertising, or a project-owned
  server.
- The account-level Codex endpoint exposes total daily token activity. It does
  not expose an input/output/cached-token breakdown, so the app does not invent
  one.

Codex `app-server` is currently experimental. Its protocol may change in a
future Codex release.

This project is independent and is not affiliated with or endorsed by OpenAI.
Codex, ChatGPT, and OpenAI are trademarks of OpenAI.
