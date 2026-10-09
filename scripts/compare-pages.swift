#!/usr/bin/env swift
import AppKit
import Foundation

struct Options {
    let reference: URL
    let actual: URL
    let channelThreshold: Int
    let maximumDifference: Double?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("오류: \(message)\n".utf8))
    exit(2)
}

func options() -> Options {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2, !arguments[0].isEmpty, !arguments[1].isEmpty else {
        fail("사용법: compare-pages.swift <한컴 PNG 폴더> <활자 PNG 폴더> [--threshold 0...255] [--max-diff-percent 0...100]")
    }
    var threshold = 8
    var maximum: Double?
    var index = 2
    while index < arguments.count {
        guard index + 1 < arguments.count else { fail("\(arguments[index]) 값이 없습니다") }
        switch arguments[index] {
        case "--threshold":
            guard let value = Int(arguments[index + 1]), (0 ... 255).contains(value) else {
                fail("--threshold는 0...255여야 합니다")
            }
            threshold = value
        case "--max-diff-percent":
            guard let value = Double(arguments[index + 1]), (0 ... 100).contains(value) else {
                fail("--max-diff-percent는 0...100이어야 합니다")
            }
            maximum = value
        default:
            fail("알 수 없는 옵션: \(arguments[index])")
        }
        index += 2
    }
    return Options(reference: URL(fileURLWithPath: arguments[0], isDirectory: true),
                   actual: URL(fileURLWithPath: arguments[1], isDirectory: true),
                   channelThreshold: threshold, maximumDifference: maximum)
}

func pngs(in directory: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles]) else {
        fail("폴더를 읽을 수 없습니다: \(directory.path)")
    }
    return files.filter { $0.pathExtension.lowercased() == "png" }.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
}

func rgba(_ url: URL) -> (width: Int, height: Int, bytes: [UInt8]) {
    guard let image = NSImage(contentsOf: url),
          let source = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
        fail("PNG를 읽을 수 없습니다: \(url.path)")
    }
    let width = source.pixelsWide
    let height = source.pixelsHigh
    guard let normalized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: width * 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: normalized) else {
        fail("픽셀 버퍼를 만들 수 없습니다: \(url.path)")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
               from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = normalized.bitmapData else { fail("픽셀을 읽을 수 없습니다: \(url.path)") }
    return (width, height, Array(UnsafeBufferPointer(start: data, count: height * normalized.bytesPerRow)))
}

let option = options()
let references = pngs(in: option.reference)
let actuals = pngs(in: option.actual)
guard !references.isEmpty else { fail("기준 폴더에 PNG가 없습니다") }
guard references.count == actuals.count else {
    fail("쪽 수가 다릅니다: 기준 \(references.count)쪽, 활자 \(actuals.count)쪽")
}

var failed = false
var totalDifferent = 0
var totalPixels = 0
for (page, pair) in zip(references, actuals).enumerated() {
    let reference = rgba(pair.0)
    let actual = rgba(pair.1)
    guard reference.width == actual.width, reference.height == actual.height else {
        print("\(page + 1)쪽: 크기 다름 (기준 \(reference.width)x\(reference.height), 활자 \(actual.width)x\(actual.height))")
        failed = true
        continue
    }
    var different = 0
    for pixel in 0 ..< reference.width * reference.height {
        let offset = pixel * 4
        if (0 ..< 4).contains(where: {
            abs(Int(reference.bytes[offset + $0]) - Int(actual.bytes[offset + $0])) > option.channelThreshold
        }) { different += 1 }
    }
    let pixels = reference.width * reference.height
    let percent = Double(different) * 100 / Double(pixels)
    print(String(format: "%d쪽: %.4f%% (%d/%d 픽셀) — %@ ↔ %@", page + 1, percent, different,
                 pixels, pair.0.lastPathComponent, pair.1.lastPathComponent))
    totalDifferent += different
    totalPixels += pixels
    if let maximum = option.maximumDifference, percent > maximum { failed = true }
}

if totalPixels > 0 {
    print(String(format: "전체: %.4f%% (%d/%d 픽셀), 채널 허용차 %d", Double(totalDifferent) * 100 / Double(totalPixels),
                 totalDifferent, totalPixels, option.channelThreshold))
}
exit(failed ? 1 : 0)
