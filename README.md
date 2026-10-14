# System Diagnostics

A bar widget for [Omarchy](https://omarchy.org) that runs a **read-only** health
scan of the machine, shows a traffic-light verdict in the bar, and produces a
report written to be pasted into — or sent straight to — an AI assistant.

Everything it reports is something the machine itself already said: it inspects
the kernel log, systemd, the package database, Hyprland, the network and the
GPU, and never changes a single thing.

## Features

- **Traffic-light bar indicator** — green when all checks pass, amber when
  something needs attention, red when there is a real problem. "Could not check"
  is shown amber, never green: an unrun probe is not a pass.
- **Quick scan** — local only, a few seconds (system, Omarchy, systemd, journal,
  storage, packages, security).
- **Full scan** — adds the slower probes (network reachability and DNS, GPU
  drivers and Vulkan, SMART disk health, package updates, `pacman -Qkk`).
- **AI-ready output** — a single click builds a prompt that states the verdict,
  lists every finding with its evidence, and asks the assistant for concrete
  fixes. Copy it, save it as Markdown/JSON, or **send it to your default AI
  agent** (see below).
- **Open, inspectable checks** — every finding carries an id, a value, a plain
  explanation and a suggested action. Nothing is a black box.

## Detecting your AI agent

The plugin does **not** hardcode an assistant. To send a report it asks Omarchy
which agent you chose:

```sh
omarchy default agent            # prints e.g. opencode, claude, codex, gemini…
```

The answer is read **per user**, from the downloader's own Omarchy configuration,
so the plugin always opens *their* agent — not the author's. Because it goes
through the CLI, the plugin carries no list of agents and works for any agent
Omarchy supports (`opencode`, `claude`, `codex`, `gemini`, `grok`, `copilot`,
`crush`, `cursor-agent`, `muse`, `pi`, `omp`, `hermes`, `openclaw`) without a
code change. Detection is re-run every time the panel opens, and the `omarchy`
binary is resolved from a short candidate list so a repackaged Omarchy cannot
break it on another machine.

That slug is shown in the panel (`Default AI agent: claude`) and on the button
(`Send to claude`). If a default is set, one click launches it through
`omarchy agent prompt` — which applies that agent's own non-interactive flags
and opens it in a terminal window with the report.

If **no** default agent is set, nothing is launched silently: the ready-to-paste
prompt is put on your clipboard and the panel tells you how to choose one:

```sh
omarchy default agent opencode  # or claude, codex, gemini, …
```

Nothing is ever sent on the plugin's own initiative — only when you click.

## Install

```sh
omarchy plugin add <git-url> --enable
```

Or copy this folder to `~/.config/omarchy/plugins/angelherman.system-diagnostics`
and enable it:

```sh
omarchy plugin enable angelherman.system-diagnostics
```

Then click the widget in the bar.

## Usage

| Action | Result |
| --- | --- |
| Left click the bar widget | Open the panel |
| Right click | Quick scan |
| Middle click | Full scan |
| `R` / `F` in the panel | Quick / Full scan |
| `A` | Copy the AI prompt |
| `S` | Save the Markdown report |
| `D` | Show all checks, not just findings |
| `Q` / `Esc` | Close |

Reports are saved under `~/.local/state/system-diagnostics/`.

## Privacy

Every check is read-only. The plugin never repairs, restarts, enables or
deletes anything; findings carry a *suggested* action, never an executed one.
The scan runs with a hardened `PATH=/usr/bin:/bin` and a minimal environment.
The only time anything leaves the machine is the moment you send the report to
your own AI agent.

## Requirements

Omarchy (with `omarchy-shell`). The scanner uses standard system tools and
degrades gracefully when one is missing: `jq`, `wl-clipboard`, `smartctl`,
`vulkaninfo`, `btrfs`, `ufw`/`nftables` and others are all optional and simply
produce an "unknown" result when absent.

## License

MIT.
