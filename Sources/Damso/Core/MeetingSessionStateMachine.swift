import Foundation

/// Tunables for the detection session lifecycle. PRD-fixed values live next
/// to agent-owned constants so both are adjustable in code without settings.
enum MeetingSessionDefaults {
    /// Fixed end-of-meeting grace (PRD: 60s, not exposed in settings).
    static let graceSeconds: TimeInterval = 60
    /// Recordings shorter than this get the discard confirmation (PRD: 5min).
    static let shortCutoffSeconds: TimeInterval = 300
    /// How long the discard confirmation waits before auto-discarding
    /// (agent-owned default: 5min).
    static let discardTimeoutSeconds: TimeInterval = 300
    /// How long the prompt panel outlives a mic drop before the session is
    /// considered over (agent-owned; mirrors the recording grace so a flapping
    /// mic never re-prompts the same meeting).
    static let promptDismissGraceSeconds: TimeInterval = 60
}

/// One detected meeting session. Simultaneous meetings (Zoom app + browser)
/// merge into a single session: one panel, one recording, and the first
/// detected source stays representative.
struct MeetingSessionInfo: Equatable, Sendable {
    var id: UUID
    var representative: DetectedMeetingSource
    var sources: [DetectedMeetingSource]
    var firstDetectedAt: Date
    var recordingStartedAt: Date?
}

/// The session lifecycle: detected → prompting → recording → grace → pipeline
/// / short-recording confirmation → idle. Ignored meeting-room identities are
/// tracked per source app so several dismissed meetings stay suppressed while
/// unrelated rooms or the same room in a different browser can still prompt.
enum MeetingSessionState: Equatable, Sendable {
    case idle
    /// Panel shows the full record proposal for the whole meeting.
    /// `quietSince` is set while every source's mic is off.
    case prompting(MeetingSessionInfo, quietSince: Date?)
    case recording(MeetingSessionInfo)
    /// Mic ended on all sources; waiting out the grace before stopping.
    case grace(MeetingSessionInfo, since: Date)
    /// A sub-cutoff recording ended; panel asks discard-or-keep until the
    /// deadline, then auto-discards.
    case shortRecordingConfirm(MeetingSessionInfo, duration: TimeInterval, deadline: Date)
}

/// Side effects the runtime must perform after an event. The machine itself
/// never records, attaches, or deletes anything (guardrail G4: nothing
/// happens before explicit approval).
enum MeetingSessionEffect: Equatable, Sendable {
    case startRecording(MeetingSessionInfo)
    case stopRecording(MeetingSessionInfo)
    /// Recording met the cutoff (or the user chose keep): run the pipeline.
    case processRecording(MeetingSessionInfo)
    /// Recording is below the cutoff and was discarded.
    case discardRecording(MeetingSessionInfo)
}

/// Pure, clock-injected session state machine. The runtime feeds it observed
/// sources and user actions; tests drive it with synthetic dates.
struct MeetingSessionStateMachine: Sendable {
    private(set) var state: MeetingSessionState = .idle
    private(set) var ignoredMeetingKeys: Set<String> = []
    private var ignoredMeetingQuietSince: [String: Date] = [:]

    var graceSeconds: TimeInterval = MeetingSessionDefaults.graceSeconds
    var shortCutoffSeconds: TimeInterval = MeetingSessionDefaults.shortCutoffSeconds
    var discardTimeoutSeconds: TimeInterval = MeetingSessionDefaults.discardTimeoutSeconds
    var promptDismissGraceSeconds: TimeInterval = MeetingSessionDefaults.promptDismissGraceSeconds

    init(
        graceSeconds: TimeInterval = MeetingSessionDefaults.graceSeconds,
        shortCutoffSeconds: TimeInterval = MeetingSessionDefaults.shortCutoffSeconds,
        discardTimeoutSeconds: TimeInterval = MeetingSessionDefaults.discardTimeoutSeconds,
        promptDismissGraceSeconds: TimeInterval = MeetingSessionDefaults.promptDismissGraceSeconds
    ) {
        self.graceSeconds = graceSeconds
        self.shortCutoffSeconds = shortCutoffSeconds
        self.discardTimeoutSeconds = discardTimeoutSeconds
        self.promptDismissGraceSeconds = promptDismissGraceSeconds
    }

