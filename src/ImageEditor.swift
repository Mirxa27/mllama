import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import SwiftUI

// MARK: - Edit operations

enum ImageEditOp: Hashable {
    case crop(CGRect)               // in pixels of source
    case rotate(Double)             // degrees clockwise
    case flip(horizontal: Bool)
    case resize(CGSize)
    case brightness(Double)         // -1...1
    case contrast(Double)           // 0...4 (1 = identity)
    case saturation(Double)         // 0...4 (1 = identity)
    case exposure(Double)           // -10...10
    case gamma(Double)              // > 0 (1 = identity)
    case hueRotate(Double)          // radians
    case temperature(Double)        // Kelvin shift, e.g. 6500 -> 5000 = warmer
    case vibrance(Double)           // -1...1
    case sharpen(Double)            // 0...10
    case blur(Double)               // pixel radius
    case noiseReduction(Double)     // 0...0.1
    case vignette(Double, radius: Double)   // intensity 0..2, radius in pixels
    case sepia(Double)              // 0..1
    case mono                       // black & white
    case invert
    case pixellate(Double)          // pixel size
    case crystallize(Double)        // radius
    case bloom(Double, radius: Double)
    case lut3d(URL)                 // .cube file path

    var label: String {
        switch self {
        case .crop:           return "Crop"
        case .rotate:         return "Rotate"
        case .flip:           return "Flip"
        case .resize:         return "Resize"
        case .brightness:     return "Brightness"
        case .contrast:       return "Contrast"
        case .saturation:     return "Saturation"
        case .exposure:       return "Exposure"
        case .gamma:          return "Gamma"
        case .hueRotate:      return "Hue"
        case .temperature:    return "Temperature"
        case .vibrance:       return "Vibrance"
        case .sharpen:        return "Sharpen"
        case .blur:           return "Blur"
        case .noiseReduction: return "Denoise"
        case .vignette:       return "Vignette"
        case .sepia:          return "Sepia"
        case .mono:           return "Mono"
        case .invert:         return "Invert"
        case .pixellate:      return "Pixellate"
        case .crystallize:    return "Crystallize"
        case .bloom:          return "Bloom"
        case .lut3d:          return "LUT 3D"
        }
    }
}

// MARK: - Editor

/// Pure Core Image pipeline: an ordered list of operations applied to a source image.
@MainActor
final class ImageEditor: ObservableObject {
    @Published var sourceURL: URL?
    @Published private(set) var sourceImage: CIImage?
    @Published var operations: [ImageEditOp] = []

    private let ctx = CIContext(options: [.useSoftwareRenderer: false])

    func load(url: URL) {
        sourceURL = url
        guard let img = CIImage(contentsOf: url) else {
            sourceImage = nil
            return
        }
        sourceImage = img
        operations.removeAll()
    }

    func resetToSource() {
        operations.removeAll()
    }

    func undoLast() {
        if !operations.isEmpty { operations.removeLast() }
    }

    func append(_ op: ImageEditOp) { operations.append(op) }

    /// Current preview image (pipeline applied).
    var renderedCI: CIImage? {
        guard let src = sourceImage else { return nil }
        var img = src
        for op in operations { img = ImageEditor.apply(op, to: img) }
        return img
    }

