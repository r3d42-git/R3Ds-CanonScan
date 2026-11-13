import AppKit
import Foundation

struct ScanSettings: Codable, Equatable, Sendable {
    var resolution = 300
    var mode: ScanMode = .gray
    var duplex = true
    var recognizeText = true
    static let resolutions = [150, 200, 300, 400, 600]
}

enum ScanMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case color = "Color", gray = "Gray", lineart = "Lineart"
    var id: String { rawValue }
    var title: String {
        switch self { case .color: "Farbe"; case .gray: "Graustufen"; case .lineart: "Schwarzweiß" }
    }
}

enum PageAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, gray, blackAndWhite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original"
        case .gray: "Graustufen"
        case .blackAndWhite: "Schwarzweiß"
        }
    }
}

@MainActor final class SettingsStore: ObservableObject {
    @Published var options: ScanSettings {
        didSet {
            if let data = try? JSONEncoder().encode(options) {
                UserDefaults.standard.set(data, forKey: "scanOptions")
            }
        }
    }
    init() {
        if let data = UserDefaults.standard.data(forKey: "scanOptions"),
           let value = try? JSONDecoder().decode(ScanSettings.self, from: data),
           ScanSettings.resolutions.contains(value.resolution) {
            var supported = value
            if supported.mode == .color { supported.mode = .gray }
            options = supported
            if supported != value, let migrated = try? JSONEncoder().encode(supported) {
                UserDefaults.standard.set(migrated, forKey: "scanOptions")
            }
        }
        else { options = ScanSettings() }
    }
}

struct ScanPage: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let imageURL: URL
    let dpi: Int
    var rotation: Int
    var label: String
    var cleanScannerEdges: Bool
    var appearance: PageAppearance
    init(id: UUID = UUID(), imageURL: URL, dpi: Int, rotation: Int = 0, label: String = "", cleanScannerEdges: Bool = true, appearance: PageAppearance = .gray) {
        self.id = id
        self.imageURL = imageURL
        self.dpi = dpi
        self.rotation = ((rotation % 360) + 360) % 360
        self.label = label
        self.cleanScannerEdges = cleanScannerEdges
        self.appearance = appearance
    }
    private enum CodingKeys: String, CodingKey { case id, imageURL, dpi, rotation, label, cleanScannerEdges, appearance }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        imageURL = try values.decode(URL.self, forKey: .imageURL)
        dpi = try values.decode(Int.self, forKey: .dpi)
        let decodedRotation = try values.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        rotation = ((decodedRotation % 360) + 360) % 360
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
        cleanScannerEdges = try values.decodeIfPresent(Bool.self, forKey: .cleanScannerEdges) ?? true
        // Keep existing sessions visually unchanged when introducing output processing.
        appearance = try values.decodeIfPresent(PageAppearance.self, forKey: .appearance) ?? .original
    }
    mutating func rotateClockwise() { rotation = (rotation + 90) % 360 }
    static func pointSize(pixelWidth: Int, pixelHeight: Int, dpi: Int, rotation: Int) -> CGSize {
        let scale = 72 / CGFloat(max(dpi, 1))
        let swap = (rotation % 180) != 0
        return CGSize(width: CGFloat(swap ? pixelHeight : pixelWidth) * scale,
                      height: CGFloat(swap ? pixelWidth : pixelHeight) * scale)
    }
}

struct ScannerDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    static func parse(_ output: String) -> [Self] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2, !fields[0].isEmpty else { return nil }
            return Self(id: fields[0], name: fields[1])
        }.sorted { a, b in
            let aCanon = a.id.hasPrefix("canon_dr:"), bCanon = b.id.hasPrefix("canon_dr:")
            if aCanon != bCanon { return aCanon }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

struct ScannerFailure: LocalizedError, Sendable {
    let message: String
    let details: String
    var errorDescription: String? { message }
    static func status(_ code: Int32, details: String) -> Self {
        let message: String
        switch code {
        case 1: message = "Diese Scanfunktion wird vom Gerät nicht unterstützt."
        case 2: message = "Der Scan wurde abgebrochen."
        case 3: message = "Der Scanner ist belegt. Beende andere Scanprogramme und versuche es erneut."
        case 4: message = "Der Scanner hat eine Einstellung abgelehnt. Prüfe Auflösung und Farbmodus."
        case 5: message = "Der Scan wurde vorzeitig beendet. Bereits eingelesene Seiten bleiben erhalten."
        case 6: message = "Papierstau. Entferne das Papier vorsichtig und lege es erneut ein."
        case 7: message = "Im Einzug liegt kein Papier. Lege Seiten ein und starte erneut."
        case 8: message = "Die Scannerabdeckung ist geöffnet. Schließe sie und versuche es erneut."
        case 9: message = "Die Verbindung zum Scanner wurde unterbrochen. Prüfe das USB-Kabel."
        case 10: message = "Es ist nicht genügend Arbeitsspeicher für diesen Scan verfügbar."
        case 11: message = "Der Zugriff auf den Scanner wurde verweigert. Prüfe die USB-Freigabe."
        default: message = "Der Scanner konnte den Vorgang nicht abschließen. Bereits eingelesene Seiten bleiben erhalten."
        }
        return Self(message: message, details: details)
    }
}
