// Derives the app icon from the real Dawri mark, so the wordmark is never redrawn or retyped.
//
//   swift ios/Tools/make-icon.swift <source.png> <appicon folder> <wordmark folder>
//
//   swift ios/Tools/make-icon.swift frontend/public/icons/icon-512.png \
//       ios/Dawri/Assets.xcassets/AppIcon.appiconset \
//       ios/Dawri/Assets.xcassets/Wordmark.imageset
//
// Writes AppIcon.png, AppIcon-Dark.png and AppIcon-Tinted.png (1024x1024, sRGB, no alpha, because
// App Store Connect rejects icons with transparency), and Wordmark.png (612x304, the same mask as
// alpha over black, for the S01 lockup). Colours and method are section 10 of iOS Design.md.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconSide = 1024

/// The mask is sharpened at four times icon size, then averaged down. Sharpening at icon size
/// leaves visible steps on shallow curves, because one source pixel is two icon pixels there.
let oversample = 4

/// The mark in the source, measured from it. The wordmark image is this box at icon scale.
let sourceBounds = (x: 103, y: 204, width: 306, height: 152)

struct Palette {
    let file: String
    let background: UInt32
    let wordmark: UInt32
}

let palettes = [
    Palette(file: "AppIcon.png", background: 0xF2F4F7, wordmark: 0x0A0A0A),
    Palette(file: "AppIcon-Dark.png", background: 0x101113, wordmark: 0xF4F4F5),
    // iOS tints by luminance, so the tinted variant is greys only: white on black.
    Palette(file: "AppIcon-Tinted.png", background: 0x000000, wordmark: 0xFFFFFF),
]

enum IconError: Error {
    case usage, read(String), context, image, write(String)
}

func channels(_ rgb: UInt32) -> [Float] {
    [Float((rgb >> 16) & 0xFF), Float((rgb >> 8) & 0xFF), Float(rgb & 0xFF)]
}

func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
    0.2126 * r + 0.7152 * g + 0.0722 * b
}

func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
    let t = min(max((x - low) / (high - low), 0), 1)
    return t * t * (3 - 2 * t)
}

func loadSRGB(_ url: URL) throws -> (pixels: [UInt8], width: Int, height: Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw IconError.read(url.path) }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { throw IconError.context }
    return (pixels, width, height)
}

/// 1 on the wordmark, 0 on the ground. Top row first.
func sourceMask(_ pixels: [UInt8], width: Int, height: Int) -> [Float] {
    let ground = channels(palettes[0].background)
    let ink = channels(palettes[0].wordmark)
    let groundLuma = luma(ground[0], ground[1], ground[2])
    let inkLuma = luma(ink[0], ink[1], ink[2])
    return (0..<(width * height)).map { index in
        let r = Float(pixels[index * 4]), g = Float(pixels[index * 4 + 1]), b = Float(pixels[index * 4 + 2])
        return min(max((groundLuma - luma(r, g, b)) / (groundLuma - inkLuma), 0), 1)
    }
}

/// Resamples a mask with Core Graphics' high-quality filter, in 32-bit float so a soft source
/// edge keeps its gradient and does not quantise into steps.
func resample(_ mask: [Float], from: Int, to: Int) throws -> [Float] {
    let space = CGColorSpace(name: CGColorSpace.linearGray)!
    let info = CGImageAlphaInfo.none.rawValue
        | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    var input = mask
    let image: CGImage? = input.withUnsafeMutableBytes { buffer in
        CGContext(
            data: buffer.baseAddress, width: from, height: from, bitsPerComponent: 32,
            bytesPerRow: from * 4, space: space, bitmapInfo: info
        )?.makeImage()
    }
    guard let image else { throw IconError.image }
    var output = [Float](repeating: 0, count: to * to)
    let drawn: Bool = output.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress, width: to, height: to, bitsPerComponent: 32,
            bytesPerRow: to * 4, space: space, bitmapInfo: info
        ) else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: to, height: to))
        return true
    }
    guard drawn else { throw IconError.context }
    return output
}

/// Averages each square block of `factor` pixels, which gives the sharpened edge true antialiasing.
func boxDown(_ mask: [Float], side: Int, factor: Int) -> [Float] {
    let smallSide = side / factor
    var output = [Float](repeating: 0, count: smallSide * smallSide)
    for y in 0..<side {
        for x in 0..<side {
            output[(y / factor) * smallSide + x / factor] += mask[y * side + x]
        }
    }
    let area = Float(factor * factor)
    return output.map { $0 / area }
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw IconError.write(url.path) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.write(url.path) }
    print("Wrote \(url.path)")
}

func renderIcon(_ palette: Palette, mask: [Float], into folder: URL) throws {
    let background = channels(palette.background)
    let wordmark = channels(palette.wordmark)
    var pixels = [UInt8](repeating: 0, count: iconSide * iconSide * 4)
    for index in 0..<(iconSide * iconSide) {
        let m = mask[index]
        for channel in 0..<3 {
            let value = background[channel] * (1 - m) + wordmark[channel] * m
            pixels[index * 4 + channel] = UInt8(value.rounded())
        }
    }
    // noneSkipLast: RGB with a padding byte, so the PNG has no alpha channel.
    let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
        CGContext(
            data: buffer.baseAddress, width: iconSide, height: iconSide, bitsPerComponent: 8,
            bytesPerRow: iconSide * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage()
    }
    guard let image else { throw IconError.image }
    try writePNG(image, to: folder.appending(path: palette.file))
}

/// The mask as alpha over black, cropped to the mark. Template rendering tints it in the app.
func renderWordmark(mask: [Float], scale: Int, into folder: URL) throws {
    let width = sourceBounds.width * scale, height = sourceBounds.height * scale
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let source = (y + sourceBounds.y * scale) * iconSide + x + sourceBounds.x * scale
            // Black, so premultiplied and straight are the same bytes: only alpha is set.
            pixels[(y * width + x) * 4 + 3] = UInt8((mask[source] * 255).rounded())
        }
    }
    let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
        CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
    guard let image else { throw IconError.image }
    try writePNG(image, to: folder.appending(path: "Wordmark.png"))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
    print("usage: swift make-icon.swift <source.png> <appicon folder> <wordmark folder>")
    throw IconError.usage
}
let source = try loadSRGB(URL(fileURLWithPath: arguments[0]))
guard source.width == source.height, iconSide % source.width == 0 else {
    throw IconError.read("\(arguments[0]) must be square, and divide \(iconSide) evenly")
}
let raw = sourceMask(source.pixels, width: source.width, height: source.height)
let working = iconSide * oversample
let sharpened = try resample(raw, from: source.width, to: working).map { smoothstep(0.25, 0.75, $0) }
let mask = boxDown(sharpened, side: working, factor: oversample)

for palette in palettes {
    try renderIcon(palette, mask: mask, into: URL(fileURLWithPath: arguments[1]))
}
try renderWordmark(
    mask: mask, scale: iconSide / source.width, into: URL(fileURLWithPath: arguments[2]))