    func renderedNSImage(maxDimension: CGFloat = 1600) -> NSImage? {
        guard var ci = renderedCI else { return nil }
        // Downscale for preview only.
        let s = max(ci.extent.width, ci.extent.height)
        if s > maxDimension {
            let scale = maxDimension / s
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: ci.extent.width, height: ci.extent.height))
    }

    /// Render to a PNG at full resolution and save next to source. Returns saved URL.
    func exportPNG(to dir: URL? = nil, filename: String? = nil) -> URL? {
        guard let ci = renderedCI else { return nil }
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        let baseDir = dir
            ?? (sourceURL?.deletingLastPathComponent()
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mllama/media"))
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let base = (sourceURL?.deletingPathExtension().lastPathComponent ?? "image")
            + "-edit-" + DateFormatter.compactStamp.string(from: Date())
        let outURL = baseDir.appendingPathComponent(filename ?? "\(base).png")
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        do { try data.write(to: outURL); return outURL } catch { return nil }
    }

    // MARK: - Static pipeline application

    static func apply(_ op: ImageEditOp, to input: CIImage) -> CIImage {
        switch op {
        case .crop(let r):
            return input.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.origin.x, y: -r.origin.y))
        case .rotate(let deg):
            let rad = deg * .pi / 180
            return input.transformed(by: CGAffineTransform(rotationAngle: rad))
        case .flip(let h):
            let t = h
                ? CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -input.extent.width, y: 0)
                : CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -input.extent.height)
            return input.transformed(by: t)
        case .resize(let size):
            let sx = size.width / max(1, input.extent.width)
            let sy = size.height / max(1, input.extent.height)
            return input.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        case .brightness(let v):
            let f = CIFilter.colorControls()
            f.inputImage = input; f.brightness = Float(v); f.contrast = 1; f.saturation = 1
            return f.outputImage ?? input
        case .contrast(let v):
            let f = CIFilter.colorControls()
            f.inputImage = input; f.brightness = 0; f.contrast = Float(v); f.saturation = 1
            return f.outputImage ?? input
        case .saturation(let v):
            let f = CIFilter.colorControls()
            f.inputImage = input; f.brightness = 0; f.contrast = 1; f.saturation = Float(v)
            return f.outputImage ?? input
        case .exposure(let v):
            let f = CIFilter.exposureAdjust()
            f.inputImage = input; f.ev = Float(v)
            return f.outputImage ?? input
        case .gamma(let v):
            let f = CIFilter.gammaAdjust()
            f.inputImage = input; f.power = Float(v)
            return f.outputImage ?? input
        case .hueRotate(let r):
            let f = CIFilter.hueAdjust()
            f.inputImage = input; f.angle = Float(r)
            return f.outputImage ?? input
        case .temperature(let k):
            let f = CIFilter.temperatureAndTint()
            f.inputImage = input
            f.neutral = CIVector(x: CGFloat(k), y: 0)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            return f.outputImage ?? input
        case .vibrance(let v):
            let f = CIFilter.vibrance()
            f.inputImage = input; f.amount = Float(v)
            return f.outputImage ?? input
        case .sharpen(let v):
            let f = CIFilter.sharpenLuminance()
            f.inputImage = input; f.sharpness = Float(v)
            return f.outputImage ?? input
        case .blur(let r):
            let f = CIFilter.gaussianBlur()
            f.inputImage = input; f.radius = Float(r)
            return (f.outputImage ?? input).cropped(to: input.extent)
        case .noiseReduction(let v):
            let f = CIFilter.noiseReduction()
            f.inputImage = input; f.noiseLevel = Float(v); f.sharpness = 0.4
            return f.outputImage ?? input
        case .vignette(let intensity, let radius):
            let f = CIFilter.vignette()
            f.inputImage = input; f.intensity = Float(intensity); f.radius = Float(radius)
            return f.outputImage ?? input
        case .sepia(let v):
            let f = CIFilter.sepiaTone()
            f.inputImage = input; f.intensity = Float(v)
            return f.outputImage ?? input
        case .mono:
            let f = CIFilter.photoEffectMono()
            f.inputImage = input
            return f.outputImage ?? input
        case .invert:
            let f = CIFilter.colorInvert()
            f.inputImage = input
            return f.outputImage ?? input
        case .pixellate(let s):
            let f = CIFilter.pixellate()
            f.inputImage = input; f.scale = Float(s)
            return f.outputImage ?? input
        case .crystallize(let r):
            let f = CIFilter.crystallize()
            f.inputImage = input; f.radius = Float(r)
            return f.outputImage ?? input
        case .bloom(let intensity, let radius):
            let f = CIFilter.bloom()
            f.inputImage = input; f.intensity = Float(intensity); f.radius = Float(radius)
            return f.outputImage ?? input
        case .lut3d:
            // .cube parsing is non-trivial; out of scope here. Pass-through.
            return input
        }
    }
}

// MARK: - Quick filter presets

enum ImagePreset: String, CaseIterable, Identifiable {
    case original, dramatic, lush, cool, warm, noir, faded, sharp
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var ops: [ImageEditOp] {
        switch self {
        case .original:  return []
        case .dramatic:  return [.contrast(1.25), .saturation(1.1), .vignette(0.55, radius: 1200)]
        case .lush:      return [.saturation(1.3), .vibrance(0.35), .contrast(1.1)]
        case .cool:      return [.temperature(7800), .saturation(0.95)]
        case .warm:      return [.temperature(5200), .saturation(1.05)]
        case .noir:      return [.mono, .contrast(1.4), .vignette(0.75, radius: 1100)]
        case .faded:     return [.contrast(0.85), .saturation(0.85), .gamma(1.15)]
        case .sharp:     return [.sharpen(0.8)]
        }
    }
}