    /// Feed the current detection result. Also advances time-based
    /// transitions, so a periodic tick can call this with unchanged sources.
    mutating func observe(sources observedSources: [DetectedMeetingSource], at now: Date) -> [MeetingSessionEffect] {
        let sources = eligibleSources(from: observedSources, at: now)
        switch state {
        case .idle:
            guard let first = sources.first else { return [] }
            let session = MeetingSessionInfo(
                id: UUID(),
                representative: first,
                sources: sources,
                firstDetectedAt: now,
                recordingStartedAt: nil
            )
            state = .prompting(session, quietSince: nil)
            return []

        case .prompting(var session, let quietSince):
            if sources.isEmpty {
                let quietStart = quietSince ?? now
                if now.timeIntervalSince(quietStart) >= promptDismissGraceSeconds {
                    state = .idle
                } else {
                    state = .prompting(session, quietSince: quietStart)
                }
                return []
            }
            session.merge(sources: sources)
            // Same meeting, mic came back: clear the quiet timer, no re-prompt.
            state = .prompting(session, quietSince: nil)
            return []

        case .recording(var session):
            if sources.isEmpty {
                state = .grace(session, since: now)
                return []
            }
            session.merge(sources: sources)
            state = .recording(session)
            return []

        case .grace(var session, let since):
            if sources.isEmpty {
                if now.timeIntervalSince(since) >= graceSeconds {
                    return finishRecording(session: session, at: now)
                }
                return []
            }
            // Mic returned within the grace: continue the same recording.
            session.merge(sources: sources)
            state = .recording(session)
            return []

        case .shortRecordingConfirm(let session, _, let deadline):
            // The confirmation blocks new sessions until resolved; a still
            // ongoing meeting is re-detected on the next observe after that.
            if now >= deadline {
                state = .idle
                var effects: [MeetingSessionEffect] = [.discardRecording(session)]
                // An ongoing meeting re-prompts as a fresh session.
                effects.append(contentsOf: observe(sources: sources, at: now))
                return effects
            }
            return []
        }
    }

    /// The user pressed [녹음]. Only valid while prompting.
    mutating func approveRecording(at now: Date) -> [MeetingSessionEffect] {
        guard case .prompting(var session, _) = state else { return [] }
        session.recordingStartedAt = now
        state = .recording(session)
        return [.startRecording(session)]
    }

    /// The user pressed [무시]: hide this proposal and suppress only this
    /// meeting room in this source app. Another room or browser remains
    /// eligible immediately.
    mutating func ignorePrompt() {
        guard case .prompting(let session, _) = state else { return }
        for key in session.sources.map(\.meetingIdentityKey) {
            ignoredMeetingKeys.insert(key)
            ignoredMeetingQuietSince.removeValue(forKey: key)
        }
        state = .idle
    }

    /// The user pressed [중지]: immediate stop, no grace, same cutoff rule.
    mutating func stopPressed(at now: Date) -> [MeetingSessionEffect] {
        switch state {
        case .recording(let session), .grace(let session, _):
            return finishRecording(session: session, at: now)
        default:
            return []
        }
    }

    /// The runtime could not actually start capture (permissions, capture
    /// failure). The session returns to prompting so the panel keeps offering
    /// [녹음] and the failure stays visible instead of a phantom recording.
    mutating func recordingFailedToStart() {
        guard case .recording(var session) = state else { return }
        session.recordingStartedAt = nil
        state = .prompting(session, quietSince: nil)
    }

    /// The user chose [그래도 보관] in the short-recording confirmation.
    mutating func keepShortRecording() -> [MeetingSessionEffect] {
        guard case .shortRecordingConfirm(let session, _, _) = state else { return [] }
        state = .idle
        return [.processRecording(session)]
    }

    /// The user chose [버리기] in the short-recording confirmation.
    mutating func discardShortRecording() -> [MeetingSessionEffect] {
        guard case .shortRecordingConfirm(let session, _, _) = state else { return [] }
        state = .idle
        return [.discardRecording(session)]
    }

    private mutating func finishRecording(session: MeetingSessionInfo, at now: Date) -> [MeetingSessionEffect] {
        let duration = now.timeIntervalSince(session.recordingStartedAt ?? now)
        if duration >= shortCutoffSeconds {
            state = .idle
            return [.stopRecording(session), .processRecording(session)]
        }
        state = .shortRecordingConfirm(session, duration: duration, deadline: now.addingTimeInterval(discardTimeoutSeconds))
        return [.stopRecording(session)]
    }

    /// Filters dismissed rooms before the ordinary session lifecycle sees
    /// them. Suppression survives brief mic drops and is released only after
    /// the room has stayed absent for the prompt grace interval.
    private mutating func eligibleSources(
        from observed: [DetectedMeetingSource],
        at now: Date
    ) -> [DetectedMeetingSource] {
        let activeKeys = Set(observed.map(\.meetingIdentityKey))
        for key in Array(ignoredMeetingKeys) {
            if activeKeys.contains(key) {
                ignoredMeetingQuietSince.removeValue(forKey: key)
                continue
            }
            if let quietSince = ignoredMeetingQuietSince[key] {
                if now.timeIntervalSince(quietSince) >= promptDismissGraceSeconds {
                    ignoredMeetingKeys.remove(key)
                    ignoredMeetingQuietSince.removeValue(forKey: key)
                }
            } else {
                ignoredMeetingQuietSince[key] = now
            }
        }
        return observed.filter { !ignoredMeetingKeys.contains($0.meetingIdentityKey) }
    }
}

private extension MeetingSessionInfo {
    /// Unions newly observed sources into the session. The representative
    /// (first detected) never changes, so the panel title stays stable during
    /// simultaneous meetings.
    mutating func merge(sources observed: [DetectedMeetingSource]) {
        for source in observed {
            if let index = sources.firstIndex(where: { $0.sourceIdentityKey == source.sourceIdentityKey }) {
                sources[index] = source
            } else {
                sources.append(source)
            }
        }
    }
}
