import AVFoundation
import CallKit
import Foundation
import LiveCommunicationKit
import PushKit
import UIKit

/// Cloud call routing is enabled per authenticated device in PhoneStore.
enum BackgroundCallConfiguration {
    static let enabled = false
}

// Select exactly one system UI for the lifetime of the process. Never report the
// same VoIP push to both frameworks. iOS 27 is the initial LCK pilot baseline.
@MainActor
private protocol NativeIncomingUI: IncomingCallReporting, OutgoingCallReporting, SystemCallControlling {
    var onOutgoingStart: (UUID) -> Bool { get set }
    var onOutgoingEnd: (UUID) -> Bool { get set }
    var coordinator: IncomingCallCoordinator? { get set }
    var onAudioActivation: (Bool) -> Void { get set }
    var onMute: (Bool) -> Bool { get set }
    var onHold: (UUID, Bool, @escaping (Bool) -> Void) -> Void { get set }
    var onTones: (UUID, String) -> Bool { get set }
    var onHoldTimeout: (UUID) -> Void { get set }
}

@MainActor
final class SystemIncomingCalls: NSObject, IncomingCallReporting, OutgoingCallReporting, SystemCallControlling, @preconcurrency PKPushRegistryDelegate {
    private let ui: any NativeIncomingUI
    let integrationName: String
    private var registry: PKPushRegistry?
    private var deadlineTimer: Timer?
    private(set) var coordinator: IncomingCallCoordinator!
    var onAudioActivation: (Bool) -> Void {
        get { ui.onAudioActivation }
        set { ui.onAudioActivation = newValue }
    }
    var onMute: (Bool) -> Bool {
        get { ui.onMute }
        set { ui.onMute = newValue }
    }
    var onHold: (UUID, Bool, @escaping (Bool) -> Void) -> Void {
        get { ui.onHold }
        set { ui.onHold = newValue }
    }
    var onTones: (UUID, String) -> Bool {
        get { ui.onTones }
        set { ui.onTones = newValue }
    }
    var onHoldTimeout: (UUID) -> Void {
        get { ui.onHoldTimeout }
        set { ui.onHoldTimeout = newValue }
    }
    func requestHold(id: UUID, held: Bool) { ui.requestHold(id: id, held: held) }
    func requestTones(id: UUID, digits: String) { ui.requestTones(id: id, digits: digits) }
    var onOutgoingStart: (UUID) -> Bool {
        get { ui.onOutgoingStart }
        set { ui.onOutgoingStart = newValue }
    }
    var onOutgoingEnd: (UUID) -> Bool {
        get { ui.onOutgoingEnd }
        set { ui.onOutgoingEnd = newValue }
    }
    func startOutgoing(id: UUID, contact: Contact, failed: @escaping () -> Void) {
        ui.startOutgoing(id: id, contact: contact, failed: failed)
    }
    func outgoingConnected(id: UUID) { ui.outgoingConnected(id: id) }
    func endOutgoing(id: UUID, failed: Bool) { ui.endOutgoing(id: id, failed: failed) }
    var onTokenChanged: (Data?) -> Void = { _ in }
    private(set) var token: Data?

