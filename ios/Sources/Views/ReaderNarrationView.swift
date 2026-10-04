import Foundation

enum ReaderNarrator {
    static func kyon(voices: [RemoteVoice], engines: [RemoteEngine]) throws -> RemoteVoice {
        for engineID in ["omnivoice", "voicestudio"] {
            guard engines.contains(where: { $0.id == engineID && $0.available }) else { continue }
            let matches = voices.filter { $0.engine == engineID && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Kyon") == .orderedSame }
            if matches.isEmpty { continue }
            guard matches.count == 1, let voice = matches.first else {
                throw BookError.message("More than one Kyon voice is available in \(engineID == "omnivoice" ? "the companion" : "VoiceStudio"). Give the intended voice a unique Kyon name, then refresh.")
            }
            return voice
        }
        throw BookError.message("Kyon is unavailable. Install OmniVoice and add the Kyon voice in your PC companion, then refresh.")
    }
}
