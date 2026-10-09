import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var phone: PhoneStore
    @ObservedObject var diagnostics: Diagnostics
    var showsProtocolLinks = true
    var body: some View {
        List {
            Section { SIPConnectionStatusView() }
            if showsProtocolLinks {
                Section("Protokolle") {
                    NavigationLink("Registrierungsprotokoll") { RegistrationConsoleView(diagnostics: diagnostics) }
                    NavigationLink("SIP-Meldungen") { SIPMessagesView(diagnostics: diagnostics) }
                }
            }
            Section("Verbindungsstatus") {
                Label(phone.registration.label, systemImage: phone.registration == .registered ? "checkmark.circle.fill" : "network")
                    .font(.headline)
                    .foregroundStyle(phone.registration == .registered ? Color.green : Color.primary)
                detail("Netzwerk", phone.networkLabel)
                detail("Gespräch", callStatus)
                Text(registrationHint).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            Section("Gespeicherte Verbindung") {
                if phone.account.server.isEmpty {
                    Label("Noch kein SIP-Konto eingerichtet", systemImage: "person.crop.circle.badge.exclamationmark")
                } else {
                    detail("Registrar / Proxy", phone.account.server)
                    detail("SIP-Domain", phone.account.effectiveDomain)
                    detail("Transport / Port", "\(phone.account.transport.rawValue) · \(phone.account.port)")
                    detail("Audio-Vorgabe", phone.account.mediaEncryption.rawValue)
                    detail("Codecs", phone.account.compatibility.g711Only ? "G.711 · PCMA/PCMU" : "SDK-Standard")
                    detail("Medienweg-Auswahl", phone.account.compatibility.forceTURN ? "TURN erzwungen" : "Automatisch")
                    detail("DTMF", phone.account.dtmf.rawValue)
                    detail("ICE", phone.account.nat.iceEnabled ? "Aktiviert" : "Ausgeschaltet")
                    if let endpoint = phone.account.nat.effectiveEndpoint {
                        detail(phone.account.nat.usesTURN ? "TURN-Server" : "STUN-Server", endpoint)
                        if phone.account.nat.usesTURN { detail("TURN-Transport", phone.account.nat.turnTransport.rawValue) }
                    }
                }
            }
            if let media = diagnostics.media {
                Section("Aktuelles Audio") {
                    LabeledContent("ICE / Medienweg", value: media.iceStatus)
                    LabeledContent("Codec", value: media.codec)
                    LabeledContent("Audio-Richtung", value: media.audioDirection)
                    LabeledContent("Mikrofoneingang", value: media.inputDevice)
                    LabeledContent("Audioausgang", value: media.outputDevice)
                    LabeledContent("Empfang", value: String(format: "%.1f kbit/s", media.downloadKbps))
                    LabeledContent("Senden", value: String(format: "%.1f kbit/s", media.uploadKbps))
                    LabeledContent(media.jitterLabel, value: String(format: "%.1f ms", media.jitterMs))
                    LabeledContent("Paketverlust Empfang", value: String(format: "%.1f %%", media.lossPercent))
                }
            } else {
                Section("Aktuelles Audio") {
                    Label(phone.call == nil ? "Kein laufendes Gespräch" : "Noch keine Audiomesswerte", systemImage: "waveform")
                        .font(.headline)
                    Text("Codec, Datenrate und Paketverlust erscheinen, sobald die Telefonie-Engine Messwerte für ein Gespräch liefert.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                if diagnostics.entries.isEmpty {
                    Text("Noch keine Ereignisse. Registrierungsversuche, Netzwerkänderungen und Gespräche werden hier angezeigt.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(diagnostics.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.message).font(.body).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Ereignisse · \(diagnostics.entries.count)") }
              footer: { Text("Neueste zuerst. Wiederholte Netzwerk-Meldungen bestätigen nur den Netzstatus, keine SIP-Registrierung.") }
            Section { Text("Nur dieser App-Lauf. Keine Zugangsdaten, Rufnummern oder DTMF-Ziffern im Protokoll.").font(.footnote) }
        }.scrollContentBackground(.hidden).background(FonooStyle.background)
            .navigationTitle("Verbindungsdetails").navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.padding(.vertical, 3)
    }

    private var registrationHint: String {
        switch phone.registration {
        case .offline:
            phone.account.server.isEmpty
                ? "Richte unter SIP-Konto zuerst deine Verbindung ein."
                : "Das Konto ist derzeit nicht registriert. Öffne SIP-Konto und wähle „Erneut registrieren“, wenn deine Zugangsdaten bereits gespeichert sind."
        case .registering: "Die Anmeldung an der Telefonanlage läuft. Das Ergebnis erscheint hier automatisch."
        case .registered: "Die Telefonanlage hat die Anmeldung bestätigt. Die Audioverbindung lässt sich erst während eines Gesprächs beurteilen."
        case .unregistering: "Die Abmeldung von der Telefonanlage läuft."
        case .failed: "Die Anmeldung ist fehlgeschlagen. Prüfe Server, Transport, Port und Zugangsdaten im SIP-Konto. Ein vorhandener Fehlercode steht oben."
        }
    }

    private var callStatus: String {
        guard let call = phone.call else { return phone.busy ? "Anruf wird vorbereitet" : "Kein laufendes Gespräch" }
        if call.isHeld { return "Gehalten" }
        if call.isRemoteHeld { return "Von der Gegenstelle gehalten" }
        switch call.phase {
        case .incoming: return "Eingehender Anruf"
        case .connecting: return "Verbindung wird aufgebaut"
        case .ringing: return "Gegenstelle klingelt"
        case .active: return "Verbunden"
        case .ending: return "Gespräch wird beendet"
        }
    }
}


struct RegistrationConsoleView: View {
    @ObservedObject var diagnostics: Diagnostics
    @State private var followLatest = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("SIP-Registrierung").font(.headline)
                Text("Live-Ablauf der Anmeldung · maximal 300 Einträge dieses App-Laufs. SDK-Zustände und lokale Schritte, kein SIP-Paketmitschnitt.")
                    .font(.subheadline)
                Toggle("Neueste Meldung verfolgen", isOn: $followLatest)
                    .font(.subheadline)
            }.padding()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if diagnostics.registrationEntries.isEmpty {
                            Text("Noch kein Registrierungsversuch protokolliert.\nStarte unter SIP-Konto mit „Speichern und registrieren“. Danach erscheint der Ablauf hier.")
                                .foregroundStyle(.white)
                        }
                        ForEach(diagnostics.registrationEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                                    .foregroundStyle(Color(white: 0.72))
                                Text(entry.message).foregroundStyle(entry.message.hasPrefix("FEHLER:") ? Color(red: 1, green: 0.65, blue: 0.6) : .white)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
                .background(Color(red: 0.08, green: 0.07, blue: 0.12))
                .onAppear { if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: diagnostics.registrationEntries.last?.id) { _, _ in
                    if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: followLatest) { _, follow in
                    if follow { proxy.scrollTo("latest", anchor: .bottom) }
                }
            }
            Text("Passwörter, Authentifizierungsheader und SIP-Adressen werden nicht aufgezeichnet.")
                .font(.footnote).padding()
        }
        .background(FonooStyle.background)
        .navigationTitle("Registrierungsprotokoll")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SIPMessagesView: View {
    @EnvironmentObject private var phone: PhoneStore
    @ObservedObject var diagnostics: Diagnostics
    @State private var followLatest = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("SIP-Mitschnitt aktiv", isOn: Binding(get: { phone.sipTracing }, set: { phone.setSIPTracing($0) }))
                    .font(.headline)
                    .disabled(!phone.supportsSIPTracing)
                if !phone.supportsSIPTracing {
                    Text("Die aktive Engine stellt keinen SIP-Paketmitschnitt bereit.").font(.footnote)
                }
                Text("Vor dem Registrieren aktivieren. Zeigt SIP-Adressen und Rufnummern; Authentifizierung und Schlüssel sind ausgeblendet. Nur im Arbeitsspeicher, maximal 150 Meldungen.")
                    .font(.footnote)
                Toggle("Neueste Meldung verfolgen", isOn: $followLatest).font(.subheadline)
            }.padding()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if diagnostics.sipPackets.isEmpty {
                            Text(!phone.supportsSIPTracing ? "Für die aktive Engine ist kein SIP-Paketmitschnitt verfügbar." : phone.sipTracing ? "Warte auf SIP-Meldungen …\nGehe zurück zum SIP-Konto und starte die Registrierung. Ohne erreichbaren Server kann zunächst nur eine gesendete Meldung erscheinen." : "Mitschnitt ausgeschaltet. Aktiviere ihn vor dem nächsten Registrierungsversuch.")
                                .foregroundStyle(.white)
                        }
                        ForEach(diagnostics.sipPackets) { packet in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(packet.direction).fontWeight(.bold)
                                    Spacer()
                                    Text(packet.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                                }.foregroundStyle(Color(red: 0.65, green: 0.8, blue: 1))
                                Text(packet.text).foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider().overlay(Color.gray)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding()
                }.background(Color(red: 0.08, green: 0.07, blue: 0.12))
                    .onAppear { if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: diagnostics.sipPackets.last?.id) { _, _ in
                        if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
                    }
                    .onChange(of: followLatest) { _, enabled in
                        if enabled { proxy.scrollTo("latest", anchor: .bottom) }
                    }
            }
            Text("Gefilterte SDK-Meldungen, kein vollständiger Netzwerkmitschnitt. Nicht freigegebene Header und Nachrichteninhalte werden ausgeblendet.")
                .font(.footnote).padding()
        }.background(FonooStyle.background)
            .navigationTitle("SIP-Meldungen").navigationBarTitleDisplayMode(.inline)
    }
}
