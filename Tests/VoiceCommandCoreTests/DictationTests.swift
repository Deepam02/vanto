import Testing
@testable import VoiceCommandCore

@Suite struct DictationTests {
    /// The 3 Nov prompt that was lost, as the transcriber split it at each pause.
    @Test func mendsPausesAndDropsFillers() {
        let segments = [
            "Can you draft a prompt for this? Like the prompt is I think we need to improve the redesigning of the screens.",
            "Um let me think.",
            "Like for example, we need to add some sort of Linear to it I guess.",
            "Uh and like.",
            "Cleaner onboarding.",
        ]
        #expect(Dictation.clean(segments) ==
            "Can you draft a prompt for this? Like the prompt is I think we need to improve the redesigning of the screens. Let me think. Like for example, we need to add some sort of Linear to it I guess. And like cleaner onboarding.")
    }

    @Test func joinKeepsWordsVerbatim() {
        #expect(Dictation.join(["We need to.", "Ship it today."]) == "We need to ship it today.")
        #expect(Dictation.join(["Done.", "Next thing."]) == "Done. Next thing.")
        #expect(Dictation.join(["Ask if.", "I can come."]) == "Ask if. I can come.")
        #expect(Dictation.join(["Tell them that.", "I said yes."]) == "Tell them that I said yes.")
    }

    @Test func fillerOnlyIsEmpty() {
        #expect(Dictation.clean(["Um.", "Uh,"]) == "")
        #expect(Dictation.clean(["um, hello there"]) == "Hello there")
    }
}
