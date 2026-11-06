#!/usr/bin/env swift

/**
 生成 App 图标（1024×1024）。

 设计：深夜蓝底 + 中心琥珀微光 + 琥珀色圆角播放三角。
 只有两个视觉元素——小尺寸下（Spotlight、通知角标）也要一眼认出来，
 所以不加胶片孔、不加文字、不加弧线装饰。

 用法：
   xcrun swift scripts/make-icon.swift <输出路径>
 */

import AppKit
import CoreGraphics
import Foundation

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let size = 1024
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    FileHandle.standardError.write(Data("无法创建绘图上下文\n".utf8))
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// 1. 底色先整块填满，避免渐变只覆盖两点之间导致四角透明
ctx.setFillColor(color(0x0A0D14))
ctx.fill(rect)

let base = CGGradient(
    colorsSpace: space,
    colors: [color(0x1C263B), color(0x0A0D14)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    base,
    start: CGPoint(x: 180, y: 900),
    end: CGPoint(x: 820, y: 120),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// 2. 中心琥珀微光：让图标像"亮着的屏幕"
let glow = CGGradient(
    colorsSpace: space,
    colors: [color(0xFFB43C, alpha: 0.28), color(0xFFB43C, alpha: 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: 512, y: 512),
    startRadius: 0,
    endCenter: CGPoint(x: 512, y: 512),
    endRadius: 460,
    options: [.drawsAfterEndLocation]
)

// 3. 播放三角：填充 + 同色粗描边（round join）把三个角磨圆。
//    三角形的视觉重心偏左，整体右移 10pt 才是几何居中。
let shift: CGFloat = 10
let triangle = CGMutablePath()
triangle.move(to: CGPoint(x: 424 + shift, y: 690))
triangle.addLine(to: CGPoint(x: 424 + shift, y: 334))
triangle.addLine(to: CGPoint(x: 712 + shift, y: 512))
triangle.closeSubpath()

ctx.setFillColor(color(0xFFB43C))
ctx.setStrokeColor(color(0xFFB43C))
ctx.setLineJoin(.round)
ctx.setLineWidth(64)
ctx.addPath(triangle)
ctx.drawPath(using: .fillStroke)

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("渲染失败\n".utf8))
    exit(1)
}

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"
let url = URL(fileURLWithPath: output)
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
try data.write(to: url)
print("已生成 \(url.path)")
