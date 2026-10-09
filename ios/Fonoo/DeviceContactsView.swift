import Contacts
import SwiftUI

struct ContactsTabView: View {
    @EnvironmentObject private var phone: PhoneStore
    @State private var query = ""
    var body: some View {
        DeviceContactsContent(query: $query) { phone.start($0) }
            .background(FonooStyle.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name oder Telefonnummer")
    }

}

/// Local iPhone contacts, loaded only while this view is visible.
struct DeviceContactsContent: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var directory = ContactsDirectory()
    @Binding var query: String
    @State private var selected: DeviceContact?
    @State private var visible = false
    let onCall: (Contact) -> Void

    private var matches: [DeviceContact] { directory.contacts.filter { $0.matches(query) } }
    private var shouldLoad: Bool { visible && scenePhase == .active }

    var body: some View {
        Group {
            if directory.canRead { contactList }
            else { accessView }
        }
        .background(FonooStyle.background)
        .onAppear { visible = true }
        .onDisappear { visible = false; directory.clear(); selected = nil }
        .task(id: shouldLoad) {
            if shouldLoad { await directory.refresh() }
            else { directory.clear(); selected = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            selected = nil
            if shouldLoad { Task { await directory.refresh() } }
        }
        .sheet(item: $selected) { person in
            DeviceContactNumbersView(person: person, onCall: onCall)
        }
    }

    private var contactList: some View {
        List {
            if directory.access == .limited {
                Section {
                    Text("Du siehst die Kontakte, die du für fonoo freigegeben hast.").font(.footnote).foregroundStyle(.secondary)
                    Button("Freigabe verwalten") { openSettings() }
                }
            }
            if directory.isLoading {
                ProgressView("Kontakte laden …")
            } else if let message = directory.errorMessage {
                Text(message)
                Button("Erneut versuchen") { Task { await directory.refresh() } }
            } else if matches.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Keine Kontakte mit Rufnummer" : "Kein Kontakt gefunden",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text(query.isEmpty ? "Hier erscheinen deine freigegebenen iPhone-Kontakte mit Telefonnummer." : "Suche nach einem Namen oder einem Teil der Telefonnummer.")
                )
            } else {
                ForEach(matches) { person in
                    HStack(spacing: 8) {
                    Button {
                        if person.numbers.count == 1, let number = person.numbers.first {
                            onCall(person.callContact(for: number))
                        } else { selected = person }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle").font(.title).foregroundStyle(FonooStyle.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(person.name).foregroundStyle(.primary)
                                Text(person.numbers.count == 1 ? person.numbers[0].value : "\(person.numbers.count) Rufnummern")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "phone").foregroundStyle(FonooStyle.accent)
                        }.padding(.vertical, 5)
                    }
                    .accessibilityLabel("\(person.name), \(person.numbers.count == 1 ? "Anruf starten" : "Rufnummer auswählen")")
                    .buttonStyle(.borderless)
                    DeviceContactFavoriteButton(person: person)
                    }
                }
            }
            Section {
                Text("Tippe auf den Stern, um eine Rufnummer als Favorit zu speichern.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await directory.refresh() }
    }

    private var accessView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.rectangle.stack").font(.system(size: 44)).foregroundStyle(FonooStyle.accent)
                Text(directory.access == .restricted ? "Zugriff eingeschränkt" : "Deine Kontakte in fonoo").font(.title2.weight(.semibold))
                Text(directory.access == .restricted
                     ? "Der Kontaktzugriff ist durch die Geräteeinstellungen eingeschränkt."
                     : "Finde Namen und Telefonnummern direkt aus deinen iPhone-Kontakten. fonoo lädt dein Adressbuch nicht auf einen Server hoch.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let message = directory.errorMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if directory.access == .notRequested {
                    Button("Kontakte freigeben") { Task { await directory.requestAccess() } }.buttonStyle(.borderedProminent)
                } else if directory.access == .denied {
                    Text("Du kannst den Kontaktzugriff in den iPhone-Einstellungen erlauben.").font(.footnote).multilineTextAlignment(.center)
                    Button("Einstellungen öffnen") { openSettings() }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(maxWidth: .infinity)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

/// Separate from the call button, so managing a favorite never starts a call.
struct DeviceContactFavoriteButton: View {
    @EnvironmentObject private var phone: PhoneStore
    let person: DeviceContact
    @State private var choosingNumber = false
    private func isFavorite(_ number: DevicePhoneNumber) -> Bool {
        let id = person.callContact(for: number).id
        return phone.favorites.contains { $0.id == id }
    }
    private var hasFavorite: Bool { person.numbers.contains { isFavorite($0) } }
    var body: some View {
        Group {
            if person.numbers.count == 1, let number = person.numbers.first {
                Button { phone.toggleFavorite(person.callContact(for: number)) } label: {
                    icon
                }
                .accessibilityLabel("\(person.name): \(isFavorite(number) ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")")
            } else {
                Button { choosingNumber = true } label: { icon }
                .accessibilityLabel("\(person.name): Favoriten-Rufnummern auswählen")
            }
        }
        .buttonStyle(.borderless)
        .tint(FonooStyle.accent)
        .sheet(isPresented: $choosingNumber) {
            DeviceContactNumbersView(person: person, onCall: nil)
        }
    }
    private var icon: some View {
        Image(systemName: hasFavorite ? "star.fill" : "star")
            .font(.title3).foregroundStyle(FonooStyle.accent)
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

/// The same explicit number list is available from both the contact and its star.
struct DeviceContactNumbersView: View {
    @EnvironmentObject private var phone: PhoneStore
    @Environment(\.dismiss) private var dismiss
    let person: DeviceContact
    let onCall: ((Contact) -> Void)?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(person.numbers) { number in
                        let contact = person.callContact(for: number)
                        let favorite = phone.favorites.contains { $0.id == contact.id }
                        HStack(spacing: 12) {
                            if let onCall {
                                Button {
                                    dismiss()
                                    onCall(contact)
                                } label: {
                                    HStack {
                                        numberLabel(number)
                                        Spacer()
                                        Image(systemName: "phone").foregroundStyle(FonooStyle.accent)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(number.label), \(number.value), anrufen")
                            } else {
                                numberLabel(number)
                                Spacer()
                            }
                            Button { phone.toggleFavorite(contact) } label: {
                                Image(systemName: favorite ? "star.fill" : "star")
                                    .font(.title3).foregroundStyle(FonooStyle.accent)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(number.label), \(number.value): \(favorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")")
                        }
                    }
                } footer: {
                    Text("Jede Rufnummer kann einzeln als Favorit gespeichert werden. Ein ausgefüllter Stern zeigt deine Auswahl.")
                }
                if let notice = phone.notice { Text(notice).foregroundStyle(.secondary) }
            }
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .tint(FonooStyle.accent)
    }
    private func numberLabel(_ number: DevicePhoneNumber) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(number.label).font(.subheadline).foregroundStyle(.secondary)
            Text(number.value).foregroundStyle(.primary)
        }.padding(.vertical, 4)
    }
}
