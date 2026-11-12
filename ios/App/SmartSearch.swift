// Ask the library in words ("124 to 128 in 8A, under 7 minutes", "what mixes with what's playing"): Apple's
// on-device model (Foundation Models, Apple Intelligence, iOS 26+) turns the sentence into a SmartFilter, and the
// filtering itself is ordinary code. Nothing leaves the phone: no Private Cloud Compute, no other service.
// Only offered where the model is ready (iPhone 15 Pro, iPhone 16 or later, M1+/A17 Pro iPads with Apple
// Intelligence on); everywhere else the button isn't there and the normal search is unchanged.
import Foundation
import CrateboxKit
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SmartSearch {
    /// true only when Apple's on-device model is ready on this device right now
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Apple Intelligence isn't available on this device" }
    }
    /// One short session per question (a few hundred tokens of the 4,096 the model allows).
    static func filter(for sentence: String, playing: (bpm: Double, key: Int)?) async throws -> SmartFilter {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                Turn a DJ's request into a filter for their music library. Tempo is in BPM. Keys are Camelot keys \
                like 8A or 11B. Use 0 or an empty list for anything the request doesn't mention.
                """)
            let a = try await session.respond(to: sentence, generating: SmartAsk.self).content
            return SmartFilter.checked(words: a.words, bpmMin: a.bpmMin, bpmMax: a.bpmMax, keys: a.keys,
                                       minMinutes: a.minMinutes, maxMinutes: a.maxMinutes, fitsPlaying: a.fitsPlaying, playing: playing)
        }
        #endif
        throw Failure.unavailable
    }
}

#if canImport(FoundationModels)
/// What the model fills in. Plain numbers with 0 for "not said" (simpler for a small model than optionals).
@available(iOS 26.0, *)
@Generable struct SmartAsk {
    @Guide(description: "Words to look for in track titles or artist names, only if the request names some")
    var words: [String]
    @Guide(description: "Lowest tempo in BPM, or 0")
    var bpmMin: Double
    @Guide(description: "Highest tempo in BPM, or 0. For a single tempo, the same as bpmMin")
    var bpmMax: Double
    @Guide(description: "Camelot keys such as 8A or 9B, or empty")
    var keys: [String]
    @Guide(description: "Shortest track length in minutes, or 0")
    var minMinutes: Double
    @Guide(description: "Longest track length in minutes, or 0")
    var maxMinutes: Double
    @Guide(description: "True if they want tracks that mix with the track playing now")
    var fitsPlaying: Bool
}
#endif