    override init() {
        if #available(iOS 27.0, *) {
            ui = LiveIncomingUI()
            integrationName = "LiveCommunicationKit"
        } else {
            ui = CallKitIncomingUI()
            integrationName = "CallKit"
        }
        super.init()
        coordinator = IncomingCallCoordinator(reporter: self)
        ui.coordinator = coordinator
    }
    func start(enrollmentReady: Bool) {
        guard enrollmentReady,
              let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
              modes.contains("voip"), modes.contains("audio"), registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        self.registry = registry
        registry.desiredPushTypes = [.voIP]
        deadlineTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator.expire() }
        }
        RunLoop.main.add(deadlineTimer!, forMode: .common)
    }
    func report(id: UUID, contact: Contact?, completion: @escaping (Bool) -> Void) {
        ui.report(id: id, contact: contact, completion: completion)
    }
    func update(id: UUID, contact: Contact) { ui.update(id: id, contact: contact) }
    func connected(id: UUID) { ui.connected(id: id) }
    func end(id: UUID, reason: SystemCallEnd) { ui.end(id: id, reason: reason) }
    func requestAnswer(id: UUID) { ui.requestAnswer(id: id) }
    func requestEnd(id: UUID) { ui.requestEnd(id: id) }
    func requestMute(id: UUID, muted: Bool) { ui.requestMute(id: id, muted: muted) }
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        token = pushCredentials.token
        onTokenChanged(token)
    }
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        token = nil
        onTokenChanged(nil)
    }
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        coordinator.receivePush(payload.dictionaryPayload, completion: completion)
    }
    deinit { deadlineTimer?.invalidate() }
}

