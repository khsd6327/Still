#!/usr/bin/env swift

import AppKit
import Foundation

struct FrameMetrics: Encodable {
    let width: Int
    let height: Int
    let nonBlackRatio: Double
    let luminanceVariance: Double
}

struct MotionMetrics: Encodable {
    let meanChannelDifference: Double
    let changedPixelRatio: Double
}

struct VisualSmokeResult: Encodable {
    let contractID = "app.stillproject.visual-smoke"
    let schemaVersion = 1
    let mode: String
    let passed: Bool
    let frames: [FrameMetrics]
    let motion: MotionMetrics?
}

enum SmokeError: Error, LocalizedError {
    case usage
    case unreadableImage(String)
    case sizeMismatch
    case blankFrame
    case staticFrame

    var errorDescription: String? {
        switch self {
        case .usage:
            "usage: verify-visual-smoke.swift ui FRAME.png | motion FRAME1.png FRAME2.png"
        case .unreadableImage(let path): "The image could not be decoded: \(path)"
        case .sizeMismatch: "Motion frames must have the same dimensions."
        case .blankFrame: "A frame is blank or lacks enough visual structure."
        case .staticFrame: "The two frames do not contain enough visual change."
        }
    }
}

struct DecodedFrame {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    let metrics: FrameMetrics
}

func decode(_ path: String) throws -> DecodedFrame {
    let url = URL(filePath: path)
    guard let image = NSImage(contentsOf: url),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw SmokeError.unreadableImage(path)
    }
    let width = cgImage.width
    let height = cgImage.height
    guard width >= 64, height >= 64 else { throw SmokeError.blankFrame }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw SmokeError.unreadableImage(path) }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var count = 0
    var nonBlack = 0
    var sum = 0.0
    var sumSquares = 0.0
    let stride = max(1, min(width, height) / 256)
    for y in Swift.stride(from: 0, to: height, by: stride) {
        for x in Swift.stride(from: 0, to: width, by: stride) {
            let index = (y * width + x) * 4
            let r = Double(bytes[index])
            let g = Double(bytes[index + 1])
            let b = Double(bytes[index + 2])
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if luminance > 10 { nonBlack += 1 }
            sum += luminance
            sumSquares += luminance * luminance
            count += 1
        }
    }
    let mean = sum / Double(count)
    let variance = max(0, sumSquares / Double(count) - mean * mean)
    return DecodedFrame(
        width: width,
        height: height,
        bytes: bytes,
        metrics: FrameMetrics(
            width: width,
            height: height,
            nonBlackRatio: Double(nonBlack) / Double(count),
            luminanceVariance: variance
        )
    )
}

func requireRendered(_ frame: DecodedFrame) throws {
    guard frame.metrics.nonBlackRatio >= 0.05,
          frame.metrics.luminanceVariance >= 25 else {
        throw SmokeError.blankFrame
    }
}

func compare(_ first: DecodedFrame, _ second: DecodedFrame) throws -> MotionMetrics {
    guard first.width == second.width, first.height == second.height else {
        throw SmokeError.sizeMismatch
    }
    var difference = 0.0
    var changed = 0
    var count = 0
    let stride = max(1, min(first.width, first.height) / 256)
    for y in Swift.stride(from: 0, to: first.height, by: stride) {
        for x in Swift.stride(from: 0, to: first.width, by: stride) {
            let index = (y * first.width + x) * 4
            let pixelDifference = (0 ..< 3).reduce(0.0) {
                $0 + abs(Double(first.bytes[index + $1]) - Double(second.bytes[index + $1]))
            } / 3.0
            difference += pixelDifference
            if pixelDifference >= 4 { changed += 1 }
            count += 1
        }
    }
    let metrics = MotionMetrics(
        meanChannelDifference: difference / Double(count),
        changedPixelRatio: Double(changed) / Double(count)
    )
    guard metrics.meanChannelDifference >= 1,
          metrics.changedPixelRatio >= 0.01 else {
        throw SmokeError.staticFrame
    }
    return metrics
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first else { throw SmokeError.usage }
    let frames: [DecodedFrame]
    let motion: MotionMetrics?
    switch mode {
    case "ui" where arguments.count == 2:
        frames = [try decode(arguments[1])]
        try requireRendered(frames[0])
        motion = nil
    case "motion" where arguments.count == 3:
        frames = [try decode(arguments[1]), try decode(arguments[2])]
        try frames.forEach(requireRendered)
        motion = try compare(frames[0], frames[1])
    default:
        throw SmokeError.usage
    }
    let result = VisualSmokeResult(
        mode: mode,
        passed: true,
        frames: frames.map(\.metrics),
        motion: motion
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(result), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    Foundation.exit(EXIT_FAILURE)
}
