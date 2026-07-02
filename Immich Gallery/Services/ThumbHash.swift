//
//  ThumbHash.swift
//  Immich Gallery
//
//  Decodes Immich's per-asset `thumbhash` (a ~25-byte, base64-encoded ThumbHash)
//  into a tiny blurry placeholder image. This lets a tile render something
//  recognisable instantly from data we already have, without any network call,
//  while the real thumbnail loads (or is deferred during fast scroll).
//
//  Self-contained port of Evan Wallace's public-domain `thumbHashToRGBA`
//  reference (https://evanw.github.io/thumbhash/). Kept dependency-free and
//  fully bounds-checked: malformed input returns nil rather than trapping.
//

import UIKit

enum ThumbHash {
    /// Decoded placeholders are cached so each distinct hash is decoded once.
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 2000 // tiny images; this is generous and cheap
        return c
    }()

    /// Decode a base64 ThumbHash string into a small placeholder image.
    /// Returns nil for empty/malformed input.
    static func image(fromBase64 base64: String?) -> UIImage? {
        guard let base64 = base64, !base64.isEmpty else { return nil }
        if let cached = cache.object(forKey: base64 as NSString) { return cached }
        guard let data = Data(base64Encoded: base64) else { return nil }
        guard let image = decode(Array(data)) else { return nil }
        cache.setObject(image, forKey: base64 as NSString)
        return image
    }

    // MARK: - Decoder

    private static func decode(_ hash: [UInt8]) -> UIImage? {
        // Header needs at least 5 bytes; alpha adds a 6th.
        guard hash.count >= 5 else { return nil }

        let header24 = Int(hash[0]) | (Int(hash[1]) << 8) | (Int(hash[2]) << 16)
        let header16 = Int(hash[3]) | (Int(hash[4]) << 8)

        let lDC = Double(header24 & 63) / 63
        let pDC = Double((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Double((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Double((header24 >> 18) & 31) / 31
        let hasAlpha = (header24 >> 23) & 1
        let lCount = hasAlpha == 1 ? 5 : 7
        let pScale = Double((header16 >> 3) & 63) / 63
        let qScale = Double((header16 >> 9) & 63) / 63
        let isLandscape = (header16 >> 15) & 1
        let lx = max(3, isLandscape == 1 ? (hasAlpha == 1 ? 5 : 7) : lCount)
        let ly = max(3, isLandscape == 1 ? lCount : (hasAlpha == 1 ? 5 : 7))

        if hasAlpha == 1 && hash.count < 6 { return nil }
        let aDC = hasAlpha == 1 ? Double(Int(hash[5]) & 15) / 15 : 1
        let aScale = hasAlpha == 1 ? Double(Int(hash[5]) >> 4) / 15 : 0

        let acStart = hasAlpha == 1 ? 6 : 5
        var acIndex = 0

        // Pull the AC terms for one channel out of the packed nibble stream.
        // Reads past the buffer decode as the neutral value (0) instead of trapping.
        func decodeChannel(_ nx: Int, _ ny: Int, _ scale: Double) -> [Double] {
            var ac: [Double] = []
            for cy in 0..<ny {
                var cx = cy > 0 ? 0 : 1
                while cx * ny < nx * (ny - cy) {
                    let byteIndex = acStart + (acIndex >> 1)
                    let nibble = byteIndex < hash.count
                        ? (Int(hash[byteIndex]) >> ((acIndex & 1) << 2)) & 15
                        : 7 // neutral -> ~0 after the transform below
                    ac.append((Double(nibble) / 7.5 - 1) * scale)
                    acIndex += 1
                    cx += 1
                }
            }
            return ac
        }

        let lAC = decodeChannel(lx, ly, lScale)
        let pAC = decodeChannel(3, 3, pScale * 1.25)
        let qAC = decodeChannel(3, 3, qScale * 1.25)
        let aAC = hasAlpha == 1 ? decodeChannel(5, 5, aScale) : []

        // Output size from the approximate aspect ratio (max dimension 32px).
        let ratio = Double(lx) / Double(ly)
        let w = Int((ratio > 1 ? 32 : 32 * ratio).rounded())
        let h = Int((ratio > 1 ? 32 / ratio : 32).rounded())
        guard w > 0, h > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        var fx = [Double](repeating: 0, count: max(lx, hasAlpha == 1 ? 5 : 3))
        var fy = [Double](repeating: 0, count: max(ly, hasAlpha == 1 ? 5 : 3))

        var i = 0
        for y in 0..<h {
            for x in 0..<w {
                var l = lDC, p = pDC, q = qDC, a = aDC

                let nx = fx.count
                for cx in 0..<nx { fx[cx] = cos(Double.pi / Double(w) * (Double(x) + 0.5) * Double(cx)) }
                let ny = fy.count
                for cy in 0..<ny { fy[cy] = cos(Double.pi / Double(h) * (Double(y) + 0.5) * Double(cy)) }

                // Luminance
                var j = 0
                for cy in 0..<ly {
                    var cx = cy > 0 ? 0 : 1
                    let fy2 = fy[cy] * 2
                    while cx * ly < lx * (ly - cy) && j < lAC.count {
                        l += lAC[j] * fx[cx] * fy2
                        j += 1; cx += 1
                    }
                }
                // Chrominance P/Q (always 3x3)
                j = 0
                for cy in 0..<3 {
                    var cx = cy > 0 ? 0 : 1
                    let fy2 = fy[cy] * 2
                    while cx < 3 - cy && j < pAC.count {
                        let f = fx[cx] * fy2
                        p += pAC[j] * f
                        q += qAC[j] * f
                        j += 1; cx += 1
                    }
                }
                // Alpha (5x5)
                if hasAlpha == 1 {
                    j = 0
                    for cy in 0..<5 {
                        var cx = cy > 0 ? 0 : 1
                        let fy2 = fy[cy] * 2
                        while cx < 5 - cy && j < aAC.count {
                            a += aAC[j] * fx[cx] * fy2
                            j += 1; cx += 1
                        }
                    }
                }

                // YPbPr-ish -> RGB, then store premultiplied for premultipliedLast.
                let b = l - 2.0 / 3.0 * p
                let r = (3 * l - b + q) / 2
                let g = r - q
                let rr = min(1, max(0, r))
                let gg = min(1, max(0, g))
                let bb = min(1, max(0, b))
                let aa = min(1, max(0, a))
                rgba[i]     = UInt8(255 * rr * aa)
                rgba[i + 1] = UInt8(255 * gg * aa)
                rgba[i + 2] = UInt8(255 * bb * aa)
                rgba[i + 3] = UInt8(255 * aa)
                i += 4
            }
        }

        return makeImage(rgba: rgba, width: w, height: h)
    }

    private static func makeImage(rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        var pixels = rgba
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let cg = ctx.makeImage() else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