/// The delegate queue of CXProvider is explicitly main.
// Both delegate queues are explicitly .main. These Objective-C protocols predate
// actor annotations; preconcurrency keeps runtime main-actor checking enabled.
@MainActor
private final class CallKitIncomingUI: NSObject, NativeIncomingUI, @preconcurrency CXProviderDelegate {
    private let controller = CXCallController()
    private var outgoingContacts: [UUID: Contact] = [:]
    private let provider: CXProvider
    var onOutgoingStart: (UUID) -> Bool = { _ in false }
    var onOutgoingEnd: (UUID) -> Bool = { _ in false }
    private var outgoingIDs: Set<UUID> = []
    weak var coordinator: IncomingCallCoordinator?
    var onAudioActivation: (Bool) -> Void = { _ in }
    var onMute: (Bool) -> Bool = { _ in false }
    var onHold: (UUID, Bool, @escaping (Bool) -> Void) -> Void = { _, _, done in done(false) }
    var onTones: (UUID, String) -> Bool = { _, _ in false }
    var onHoldTimeout: (UUID) -> Void = { _ in }

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic, .phoneNumber]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func report(id: UUID, contact: Contact?, completion: @escaping (Bool) -> Void) {
        provider.reportNewIncomingCall(with: id, update: updateFor(contact)) { error in
            // Delegate delivery is on main; report completion is not documented as main.
            Task { @MainActor in completion(error == nil) }
        }
    }
    func update(id: UUID, contact: Contact) { provider.reportCall(with: id, updated: updateFor(contact)) }
    private func updateFor(_ contact: Contact?) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: contact == nil ? .generic : .phoneNumber,
                                       value: contact?.number ?? "Unbekannter Anrufer")
        update.localizedCallerName = contact?.name ?? "Unbekannter Anrufer"
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true
        return update
    }
    func end(id: UUID, reason: SystemCallEnd) {
        let mapped: CXCallEndedReason
        switch reason {
        case .remote, .declined: mapped = .remoteEnded
        case .unanswered: mapped = .unanswered
        case .failed: mapped = .failed
        }
        provider.reportCall(with: id, endedAt: Date(), reason: mapped)
    }

    func startOutgoing(id: UUID, contact: Contact, failed: @escaping () -> Void) {
        outgoingIDs.insert(id)
        outgoingContacts[id] = contact
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .phoneNumber, value: contact.number))
        action.contactIdentifier = contact.name
        controller.request(CXTransaction(action: action)) { error in
            if error != nil { Task { @MainActor in self.outgoingIDs.remove(id); self.outgoingContacts.removeValue(forKey: id); failed() } }
        }
    }
    func outgoingConnected(id: UUID) {
        guard outgoingIDs.contains(id) else { return }
        provider.reportOutgoingCall(with: id, connectedAt: Date())
    }
    func endOutgoing(id: UUID, failed: Bool) {
        outgoingIDs.remove(id)
        outgoingContacts.removeValue(forKey: id)
        provider.reportCall(with: id, endedAt: Date(), reason: failed ? .failed : .remoteEnded)
    }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard outgoingIDs.contains(action.callUUID) else { action.fail(); return }
        provider.reportCall(with: action.callUUID, updated: updateFor(outgoingContacts[action.callUUID]))
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        guard onOutgoingStart(action.callUUID) else { action.fail(); return }
        action.fulfill()
    }
    func requestAnswer(id: UUID) { request(CXAnswerCallAction(call: id)) }
    func requestEnd(id: UUID) { request(CXEndCallAction(call: id)) }
    func requestMute(id: UUID, muted: Bool) { request(CXSetMutedCallAction(call: id, muted: muted)) }
    func requestHold(id: UUID, held: Bool) { request(CXSetHeldCallAction(call: id, onHold: held)) }
    func requestTones(id: UUID, digits: String) { request(CXPlayDTMFCallAction(call: id, digits: digits, type: .singleTone)) }
    private func request(_ action: CXAction) {
        controller.request(CXTransaction(action: action)) { [weak self] error in
            if error != nil { Task { @MainActor in
                self?.coordinator?.trace("CallKit-Aktion konnte nicht gestartet werden.")
            } }
        }
    }

    func providerDidReset(_ provider: CXProvider) {
        for id in Array(outgoingIDs) { _ = onOutgoingEnd(id) }
        outgoingIDs.removeAll(); outgoingContacts.removeAll(); coordinator?.reset(); onAudioActivation(false)
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let coordinator else { action.fail(); return }
        coordinator.answer(id: action.callUUID) { success in
            if success { action.fulfill() } else { action.fail() }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if outgoingIDs.contains(action.callUUID) ? onOutgoingEnd(action.callUUID) : coordinator?.end(id: action.callUUID) == true { action.fulfill() } else { action.fail() }
    }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if (coordinator?.systemID == action.callUUID || outgoingIDs.contains(action.callUUID)), onMute(action.isMuted) { action.fulfill() }
        else { action.fail() }
    }
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard coordinator?.systemID == action.callUUID || outgoingIDs.contains(action.callUUID) else { action.fail(); return }
        onHold(action.callUUID, action.isOnHold) { success in
            if success { action.fulfill() } else { action.fail() }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard coordinator?.systemID == action.callUUID || outgoingIDs.contains(action.callUUID),
              action.type == .singleTone, onTones(action.callUUID, action.digits) else { action.fail(); return }
        action.fulfill()
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        if let hold = action as? CXSetHeldCallAction { onHoldTimeout(hold.callUUID); return }
        if action is CXPlayDTMFCallAction { return }
        if let callAction = action as? CXCallAction, outgoingIDs.contains(callAction.callUUID) {
            _ = onOutgoingEnd(callAction.callUUID)
        }
        // A timed-out answer must never answer a later INVITE.
        if let callAction = action as? CXCallAction, callAction.callUUID == coordinator?.systemID {
            coordinator?.reset()
        }
    }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { onAudioActivation(true) }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { onAudioActivation(false) }

}

/// Native iOS 27 conversation UI. The SIP/push state machine remains the single
/// authority for identity, early answer, expiry and cancellation.
@available(iOS 27.0, *)
@MainActor
private final class LiveIncomingUI: NativeIncomingUI, ConversationManagerDelegate {
    private let manager: ConversationManager
    var onOutgoingStart: (UUID) -> Bool = { _ in false }
    var onOutgoingEnd: (UUID) -> Bool = { _ in false }
    private var outgoingIDs: Set<UUID> = []
    weak var coordinator: IncomingCallCoordinator?
    var onAudioActivation: (Bool) -> Void = { _ in }
    var onMute: (Bool) -> Bool = { _ in false }
    var onHold: (UUID, Bool, @escaping (Bool) -> Void) -> Void = { _, _, done in done(false) }
    var onTones: (UUID, String) -> Bool = { _, _ in false }
    var onHoldTimeout: (UUID) -> Void = { _ in }
    // Caller information can arrive while the asynchronous system report is pending.
    private var contacts: [UUID: Contact] = [:]
    private var connectedIDs: Set<UUID> = []

