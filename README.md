# Duanduan Codex Companion

A tiny open-source macOS companion that gives your Codex desktop pet a live
usage dashboard, follows local conversation progress, and makes Duanduan jump
out and knock when Codex needs you or only 10% remains.

![Duanduan Codex Usage demo](docs/demo-dashboard.png)

When the remaining quota reaches zero, Duanduan collapses and stays down until
the quota becomes available again:

![Duanduan fainted state](docs/fainted-state.png)

## What it shows

- A compact cyan-blue transparent panel; the expanded view adds a colored blur for readability
- Live Codex conversation states: working, needs input, ready, and blocked
- Privacy-safe progress labels such as analyzing, editing files, running commands, and checking the UI
- Up to eight recent active conversations, prioritized by attention needed
- Elapsed time and tool-call count for each active conversation
- Automatic respect for the macOS Reduce Motion accessibility setting
- Every active Codex rate-limit window
- Used and remaining percentage
- Window duration and reset time
- ChatGPT plan, extra balance, spend-control state, and reset credits
- Today, 7-day, 30-day, and lifetime token activity
- Peak daily tokens, longest turn, and usage streaks
- Full daily token history and a compact trend chart

When any active limit reaches **10% remaining or less**, Duanduan:

- jumps and waves a paw like knocking
- shakes the floating panel
- plays a sound
- sends a macOS notification

At **0% remaining**, Duanduan plays a one-shot collapse animation and remains
fainted. The normal idle animation returns automatically after the quota
recovers.

The automatic warning fires once per reset window. A built-in test button lets
you preview it at any time.

## Conversation companion

Duanduan watches the local Codex rollout event stream in read-only mode. It
does not attach to, steer, interrupt, or modify a conversation.

- **Working:** Duanduan animates and reports the current activity category.
- **Needs input:** Duanduan knocks, expands the activity panel, and sends a
  macOS notification.
- **Ready:** Duanduan celebrates and marks the conversation as unread until
  you open it.
- **Blocked:** Duanduan shows a failed state and asks you to inspect the task.

Select an activity to open its original conversation through the local
`codex://threads/<id>` deep link. Text progress is always available. Optional
Chinese voice announcements can be enabled from the activity panel or menu-bar
menu; voice progress is throttled so normal tool activity is not noisy.

Codex does not expose a trustworthy completion percentage. Duanduan reports
real phases, duration, and tool activity rather than inventing a percentage.

## Requirements

- macOS 13 or newer
- ChatGPT/Codex desktop app installed
- Signed in to Codex with ChatGPT
- Xcode Command Line Tools for building from source

## Install

```bash
git clone https://github.com/dantong0814-a11y/duanduan-codex-usage.git
cd duanduan-codex-usage
./scripts/install.sh
```

The installer builds the app locally, places it at
`~/Applications/Duanduan Usage.app`, and adds a per-user login LaunchAgent.

## Use

- Click Duanduan or the arrow to expand the complete dashboard.
- Use the paw icon in the macOS menu bar to refresh, test the warning, hide the
  panel, toggle conversation monitoring or voice progress, or quit.
- Drag the floating panel to move it.
- Data refreshes every 60 seconds.

## Uninstall

```bash
./scripts/uninstall.sh
```

## Build without installing

```bash
./scripts/build.sh
open "build/Duanduan Usage.app" --args --demo --expanded
```

`--demo` uses generated sample data and never reads an account or local
conversation. Add
`--test-alarm` to preview the 10% warning, or `--test-fainted` to preview the
0% collapse state. Add `--test-activity` to preview working, needs-input,
ready, and blocked states.

## Data accuracy and limitations

The app reads the local Codex app-server methods
`account/rateLimits/read` and `account/usage/read`. It uses the existing local
ChatGPT sign-in and does not store passwords or API keys.

The account endpoint reports total token activity by day and lifetime totals.
It does **not** provide account-level input/output/cached-token splits, so this
project does not estimate or fabricate those values. Daily buckets may also be
reported with a delay.

Codex app-server is experimental, so a future Codex update may require a
protocol adjustment.

Conversation progress is derived from structured local rollout events under
the current Codex home folder. The monitor reads only event metadata needed for
state, timing, workspace name, and tool category. It does not display message
text, reasoning content, command output, or file contents. Because the local
rollout format is an internal integration surface, future Codex versions may
also require parser updates.

See [PRIVACY.md](PRIVACY.md) for the complete privacy statement.

## 中文说明

这是一个 macOS 本机小助手：显示 Codex 订阅额度、Token 活动和真实对话进度；
工作中会播报“分析、编辑文件、执行命令”等阶段，需要确认时短短会敲门，
完成后会庆祝并可点击返回原对话。当任一额度只剩 10% 时，短短也会提醒。
额度变成 0% 时，短短会晕倒并保持趴下；额度恢复后自动醒来。

安装后不会读取或保存密码、API Key。所有数据都通过本机 Codex 登录状态读取，
对话监听只解析状态所需的事件类型，不展示完整消息、推理、命令输出或文件内容。
Codex 没有提供可靠的完成百分比，因此不会自行估算。

## License

MIT. The bundled Duanduan sprite frames are included under the same license.

This project is independent and is not affiliated with or endorsed by OpenAI.
