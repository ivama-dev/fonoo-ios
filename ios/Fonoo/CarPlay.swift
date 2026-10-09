import AVFoundation
import CarPlay
import Combine
import Intents
import UIKit

/// One shared PhoneStore serves iPhone, CarPlay and Siri. There is no second SIP
/// registration or password copy for the car display.
@MainActor
final class FonooCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interface: CPInterfaceController?
    private var subscriptions: Set<AnyCancellable> = []
    private let favorites = CPListTemplate(title: "Favoriten", sections: [])
    private let recents = CPListTemplate(title: "Letzte Anrufe", sections: [])
    private weak var phone: PhoneStore?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        guard let phone = FonooAppDelegate.current?.phone else { return }
        self.phone = phone
        favorites.tabTitle = "Favoriten"; favorites.tabImage = UIImage(systemName: "star.fill")
        recents.tabTitle = "Anrufliste"; recents.tabImage = UIImage(systemName: "clock.fill")
        let assistant = CPAssistantCellConfiguration(position: .top, visibility: .always, assistantAction: .startCall)
        favorites.assistantCellConfiguration = assistant
        recents.assistantCellConfiguration = assistant
        render()
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: [favorites, recents]), animated: false) { [weak self] success, _ in
            if !success { self?.phone?.diagnostics.record("CarPlay-Oberfläche konnte nicht geöffnet werden.") }
        }
        // objectWillChange fires before the model changes. Deliver on the next main
        // turn, debounce bursts, and release the subscription on disconnect.
        phone.objectWillChange.debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.render() }.store(in: &subscriptions)
    }
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        subscriptions.removeAll(); interface = nil; phone = nil
        // Unplugging CarPlay must not hang up the call; iOS owns the audio route.
    }
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == "INStartCallIntent" else { return }
        FonooAppDelegate.current?.phone.continueCallActivity(userActivity)
    }
    private func render() {
        guard let phone else { return }
        let configured = phone.cloudPushActive
        let limit = min(30, CPListTemplate.maximumItemCount)
        favorites.emptyViewTitleVariants = [configured ? "Keine Favoriten" : "fonoo einrichten"]
        favorites.emptyViewSubtitleVariants = [configured ? "Favoriten auf dem iPhone hinzufügen." : "Zuerst auf dem iPhone bei fonoo anmelden."]
        recents.emptyViewTitleVariants = [configured ? "Keine Anrufe" : "fonoo einrichten"]
        recents.emptyViewSubtitleVariants = favorites.emptyViewSubtitleVariants
        favorites.updateSections([CPListSection(items: configured ? Array(phone.favorites.prefix(limit)).map { item($0, detail: $0.number) } : [])])
        recents.updateSections([CPListSection(items: configured ? Array(phone.recents.prefix(limit)).map { item($0.contact, detail: $0.detail + " · " + $0.contact.number) } : [])])
    }
    private func item(_ contact: Contact, detail: String) -> CPListItem {
        let item = CPListItem(text: contact.name, detailText: detail)
        item.handler = { [weak self] _, done in
            guard let self, let interface else { done(); return }
            let person = CPContact(name: contact.name, image: UIImage(systemName: "person.circle.fill")!)
            person.subtitle = contact.number
            person.actions = [CPContactCallButton { [weak self] _ in self?.call(contact) }]
            interface.pushTemplate(CPContactTemplate(contact: person), animated: true) { _, _ in done() }
        }
        return item
    }
    private func call(_ contact: Contact) {
        Task { [weak self] in
            guard let self, let phone else { return }
            do { try await phone.startCarPlayCall(contact) }
            catch {
                let dismiss = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                    self?.interface?.dismissTemplate(animated: true, completion: nil)
                }
                interface?.presentTemplate(CPAlertTemplate(titleVariants: [error.localizedDescription], actions: [dismiss]), animated: true, completion: nil)
            }
        }
    }
}

/// Siri resolves numbers or unambiguous names from the existing local Fonoo
/// favorites/history. It never chooses the first of several matching contacts.
@MainActor
final class FonooCallIntentHandler: NSObject, INStartCallIntentHandling {
    private weak var phone: PhoneStore?
    init(phone: PhoneStore) { self.phone = phone }
    private func contact(_ person: INPerson) -> Contact? {
        guard let value = person.personHandle?.value,
              let number = try? SIPAccount.normalizedNumber(value) else { return nil }
        return Contact(id: number, name: person.displayName, role: "Siri", number: number)
    }
    private func person(_ contact: Contact) -> INPerson {
        INPerson(personHandle: INPersonHandle(value: contact.number, type: .phoneNumber),
                 nameComponents: nil, displayName: contact.name, image: nil,
                 contactIdentifier: nil, customIdentifier: contact.id)
    }
    nonisolated func resolveContacts(for intent: INStartCallIntent, with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        Task { @MainActor in
            guard let input = intent.contacts, !input.isEmpty else { completion([.needsValue()]); return }
            guard input.count == 1 else { completion([.unsupported()]); return }
            if contact(input[0]) != nil { completion([.success(with: input[0])]); return }
            let name = input[0].displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let contacts = (phone?.favorites ?? []) + (phone?.recents.map(\.contact) ?? [])
            var seen: Set<String> = []
            let matches = contacts.filter {
                $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == name && seen.insert($0.number).inserted
            }
            if matches.count == 1 { completion([.success(with: person(matches[0]))]) }
            else if matches.count > 1 { completion([.disambiguation(with: matches.map(person))]) }
            else { completion([.unsupported()]) }
        }
    }
    nonisolated func resolveCallCapability(for intent: INStartCallIntent, with completion: @escaping (INStartCallCallCapabilityResolutionResult) -> Void) {
        Task { @MainActor in
            completion(intent.callCapability == .videoCall ? .unsupported() : .success(with: .audioCall))
        }
    }
    nonisolated func confirm(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        Task { @MainActor in
            let code: INStartCallIntentResponseCode = phone?.cloudPushActive != true ? .failureAppConfigurationRequired
                : phone?.busy == true ? .failureCallInProgress : .ready
            completion(INStartCallIntentResponse(code: code, userActivity: nil))
        }
    }
    nonisolated func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        Task { @MainActor in
            guard intent.callCapability != .videoCall, intent.contacts?.count == 1,
                  let person = intent.contacts?.first, let target = contact(person), phone?.cloudPushActive == true else {
                completion(INStartCallIntentResponse(code: .failureContactNotSupportedByApp, userActivity: nil)); return
            }
            guard phone?.busy == false else {
                completion(INStartCallIntentResponse(code: .failureCallInProgress, userActivity: nil)); return
            }
            let activity = NSUserActivity(activityType: "INStartCallIntent")
            activity.userInfo = ["fonoo_number": target.number, "fonoo_name": target.name, "fonoo_request": UUID().uuidString]
            completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
        }
    }
}
