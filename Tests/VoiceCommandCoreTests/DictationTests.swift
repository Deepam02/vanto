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

@Suite struct VoiceDictationEndTests {
    @Test func endsOnSendOrDone() {
        #expect(Dictation.endCommand(in: "Send it.") == ("", .send))
        #expect(Dictation.endCommand(in: "When should we introduce the sidebar. Send it.") == ("When should we introduce the sidebar", .send))
        #expect(Dictation.endCommand(in: "and that's the plan, okay send it") == ("and that's the plan", .send))
        #expect(Dictation.endCommand(in: "Done.") == ("", .done))
        #expect(Dictation.endCommand(in: "the rest is fine, stop dictating") == ("the rest is fine", .done))
        #expect(Dictation.endCommand(in: "Cancel dictation") == ("", .cancel))
    }

    @Test func contentThatMentionsSendStaysContent() {
        #expect(Dictation.endCommand(in: "Tell them I will send the files tomorrow") == ("Tell them I will send the files tomorrow", nil))
        #expect(Dictation.endCommand(in: "We are almost done with it") == ("We are almost done with it", nil))
    }
}
