import AVFoundation

/// The flashlight as a light show. Changing it means locking the camera device, which can take
/// a few milliseconds, so that happens on its own queue. Only meaningful changes are sent.
final class Torch {
    private let device = AVCaptureDevice.default(for: .video)
    private let queue = DispatchQueue(label: "felt.torch")
    private var level: Float = 0

    var available: Bool { device?.hasTorch == true }

    func set(_ value: Float) {
        let v = min(1, max(0, value))
        guard let device, device.hasTorch else { return }
        guard abs(v - level) > 0.05 || (v < 0.02) != (level < 0.02) else { return }
        level = v
        queue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if v < 0.02 { device.torchMode = .off } else { try? device.setTorchModeOn(level: v) }
            device.unlockForConfiguration()
        }
    }
}
