# fonoo für iOS

Native SwiftUI-App ab iOS 17 mit Liblinphone 5.5.23. Bundle-ID `app.fonoo.ios`; Xcode-Scheme **Fonoo**. Dieses Repository enthält ausschließlich App-Quellen, App-Konfiguration, Assets, Lizenzen und isolierte Prüfungen. Der Telefonie-/Kontoserver wird separat verwaltet.

## Bauen und prüfen

Xcode 27 und Swift auf macOS verwenden. Das bestehende Entwicklungsteam ist im Projekt hinterlegt; eine andere Installation muss ihre eigene passende Signierung einrichten. Private Schlüssel, Provisionierungsprofile und lokale Kontodaten werden nicht übertragen.

```sh
bash ios/Checks/run-checks.sh
python3 ios/Checks/customer-provisioning-checks.py
xcodebuild -project ios/Fonoo.xcodeproj -scheme Fonoo \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/fonoo-ios-build \
  -clonedSourcePackagesDirPath build/SourcePackages build
```

Simulator-Builds regulär signieren: Ohne App-Identität kann der Schlüsselbund die Anmeldung verweigern. Der Simulator verwendet die eigene Anrufoberfläche; Push, native Anrufsteuerung, CarPlay und WLAN/LTE-Übergänge müssen auf einem echten iPhone geprüft werden.

## Funktionen und Struktur

`ios/Fonoo/` enthält Anmeldung und automatische Cloud-Nebenstelle, Geräteprofile, Team/Präsenz, Kontakte/Favoriten, synchronisierte Anrufhistorie, Weiterleitungen und Gesprächssteuerung. VoIP-Push, CallKit/LiveCommunicationKit, Siri und CarPlay bleiben erhalten. `SIPConnectionCoordinator` serialisiert Wiederverbindungen; `LinphoneSIPCore` kapselt die einzige Telefonie-Engine. Zertifikatsprüfung, Pflicht-SRTP und gerätegebundene Schlüsselbundablage bleiben aktiv.

Die [Mac-App](https://github.com/ivama-dev/fonoo-macos) übernimmt einen kontrollierten Stand der gemeinsamen Dateien. Änderungen an Konto-, Verbindungs- und API-Modellen müssen auf beiden Plattformen abgestimmt werden.

## Übernahme

Übernommen wurde der aktuelle Quellstand vom 9. Oktober 2026 (Build 26). Laufzeitcode und Bundle-Identitäten bleiben erhalten. Die bisherige private Git-Historie bleibt im ursprünglichen Repository; sie wurde wegen des dort enthaltenen Servercodes nicht in dieses App-Repository übernommen. Historische Betriebs-/TestFlight-Notizen und interne Screenshots verbleiben ebenfalls dort. Die Migration veröffentlicht keine neue TestFlight-/Store-Version.

## Lizenz

Die fonoo-iOS-App steht wie der Windows-Client unter **GNU Affero General Public License v3 oder später** (`AGPL-3.0-or-later`). Siehe [LICENSE](LICENSE) und [NOTICE.md](NOTICE.md). Drittanbieter behalten ihre eigenen Lizenzen; [Hinweise und unveränderte Lizenzdateien](THIRD-PARTY-NOTICES.md). Automatische GitHub-Prüfungen verwenden synthetische Daten und benötigen keine Produktionszugänge.
