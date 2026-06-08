import Foundation

enum PlaybackMode: String, CaseIterable, Identifiable {
    case window
    case immersive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window:
            "Window"
        case .immersive:
            "Immersive"
        }
    }

    var usesResidentTexture: Bool {
        self == .immersive
    }

    static func commandLineDefault(_ arguments: [String] = CommandLine.arguments) -> PlaybackMode {
        guard let index = arguments.firstIndex(of: "--mode"),
              arguments.indices.contains(index + 1),
              let mode = PlaybackMode(rawValue: arguments[index + 1])
        else {
            return .immersive
        }
        return mode
    }
}
