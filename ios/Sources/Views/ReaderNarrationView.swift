import Foundation

enum ReaderNarrator {
    static func kyon(voices: [RemoteVoice], engines: [RemoteEngine]) throws -> RemoteVoice {
        guard engines.contains(where: { $0.id == "voicestudio" && $0.available }) else {
            throw BookError.message("OmniVoice is unavailable. Start VoiceStudio on your PC and check its external engine connection in Studio.")
        }
        let matches = voices.filter { $0.engine == "voicestudio" && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Kyon") == .orderedSame }
        guard matches.count == 1, let voice = matches.first else {
            throw BookError.message(matches.isEmpty ? "Kyon is not available from your paired PC. Add the Kyon voice in VoiceStudio, then refresh." : "More than one Kyon voice is available. Give the intended voice a unique Kyon name in VoiceStudio, then refresh.")
        }
        return voice
    }
}
