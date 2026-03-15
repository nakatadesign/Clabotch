#!/usr/bin/env swift
// Clabotch アプリアイコン生成スクリプト
// PNG 素材ゼロの方針に準拠 — コードで顔を描画して PNG を出力する

import AppKit

let canvasW: CGFloat = 20
let canvasH: CGFloat = 14

// カラーパレット
let faceNormal = NSColor(red: 0xB0/255.0, green: 0x78/255.0, blue: 0x78/255.0, alpha: 1)
let eyeWhite = NSColor(red: 0xF0/255.0, green: 0xF0/255.0, blue: 0xF0/255.0, alpha: 1)
let pupil = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)

func pxFill(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat,
            _ w: CGFloat, _ h: CGFloat, _ dot: CGFloat,
            ox: CGFloat, oy: CGFloat) {
    let flippedY = canvasH - y - h
    ctx.fill(CGRect(x: x * dot + ox, y: flippedY * dot + oy,
                    width: w * dot, height: h * dot))
}

func generateIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    let gCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gCtx
    let ctx = gCtx.cgContext
    let sizeF = CGFloat(size)

    // 横幅いっぱいに表示（アスペクト比 20:14 を維持、背景透明）
    let dot = sizeF / canvasW
    let ox: CGFloat = 0
    let oy = (sizeF - canvasH * dot) / 2

    // 顔
    ctx.setFillColor(faceNormal.cgColor)
    pxFill(ctx, 0, 0, canvasW, canvasH, dot, ox: ox, oy: oy)

    // 左目ソケット
    ctx.setFillColor(eyeWhite.cgColor)
    pxFill(ctx, 2, 2, 5, 10, dot, ox: ox, oy: oy)
    // 右目ソケット
    pxFill(ctx, 13, 2, 5, 10, dot, ox: ox, oy: oy)

    // 瞳（左下ポーズ）— 欠けあり
    ctx.setFillColor(pupil.cgColor)
    // 左目
    pxFill(ctx, 2, 4, 3, 3, dot, ox: ox, oy: oy)
    pxFill(ctx, 2, 7, 2, 1, dot, ox: ox, oy: oy)
    pxFill(ctx, 2, 8, 3, 4, dot, ox: ox, oy: oy)
    // 右目
    pxFill(ctx, 13, 4, 3, 3, dot, ox: ox, oy: oy)
    pxFill(ctx, 13, 7, 2, 1, dot, ox: ox, oy: oy)
    pxFill(ctx, 13, 8, 3, 4, dot, ox: ox, oy: oy)

    NSGraphicsContext.current = nil
    return rep
}

func savePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("PNG 生成失敗: \(path)")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("生成: \(path)")
    } catch {
        print("書き込み失敗: \(path) — \(error)")
    }
}

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "."

// macOS アプリアイコンに必要なサイズ
let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, filename) in sizes {
    let rep = generateIcon(size: size)
    savePNG(rep, to: "\(outputDir)/\(filename)")
}

print("完了")
