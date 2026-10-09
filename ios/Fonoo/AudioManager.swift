import AVFoundation
import Foundation

@MainActor
final class AudioManager: CallAudio {
    var onRouteChange: (() -> Void)?
    var onInterruption: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var systemManaged = false
    private let session = AVAudioSession.sharedInstance()
    init() {
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onRouteChange?() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in self?.onInterruption?(began) }
        })
    }
    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    func prepare() throws {
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        if !systemManaged { try session.setActive(true) }
    }
    func setSystemManaged(_ enabled: Bool) { systemManaged = enabled }
    func release() {
        if !systemManaged { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
