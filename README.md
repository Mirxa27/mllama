# Mllama

A fully-local AI studio for macOS. Chat with LLMs, generate images and videos with
[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp), search and
download from HuggingFace, and expose the whole stack as a Model Context Protocol
server for other AI clients.

Built on top of [llama.cpp](https://github.com/ggerganov/llama.cpp). No cloud, no
telemetry, no API keys.

## What's in here

A SwiftUI macOS app with:

- **Chat** — local LLM agent with tool use, vision (mmproj), and MCP client/host.
- **Image Studio** — txt2img, img2img, inpaint, ControlNet, hires-fix, LoRA, family-aware
  defaults for FLUX / SD 3.5 / SDXL / SD 1.5.
- **Video Studio** — text-to-video and image-to-video via sd-cli (Wan 2.1, LTX),
  storyboard mode for multi-scene chained generation, FFmpeg-backed clip editor.
- **Models tab** — HuggingFace browser with size-aware filtering, curated picks,
  resumable downloads, automatic companion-file resolution (T5 / CLIP-L / VAE).
- **Settings → Evolution** — the agent can `reflect` on its own tool-call failures,
  `update_instructions` to rewrite its own system prompt, and `create_tool` to
  author new shell-backed tools that become callable on the next turn.
- **MCP server** — host Mllama's image/video/HF tools to Claude Desktop, Cursor,
  Continue, etc. over HTTP `:3737/mcp`.

## Requirements

- macOS 13.0 (Ventura) or newer
- Apple Silicon (arm64) recommended; Intel untested
- 16 GB RAM recommended for FLUX / SDXL; 8 GB works for small chat models

Bundled (in app Resources): `llama-server`, `whisper-cli`, and the GGML dylib chain.

User-installable (via in-app Quick Setup):

- `ffmpeg` (Homebrew) — video editing
- `sd-server` + `sd-cli` from stable-diffusion.cpp — image & video generation

## Build from source

```bash
git clone https://github.com/Mirxa27/mllama.git
cd mllama
./build.sh release          # debug omit to skip optimization
./build.sh release --run    # launch after building

./package.sh                # produces dist/Mllama-<version>-arm64.dmg
```

Requirements:

- Xcode command-line tools (Swift 5.9+)
- macOS 13 SDK

The build script compiles every `.swift` file under `src/` into one Mach-O
binary, stamps an `rpath`, and ad-hoc codesigns it.

## Repository layout

```
src/                          # Swift source (52 files)
├── App.swift                 # entrypoint, bootstrap, top bar
├── Agent.swift               # LLM agent loop with tool use
├── Server.swift              # llama-server subprocess manager
├── SDServer.swift            # sd-server subprocess manager (image gen)
├── ImageGenerator.swift      # /sdapi/v1/ + /sdcpp/v1/ HTTP client
├── VideoGenerator.swift      # sd-cli subprocess + webp→mp4 transcode
├── VideoPipeline.swift       # storyboard pipeline (multi-scene + stitch)
├── ModelLibrary.swift        # local model discovery (LM Studio / Ollama / disk)
├── ModelRecommender.swift    # curated HF catalog with companion entries
├── ModelBundle.swift         # family detection + companion requirements
├── UnifiedModelCatalog.swift # merge local + downloaded + curated, auto-link
├── HFDownloader.swift        # resumable HF download manager
├── HuggingFace.swift         # HF API client
├── SelfImprovement.swift     # reflection / prompt evolution / dynamic tools
├── SelfImprovementTools.swift# 5 AgentTools (reflect, update_instructions, …)
├── MCP.swift                 # MCP client (consume external MCP servers)
├── MCPServerHost.swift       # MCP server (expose Mllama to other clients)
├── Tools.swift               # AgentTool protocol + built-in tools
├── MediaTools.swift          # image/video generation tools for the agent
├── ...
└── Views/                    # SwiftUI surface
    ├── ImageStudio.swift
    ├── VideoStudio.swift
    ├── ModelPicker.swift
    ├── HuggingFaceBrowserView.swift
    ├── SettingsView.swift
    ├── EvolutionSettingsView.swift
    ├── CompanionBanner.swift
    └── ...

build.sh                      # release / debug build script
package.sh                    # release → strip → codesign → DMG
LICENSE                       # MIT
README.md                     # this file
```

## Self-improvement loop

The agent identifies where it's struggling, rewrites its own instructions, creates
new tools for itself, and uses those tools on its very next turn — all in-session.

```
reflect             → returns recent failures + recurring patterns from the last 30 min
update_instructions → replaces the system prompt (versioned, rollback in Settings)
create_tool         → authors a new ScriptedTool from a JSON schema + shell template
list_dynamic_tools  → introspect tools created at runtime
disable_tool        → remove a dynamic tool
```

Persistence at `~/.mllama/agent/`:

- `reflection.jsonl` — append-only tool-call outcome log
- `prompt_history.json` — versioned system prompts with rollback
- `dynamic_tools.json` — runtime-created ScriptedTools (re-registered on launch)

See [Settings → Evolution] in the app for a live UI of all three.

## Data locations

```
~/.mllama/hf/              # HuggingFace model cache (downloads)
~/.mllama/bin/             # sd-server / sd-cli (after Quick Setup builds them)
~/.mllama/media/           # generated images and videos
~/.mllama/library.json     # gallery index
~/.mllama/prompts.json     # saved prompts
~/.mllama/agent/           # self-improvement state (see above)
```

## Expose Mllama as MCP

Drop into `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "mllama": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:3737/mcp"]
    }
  }
}
```

Claude Desktop / Cursor / Continue can then call Mllama's `generate_image`,
`generate_video`, `search_huggingface`, etc. as tools.

## Keyboard shortcuts

```
⌘1 .. ⌘5      Switch workspaces (Chat / Image / Video / Models / MCP)
⌘K            Model picker (filter by ⌘1-3 for kind)
⌘N            New chat
⌘⇧R           Restart LLM server
⌘⌥R           Restart image server
⌘⇧K           Compact conversation
```

## License

MIT — see [LICENSE](LICENSE).

Built with:

- [llama.cpp](https://github.com/ggerganov/llama.cpp) (MIT)
- [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) (MIT)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (MIT)
- Swift / SwiftUI / AVFoundation
