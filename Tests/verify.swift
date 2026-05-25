// Standalone verifier — exercises pure functions copied from the main
// codebase so we can run `swift Tests/verify.swift` in CI without setting
// up an Xcode project. Each pure helper is inlined here verbatim to keep
// the test independent of the main module's compile graph.
//
// Run:  swift Tests/verify.swift
// Exit codes: 0 on success, 1 on assertion failure.

import Foundation

// MARK: - Test harness

var pass = 0
var fail = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String,
            file: String = #file, line: Int = #line) {
    if condition() {
        pass += 1
        print("  ✓ \(label)")
    } else {
        fail += 1
        print("  ✗ \(label)  (\((file as NSString).lastPathComponent):\(line))")
    }
}

func suite(_ name: String, _ body: () -> Void) {
    print("\n=== \(name) ===")
    body()
}

// MARK: - DiffusionFamily.detect (copy of the production logic)

enum DiffusionFamily: String {
    case flux, sd35, sdxl, sd15, wan21, ltx, unknown

    static func detect(path: String) -> DiffusionFamily {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.contains("flux") || name.contains("kontext") { return .flux }
        if name.contains("sd3.5") || name.contains("sd_3.5") || name.contains("sd35") { return .sd35 }
        if name.contains("sdxl") || name.contains("sd_xl") || name.contains("xl_turbo") || name.contains("sd-xl") { return .sdxl }
        if name.contains("wan2") || name.contains("wan_2") { return .wan21 }
        if name.contains("ltx") { return .ltx }
        if name.contains("v1-5") || name.contains("v2-1") || name.contains("stable-diffusion-v1")
            || name.contains("sd_1") || name.contains("sd_2") {
            return .sd15
        }
        return .unknown
    }
}

// MARK: - Shell escape (copy from ScriptedTool)

func shellEscape(_ s: String) -> String {
    "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func applyTemplate(_ template: String, _ args: [String: String]) -> String {
    var out = template
    for (k, v) in args {
        out = out.replacingOccurrences(of: "{{\(k)}}", with: shellEscape(v))
    }
    return out
}

// MARK: - prettifyModelName (copy from App.swift)

func prettifyModelName(_ raw: String) -> String {
    var s = raw
    for ext in [".gguf", ".safetensors", ".bin"] {
        if s.lowercased().hasSuffix(ext) { s = String(s.dropLast(ext.count)) }
    }
    if let r = s.range(of: #"(?i)[-_](q\d+(_[A-Za-z0-9]+)*|f16|bf16|f32|fp16|fp32|iq\d[A-Za-z_]*)$"#,
                        options: .regularExpression) {
        s = String(s[..<r.lowerBound])
    }
    s = s.replacingOccurrences(of: "-Instruct", with: "")
    s = s.replacingOccurrences(of: "-chat",     with: "")
    return s
}

// MARK: - SemVer comparison (copy from UpdateChecker)

func isNewer(remote: String, local: String) -> Bool {
    let r = remote.split(separator: ".").map { Int($0) ?? 0 }
    let l = local.split(separator: ".").map { Int($0) ?? 0 }
    let pad = max(r.count, l.count)
    let rp = r + Array(repeating: 0, count: pad - r.count)
    let lp = l + Array(repeating: 0, count: pad - l.count)
    for (rv, lv) in zip(rp, lp) {
        if rv > lv { return true }
        if rv < lv { return false }
    }
    return false
}

// MARK: - Test suites

suite("DiffusionFamily.detect") {
    expect(DiffusionFamily.detect(path: "flux1-schnell-Q4_K_S.gguf") == .flux,
           "FLUX schnell GGUF")
    expect(DiffusionFamily.detect(path: "flux1-kontext-dev-Q4.gguf") == .flux,
           "FLUX Kontext")
    expect(DiffusionFamily.detect(path: "sd3.5_large-Q4_0.gguf") == .sd35,
           "SD3.5 with dot notation")
    expect(DiffusionFamily.detect(path: "sd_3.5_large.safetensors") == .sd35,
           "SD3.5 with underscore notation")
    expect(DiffusionFamily.detect(path: "sd35_medium.gguf") == .sd35,
           "SD3.5 no-dot")
    expect(DiffusionFamily.detect(path: "sd_xl_turbo_1.0.q8_0.gguf") == .sdxl,
           "SDXL Turbo")
    expect(DiffusionFamily.detect(path: "sd-xl-base-1.0.safetensors") == .sdxl,
           "SD-XL with hyphens")
    expect(DiffusionFamily.detect(path: "wan2.1-t2v-14b-Q3_K_S.gguf") == .wan21,
           "Wan 2.1 T2V")
    expect(DiffusionFamily.detect(path: "wan_2_1_i2v.gguf") == .wan21,
           "Wan 2.1 underscore")
    expect(DiffusionFamily.detect(path: "ltxv-2b-0.9.6-dev-q4_k_s.gguf") == .ltx,
           "LTX Video")
    expect(DiffusionFamily.detect(path: "v1-5-pruned.safetensors") == .sd15,
           "SD 1.5")
    expect(DiffusionFamily.detect(path: "random_model.safetensors") == .unknown,
           "Unknown falls through")
    // /full/paths/
    expect(DiffusionFamily.detect(path: "/Users/foo/models/flux/flux1-dev.gguf") == .flux,
           "Full path FLUX")
}

