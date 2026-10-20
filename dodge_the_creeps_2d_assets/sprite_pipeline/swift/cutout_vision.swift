import Foundation
import Vision
import CoreImage
import AppKit
import ImageIO

// 前景分割。用 macOS Vision 的 VNGenerateForegroundInstanceMaskRequest：
//   · 本地推理，不下载模型、不联网；
//   · 白底、柔投影、角落水印会一起被排除（前提是主体足够明确）；
//   · 输出直通 alpha，边缘比纯色键控自然。
//
// 用法：cutout_vision <in.png> <out.png>

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: cutout_vision <in.png> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("load fail: \(inURL.path)")
    exit(3)
}

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
let request = VNGenerateForegroundInstanceMaskRequest()
do {
    try handler.perform([request])
} catch {
    print("vision fail: \(error)")
    exit(4)
}

guard let obs = request.results?.first else {
    print("no foreground found: \(inURL.lastPathComponent)")
    exit(5)
}

let maskPB = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
let maskCI = CIImage(cvPixelBuffer: maskPB)
let origCI = CIImage(cgImage: cg)
let clear = CIImage(color: CIColor.clear).cropped(to: origCI.extent)
let outCI = origCI.applyingFilter("CIBlendWithMask", parameters: [
    kCIInputMaskImageKey: maskCI,
    kCIInputBackgroundImageKey: clear
])

let ctx = CIContext()
guard let outCG = ctx.createCGImage(outCI, from: origCI.extent) else {
    print("render fail")
    exit(6)
}
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
    print("dest fail")
    exit(7)
}
CGImageDestinationAddImage(dest, outCG, nil)
guard CGImageDestinationFinalize(dest) else {
    print("write fail")
    exit(8)
}
