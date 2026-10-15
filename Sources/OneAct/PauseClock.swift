import CoreMedia

/// The pause bookkeeping behind a recording's timestamps.
///
/// Split out from the recorder because this arithmetic decides every timestamp
/// that reaches the file: get it wrong and the recording still *looks* fine
/// while playing back out of sync, or reporting a duration that includes time
/// nobody recorded. On its own it can be exercised without a camera.
///
/// Paused stretches are removed rather than preserved — resuming closes the gap
/// so the file plays continuously, which is the whole point of pausing instead
/// of stopping.
struct PauseClock {
    private(set) var isPaused = false
    /// Total source time skipped so far. Every emitted timestamp is shifted
    /// back by this much.
    private(set) var skipped: CMTime = .zero
    /// Presentation time of the first sample dropped by the current pause.
    /// Taken from a real sample rather than a wall clock so the gap is measured
    /// on the same timeline the writer uses.
    private var anchor: CMTime?

    mutating func pause() {
        isPaused = true
    }

    mutating func resume() {
        isPaused = false
    }

    mutating func reset() {
        isPaused = false
        skipped = .zero
        anchor = nil
    }

    /// Writer-clock time for a sample presented at `presentationTime`, or nil
    /// when the sample falls inside a paused stretch and must be dropped.
    ///
    /// Call once per sample actually headed for the writer. Video and audio
    /// share one clock, so whichever track delivers first after a resume closes
    /// the gap for both — they must not be shifted by different amounts.
    mutating func writerTime(for presentationTime: CMTime) -> CMTime? {
        guard presentationTime.isValid else { return nil }
        if isPaused {
            if anchor == nil { anchor = presentationTime }
            return nil
        }
        if let anchor {
            // A resume with no samples in between leaves nothing to skip.
            let gap = presentationTime - anchor
            if gap > .zero { skipped = skipped + gap }
            self.anchor = nil
        }
        return presentationTime - skipped
    }
}

/// A copy of `sampleBuffer` with every timestamp moved back by `offset`.
///
/// Offsets each entry of the existing timing array instead of replacing it with
/// one entry. An audio buffer carries hundreds of samples described by a single
/// timing entry whose `duration` is the duration of *one* sample; rewriting that
/// entry with the buffer's total duration would stretch the audio by the sample
/// count and desynchronise everything after the first pause.
func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, offsetBy offset: CMTime) -> CMSampleBuffer? {
    var entryCount: CMItemCount = 0
    guard CMSampleBufferGetSampleTimingInfoArray(
        sampleBuffer,
        entryCount: 0,
        arrayToFill: nil,
        entriesNeededOut: &entryCount
    ) == noErr, entryCount > 0 else { return nil }

    var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(entryCount))
    guard CMSampleBufferGetSampleTimingInfoArray(
        sampleBuffer,
        entryCount: entryCount,
        arrayToFill: &timings,
        entriesNeededOut: nil
    ) == noErr else { return nil }

    for index in timings.indices {
        if timings[index].presentationTimeStamp.isValid {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp - offset
        }
        if timings[index].decodeTimeStamp.isValid {
            timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - offset
        }
    }

    var output: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault,
        sampleBuffer: sampleBuffer,
        sampleTimingEntryCount: entryCount,
        sampleTimingArray: &timings,
        sampleBufferOut: &output
    ) == noErr else { return nil }
    return output
}
