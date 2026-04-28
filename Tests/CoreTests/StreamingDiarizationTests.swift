import Testing
@testable import GrembleVoiceCore

@Suite("Streaming Diarization Types")
struct StreamingDiarizationTests {

    // MARK: - SpeakerLabel

    @Test func speakerLabelDisplayNameFallback() {
        let label = SpeakerLabel(index: 0)
        #expect(label.displayName == "Speaker 1")
        #expect(label.name == nil)
    }

    @Test func speakerLabelDisplayNameWithExplicitName() {
        let label = SpeakerLabel(index: 2, name: "Alice")
        #expect(label.displayName == "Alice")
        #expect(label.index == 2)
    }

    @Test func speakerLabelEquality() {
        let a = SpeakerLabel(index: 1, name: "Bob")
        let b = SpeakerLabel(index: 1, name: "Bob")
        let c = SpeakerLabel(index: 1, name: "Carol")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func speakerLabelHashable() {
        let labels: Set<SpeakerLabel> = [
            SpeakerLabel(index: 0),
            SpeakerLabel(index: 0),
            SpeakerLabel(index: 1),
        ]
        #expect(labels.count == 2)
    }

    // MARK: - DiarizedSegment

    @Test func diarizedSegmentDuration() {
        let seg = DiarizedSegment(
            speaker: SpeakerLabel(index: 0),
            startTime: 1.5,
            endTime: 4.0,
            confidence: 0.9,
            isFinalized: true
        )
        #expect(seg.duration == 2.5)
    }

    @Test func diarizedSegmentZeroDuration() {
        let seg = DiarizedSegment(
            speaker: SpeakerLabel(index: 0),
            startTime: 3.0,
            endTime: 3.0,
            confidence: 0.5,
            isFinalized: false
        )
        #expect(seg.duration == 0)
    }

    // MARK: - StreamingDiarizationUpdate

    @Test func streamingDiarizationUpdateEmpty() {
        let update = StreamingDiarizationUpdate()
        #expect(update.finalizedSegments.isEmpty)
        #expect(update.tentativeSegments.isEmpty)
    }

    @Test func streamingDiarizationUpdateWithSegments() {
        let finalized = DiarizedSegment(
            speaker: SpeakerLabel(index: 0, name: "Alice"),
            startTime: 0.0,
            endTime: 2.0,
            confidence: 0.95,
            isFinalized: true
        )
        let tentative = DiarizedSegment(
            speaker: SpeakerLabel(index: 1),
            startTime: 2.0,
            endTime: 3.5,
            confidence: 0.7,
            isFinalized: false
        )
        let update = StreamingDiarizationUpdate(
            finalizedSegments: [finalized],
            tentativeSegments: [tentative]
        )
        #expect(update.finalizedSegments.count == 1)
        #expect(update.tentativeSegments.count == 1)
        #expect(update.finalizedSegments[0].speaker.displayName == "Alice")
        #expect(update.tentativeSegments[0].speaker.displayName == "Speaker 2")
    }
}
