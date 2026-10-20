import Foundation
import AVFoundation
import ImageIO

// 抽帧器。用 AVFoundation 而不是 ffmpeg：
//   · macOS 自带，不依赖 Homebrew；
//   · 能精确指定时间点（requestedTimeTolerance = zero），不会因为关键帧对齐而取错帧。
//
// 用法：
//   extract_frames --duration <video>
//   extract_frames <video> <outdir> <start> <end> <count>

let args = CommandLine.arguments

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

func videoDuration(_ url: URL) -> Double {
    let asset = AVURLAsset(url: url)
    return CMTimeGetSeconds(asset.duration)
}

if args.count == 3 && args[1] == "--duration" {
    print(videoDuration(URL(fileURLWithPath: args[2])))
    exit(0)
}

guard args.count == 6 else {
    fail("usage:\n  extract_frames --duration <video>\n  extract_frames <video> <outdir> <start> <end> <count>")
}

let videoURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
guard let start = Double(args[3]), let end = Double(args[4]),
      let count = Int(args[5]), count > 0, end > start else {
    fail("参数不合法：start/end/count 必须满足 end > start、count > 0")
}
guard FileManager.default.fileExists(atPath: videoURL.path) else {
    fail("找不到视频：\(videoURL.path)")
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let asset = AVURLAsset(url: videoURL)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero

for i in 0..<count {
    // 取每个区间的中点，避免正好落在边界上
    let t = start + (end - start) * (Double(i) + 0.5) / Double(count)
    do {
        let cg = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
        let url = outDir.appendingPathComponent(String(format: "f_%02d.png", i))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            fail("无法创建输出：\(url.path)")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            fail("写入失败：\(url.path)")
        }
        print(String(format: "frame %02d  t=%.3f", i, t))
    } catch {
        fail("抽帧失败（第 \(i) 帧，t=\(String(format: "%.3f", t))）：\(error)")
    }
}