suite("Shell escape & template substitution") {
    expect(shellEscape("simple") == "'simple'", "simple")
    expect(shellEscape("with space") == "'with space'", "with space")
    expect(shellEscape("path with 'quotes'") == "'path with '\\''quotes'\\'''",
           "single quote escape")
    // Injection attempt — should NOT break out of the single-quote wrap
    let injected = shellEscape("hi'; rm -rf /; echo 'oops")
    expect(injected == "'hi'\\''; rm -rf /; echo '\\''oops'",
           "injection escape")
    // Template substitution
    let cmd = applyTemplate("wc -w {{path}}", ["path": "/tmp/file with space.txt"])
    expect(cmd == "wc -w '/tmp/file with space.txt'",
           "template substitution preserves spaces")
}

suite("prettifyModelName") {
    expect(prettifyModelName("flux1-schnell-Q4_K_S.gguf") == "flux1-schnell",
           "FLUX schnell stripped")
    expect(prettifyModelName("Llama-3.2-3B-Instruct-Q4_K_M.gguf") == "Llama-3.2-3B",
           "Llama instruct stripped")
    expect(prettifyModelName("sd3.5_large-Q8_0.safetensors") == "sd3.5_large",
           "SD3.5 safetensors")
    expect(prettifyModelName("ae.safetensors") == "ae",
           "ae VAE")
    expect(prettifyModelName("simple_name") == "simple_name",
           "plain name passthrough")
    expect(prettifyModelName("model-f16.safetensors") == "model",
           "fp suffix stripped")
}

suite("UpdateChecker.isNewer (SemVer)") {
    func test(_ r: String, _ l: String, _ expected: Bool, _ name: String) {
        expect(isNewer(remote: r, local: l) == expected, name)
    }
    test("3.0.3", "3.0.2", true,  "patch bump")
    test("3.1.0", "3.0.9", true,  "minor bump beats high patch")
    test("4.0.0", "3.9.9", true,  "major bump")
    test("3.0.2", "3.0.2", false, "equal")
    test("3.0.1", "3.0.2", false, "remote older patch")
    test("2.9.9", "3.0.0", false, "remote older major")
    test("3.0.10", "3.0.9", true, "double-digit patch")
    test("3.0",   "3.0.0", false, "short-equal padded with zeros")
    test("3.0.1", "3.0",   true,  "remote longer wins on extra non-zero")
}

// MARK: - Agent.isContextOverflowError (copy of detector logic)

func isContextOverflowError(_ message: String) -> Bool {
    let lower = message.lowercased()
    return lower.contains("exceed_context_size_error")
        || lower.contains("exceeds the available context size")
        || lower.contains("context size")
}

suite("Agent context-overflow detection") {
    expect(isContextOverflowError(#"{"error":{"code":400,"message":"request (29568 tokens) exceeds the available context size (8192 tokens), try increasing it","type":"exceed_context_size_error","n_prompt_tokens":29568,"n_ctx":8192}}"#),
           "canonical 400 from user report")
    expect(isContextOverflowError("HTTP 400: exceed_context_size_error"),
           "short error_type form")
    expect(!isContextOverflowError("Server: HTTP 503 — service unavailable"),
           "rejects unrelated server errors")
    expect(!isContextOverflowError("connection refused"),
           "rejects network errors")
}

// MARK: - Result

print("\n────────────────────────────────────────")
print("  \(pass) passed, \(fail) failed")
print("────────────────────────────────────────")
exit(fail == 0 ? 0 : 1)