    init() {
        manager = ConversationManager(configuration: .init(
            ringtoneName: nil, iconTemplateImageData: nil,
            maximumConversationGroups: 1, maximumConversationsPerConversationGroup: 1,
            includesConversationInRecents: true, supportsVideo: false,
            supportedHandleTypes: [.generic, .phoneNumber]))
        manager.delegate = self
    }
    private func conversation(_ id: UUID) -> Conversation? {
        manager.conversations.first { $0.uuid == id }
    }
    private func updateFor(_ contact: Contact?) -> Conversation.Update {
        let handle = Handle(type: contact == nil ? .generic : .phoneNumber,
                            value: contact?.number ?? "Unbekannter Anrufer",
                            displayName: contact?.name ?? "Unbekannter Anrufer")
        return Conversation.Update(members: [handle], capabilities: [.pausing, .playingTones])
    }
    func report(id: UUID, contact: Contact?, completion: @escaping (Bool) -> Void) {
        if let contact { contacts[id] = contact }
        // PushKit completion runs only after Apple's reporting API completes.
        Task { @MainActor in
            do {
                try await manager.reportNewIncomingConversation(uuid: id, update: updateFor(contacts[id]))
                if let latest = contacts[id] { update(id: id, contact: latest) }
                completion(true)
            } catch {
                if conversation(id) == nil { contacts.removeValue(forKey: id) }
                coordinator?.trace("LiveCommunicationKit: Systemmeldung nicht angenommen.")
                completion(false)
            }
        }
    }
    func update(id: UUID, contact: Contact) {
        contacts[id] = contact
        guard let conversation = conversation(id) else { return }
        manager.reportConversationEvent(.conversationUpdated(updateFor(contact)), for: conversation)
    }
    func connected(id: UUID) {
        guard let conversation = conversation(id), connectedIDs.insert(id).inserted else { return }
        manager.reportConversationEvent(.conversationConnected(Date()), for: conversation)
    }
    func end(id: UUID, reason: SystemCallEnd) {
        contacts.removeValue(forKey: id)
        connectedIDs.remove(id)
        guard let conversation = conversation(id) else { return }
        let mapped: Conversation.EndedReason
        switch reason {
        case .remote, .declined: mapped = .remoteEnded
        case .unanswered: mapped = .unanswered
        case .failed: mapped = .failed
        }
        manager.reportConversationEvent(.conversationEnded(Date(), mapped), for: conversation)
    }
    func startOutgoing(id: UUID, contact: Contact, failed: @escaping () -> Void) {
        outgoingIDs.insert(id)
        contacts[id] = contact
        let handle = Handle(type: .phoneNumber, value: contact.number, displayName: contact.name)
        Task { @MainActor in
            do { try await manager.perform([StartConversationAction(conversationUUID: id, handles: [handle], isVideo: false)]) }
            catch { outgoingIDs.remove(id); contacts.removeValue(forKey: id); failed() }
        }
    }
    func outgoingConnected(id: UUID) { connected(id: id) }
    func endOutgoing(id: UUID, failed: Bool) {
        outgoingIDs.remove(id)
        end(id: id, reason: failed ? .failed : .remote)
    }
    func requestAnswer(id: UUID) { request(JoinConversationAction(conversationUUID: id)) }
    func requestEnd(id: UUID) { request(EndConversationAction(conversationUUID: id)) }
    func requestMute(id: UUID, muted: Bool) { request(MuteConversationAction(conversationUUID: id, isMuted: muted)) }
    func requestHold(id: UUID, held: Bool) { request(PauseConversationAction(conversationUUID: id, isPaused: held)) }
    func requestTones(id: UUID, digits: String) { request(PlayToneAction(conversationUUID: id, digits: digits, tone: .single)) }
    private func request(_ action: ConversationAction) {
        Task { @MainActor in
            do { try await manager.perform([action]) }
            catch { coordinator?.trace("LiveCommunicationKit: Aktion konnte nicht gestartet werden.") }
        }
    }
    nonisolated func conversationManagerDidBegin(_ manager: ConversationManager) {}
    nonisolated func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {}
    nonisolated func conversationManagerDidReset(_ manager: ConversationManager) {
        Task { @MainActor in
            for id in Array(outgoingIDs) { _ = onOutgoingEnd(id) }
            outgoingIDs.removeAll()
            coordinator?.reset()
            contacts.removeAll(); connectedIDs.removeAll()
            onAudioActivation(false)
        }
    }
    nonisolated func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
        Task { @MainActor in self.perform(action) }
    }
    private func perform(_ action: ConversationAction) {
        guard let conversation = conversation(action.conversationUUID) else { action.fail(); return }
        let known = outgoingIDs.contains(action.conversationUUID) || coordinator?.systemID == action.conversationUUID
        if let pause = action as? PauseConversationAction {
            guard known else { pause.fail(); return }
            onHold(pause.conversationUUID, pause.isPaused) { success in
                if success { pause.fulfill() } else { pause.fail() }
            }
            return
        }
        if let tone = action as? PlayToneAction {
            guard known, tone.tone == .single, onTones(tone.conversationUUID, tone.digits) else { tone.fail(); return }
            tone.fulfill(); return
        }
        if outgoingIDs.contains(action.conversationUUID) {
            switch action {
            case let start as StartConversationAction:
                manager.reportConversationEvent(.conversationUpdated(updateFor(contacts[start.conversationUUID])), for: conversation)
                manager.reportConversationEvent(.conversationStartedConnecting(Date()), for: conversation)
                if onOutgoingStart(start.conversationUUID) {
                    start.fulfill(dateStarted: Date())
                } else {
                    start.fail(); endOutgoing(id: start.conversationUUID, failed: true)
                }
            case let end as EndConversationAction:
                if onOutgoingEnd(end.conversationUUID) { end.fulfill(dateEnded: Date()) } else { end.fail() }
            case let mute as MuteConversationAction:
                if onMute(mute.isMuted) { mute.fulfill() } else { mute.fail() }
            default: action.fail()
            }
            return
        }
        guard let coordinator, coordinator.systemID == action.conversationUUID else { action.fail(); return }
        switch action {
        case let join as JoinConversationAction:
            manager.reportConversationEvent(.conversationStartedConnecting(Date()), for: conversation)
            coordinator.answer(id: join.conversationUUID) { success in
                // As with CXAnswerCallAction, fulfill after SIP accepts the answer so
                // iOS can activate audio. SIP .active separately reports connection.
                if success { join.fulfill(dateConnected: Date()) } else { join.fail() }
            }
        case let end as EndConversationAction:
            if coordinator.end(id: end.conversationUUID) { end.fulfill(dateEnded: Date()) }
            else { end.fail() }
        case let mute as MuteConversationAction:
            if onMute(mute.isMuted) { mute.fulfill() } else { mute.fail() }
        default:
            action.fail() // Merging, video and translation are not advertised.
        }
    }
    nonisolated func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
        Task { @MainActor in
            if action is PauseConversationAction { onHoldTimeout(action.conversationUUID); return }
            if action is PlayToneAction { return }
            if outgoingIDs.contains(action.conversationUUID) { _ = onOutgoingEnd(action.conversationUUID) }
            if coordinator?.systemID == action.conversationUUID { coordinator?.reset() }
        }
    }
    nonisolated func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in onAudioActivation(true) }
    }
    nonisolated func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in onAudioActivation(false) }
    }
}
