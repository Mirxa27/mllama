# Mllama architecture

A tour of the codebase. Read this once and the rest of the source becomes navigable.

## Top-level layout

```
build/
├── src/                    # All Swift source
│   ├── App.swift            ← entrypoint, AppDelegate, RootView, top bar
│   ├── Logging.swift        ← os.Logger categories
│   ├── KeychainStore.swift  ← secret storage (HF token)
│   ├── SystemIntegration.swift ← permissions, notifications, dock, URL scheme
│   ├── UpdateChecker.swift  ← GitHub Releases poller
│   ├── …                    ← subsystem files (Agent, ImageGenerator, etc.)
│   └── Views/               ← SwiftUI surface
├── Tests/verify.swift       # standalone pure-function test runner
├── Resources/PrivacyInfo.xcprivacy  # privacy manifest, copied at build time
├── build.sh                 # compile + patch Info.plist
├── notarize.sh              # sign + Apple-notarize + DMG round-trip
├── package.sh               # ad-hoc DMG for unsigned builds
├── .github/workflows/       # CI + release automation
└── (built artifacts)        # Mllama.app, dist/*.dmg — gitignored
```

## Subsystem map

```
┌────────────────────────────────────────────────────────────────┐
│                       SwiftUI Views                            │
│  ChatView · ImageStudio · VideoStudio · ModelPicker · …        │
└────────────────────────────────────────────────────────────────┘
       │                  │                    │
       ▼                  ▼                    ▼
┌────────────┐   ┌──────────────────┐   ┌────────────────┐
│   Agent    │   │  ImageGenerator  │   │ VideoGenerator │
│  (LLM loop │   │  (sd-server HTTP │   │   (sd-cli      │
│   + tools) │   │   client)        │   │   subprocess)  │
└────────────┘   └──────────────────┘   └────────────────┘
       │                  │                    │
       ▼                  ▼                    ▼
┌────────────────────────────────────────────────────────────────┐
│             llama-server / sd-server / sd-cli                  │
│   (subprocesses managed by ServerController / SDServerController)
└────────────────────────────────────────────────────────────────┘
       │                  │                    │
       └──────────────────┴────────────────────┴────────────┐
                                                            ▼
                                            ┌──────────────────────────┐
                                            │  UnifiedModelCatalog     │
                                            │  + ModelBundle resolver  │
                                            │  + HFDownloadManager     │
                                            └──────────────────────────┘
```

### Layer responsibilities

**Views** never own state — they bind to `@EnvironmentObject` and `@StateObject` instances. Each studio is a pure surface that consumes a generator.

**Generators** (`ImageGenerator`, `VideoGenerator`, `VideoPipeline`) drive the underlying engine and publish progress/results to SwiftUI.

**Server controllers** (`ServerController` for llama-server, `SDServerController` for sd-server) own a `Process` subprocess + its lifecycle. They probe HTTP endpoints to confirm readiness.

**Catalog & downloads** unify model state across local disk, LM Studio, Ollama, the HF cache, and curated catalog entries. The catalog is the single source of truth for "what models do we have, and what state are they in?"

**Self-improvement** (`SelfImprovement.swift` + `SelfImprovementTools.swift`) closes the loop: every tool call goes into a reflection log; the agent can `reflect`, `update_instructions`, or `create_tool` to evolve in-session. Persisted to `~/.mllama/agent/`.

## Data flow: image generation

```
User clicks Generate in ImageStudio
            │
            ▼
ImageStudio.triggerGenerate
            │
            ▼
ImageGenerator.generate(params)         ←  sets DockBadge, isGenerating
            │
            ▼
runGenerate detects DiffusionFamily      ←  if FLUX/SD3 + supportsSdcpp →
            │                                /sdcpp/v1/img_gen
            ▼
URLSession POST → sd-server (subprocess)
            │
            ▼
Server returns base64 PNG → save to ~/.mllama/media/
            │
            ▼
ImageGenResult inserted into results     →  NotificationCenterBridge.post
                                            if !NSApp.isActive
            │
            ▼
SwiftUI renders the new ImagePreview
```

## Data flow: companion files

When the user activates a FLUX checkpoint:

1. `UnifiedModelCatalog.activate(model)` writes the diffusion path into `UserDefaults[SDKeys.imageModelPath]`.
2. `autoLinkCompanions(for:isVideo:)` scans `~/.mllama/hf/` for T5, CLIP-L, VAE files matching the FLUX bundle.
3. Each found path is written into the corresponding `SDKeys.{t5,clipL,vae}Path` so sd-server's relaunch picks them up.
4. Missing companions get queued via `HFDownloadManager.enqueue` (T5 from city96, CLIP-L from comfyanonymous, VAE from Kijai).
5. `sdServer.restart()` — guarded by `imageGen.isGenerating` so we never yank the server out from under an in-flight request.

## Persistence locations

| Path | Owner | Format |
|---|---|---|
| `~/.mllama/diag.log` | `Log.diag` | text |
| `~/.mllama/hf/<author>/<repo>/<file>` | HFDownloadManager | binary |
| `~/.mllama/bin/{sd-server,sd-cli,ffmpeg}` | user via Quick Setup | mach-o |
| `~/.mllama/media/<name>.{png,mp4}` | image/video generators | binary |
| `~/.mllama/library.json` | MediaLibrary | JSON |
| `~/.mllama/prompts.json` | PromptLibrary | JSON |
| `~/.mllama/agent/reflection.jsonl` | ReflectionStore | JSONL |
| `~/.mllama/agent/prompt_history.json` | PromptEvolution | JSON |
| `~/.mllama/agent/dynamic_tools.json` | DynamicToolStore | JSON |
| Keychain (`org.mllama.app` / `hf.token`) | KeychainStore | secret |

## Key invariants

- **Single window.** No multi-window state to coordinate.
- **All UI on the main actor.** SwiftUI views are `@MainActor`; long work hops to `Task.detached` and comes back via `await MainActor.run`.
- **Server processes are owned by their controllers.** No view directly forks subprocesses.
- **Reflection records every tool call** including unknown-tool and approval-denied — the agent's reflection loop sees the complete behavioural trace.
- **Family detection is pure.** `DiffusionFamily.detect(path:)` takes only a string; tested in isolation via `Tests/verify.swift`.

## Concurrency model

- `@MainActor` everywhere SwiftUI lives.
- `actor ToolRegistry`, `actor ReflectionStore`, `actor PromptEvolution`, `actor DynamicToolStore` — each holds the canonical state for its slice.
- `Task.detached` for filesystem walks and CPU-bound work (`CompanionResolver.scanOffActor`, `VideoTranscoder.toMP4`).
- `Process` subprocesses use `terminationHandler` + `CheckedContinuation` patterns — never `waitUntilExit` (would block a cooperative thread).

## What's deliberately not here

- **No XCTest harness.** Pure-function tests run via `swift Tests/verify.swift`. SwiftUI/integration testing is manual.
- **No SwiftPM `Package.swift`.** The flat-file build is simpler for a single-developer project.
- **No analytics or telemetry.** Mllama is a local app; the privacy manifest declares `NSPrivacyTracking=false`.
- **No iCloud sync.** All state is local to one Mac. Future work could add export/import.
