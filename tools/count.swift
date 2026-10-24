// Counts frames AVFoundation delivers from the "EyeToy" camera (ffmpeg's avfoundation input caps out near 33 fps).
// usage: count <width> <seconds> [x]   x = set that format; otherwise the app default is used
import AVFoundation

let width = Int32(CommandLine.arguments.dropFirst().first ?? "320") ?? 320
let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "8") ?? 8

final class Counter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var n = 0
    var dims = ""
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        n += 1
        if let ib = CMSampleBufferGetImageBuffer(sb) { dims = "\(CVPixelBufferGetWidth(ib))x\(CVPixelBufferGetHeight(ib))" }
    }
}

let dev = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
    .devices.first { $0.localizedName == "EyeToy" }!
let fmt = dev.formats.first { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width == width }!
let session = AVCaptureSession()
session.addInput(try! AVCaptureDeviceInput(device: dev))
let out = AVCaptureVideoDataOutput()
out.alwaysDiscardsLateVideoFrames = false
let counter = Counter()
out.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "count"))
session.addOutput(out)
session.startRunning()
if CommandLine.arguments.count > 3 { // set after startRunning, or the session preset overrides it
    try! dev.lockForConfiguration()
    dev.activeFormat = fmt
    dev.activeVideoMinFrameDuration = fmt.videoSupportedFrameRateRanges[0].minFrameDuration
    dev.unlockForConfiguration()
}
Thread.sleep(forTimeInterval: 2)
let n0 = counter.n
Thread.sleep(forTimeInterval: seconds)
print("active \(dev.activeFormat.formatDescription.dimensions.width) min \(dev.activeVideoMinFrameDuration.seconds) frames \(counter.dims): \(Double(counter.n - n0) / seconds) fps")
session.stopRunning()
