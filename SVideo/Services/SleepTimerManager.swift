import Foundation

enum SleepTimerMode: Equatable, Sendable {
    case off
    case countdown(endDate: Date)
    case endOfVideo
}

@MainActor
@Observable
final class SleepTimerManager {
    nonisolated static let fadeDurationSeconds: TimeInterval = 15

    private(set) var mode: SleepTimerMode = .off
    private(set) var remainingSeconds: TimeInterval = 0
    private(set) var currentVolume: Double = 1.0

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored var onExpire: (@MainActor () -> Void)?
    @ObservationIgnored var onVolumeChange: (@MainActor (Double) -> Void)?

    var isActive: Bool {
        mode != .off
    }

    var badgeLabel: String? {
        switch mode {
        case .off:
            return nil
        case .endOfVideo:
            return "End of Video"
        case .countdown:
            return VideoLinkBuilder.formatTimecode(remainingSeconds)
        }
    }

    /// Pure fade-out curve: stays at 1.0 until the final `fadeDurationSeconds`,
    /// then tapers linearly down to 0.0 so playback fades out gently before pausing.
    nonisolated static func fadeVolume(forRemaining remaining: TimeInterval) -> Double {
        guard remaining > 0 else { return 0.0 }
        guard remaining < fadeDurationSeconds else { return 1.0 }
        return min(1.0, max(0.0, remaining / fadeDurationSeconds))
    }

    func start(minutes: Int) {
        let endDate = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
        mode = .countdown(endDate: endDate)
        remainingSeconds = TimeInterval(minutes * 60)
        setVolume(1.0)
        startTicker(until: endDate)
    }

    func addMinutes(_ minutes: Int) {
        switch mode {
        case .countdown(let endDate):
            let extended = max(endDate, Date.now).addingTimeInterval(TimeInterval(minutes * 60))
            mode = .countdown(endDate: extended)
            remainingSeconds = extended.timeIntervalSinceNow
            setVolume(Self.fadeVolume(forRemaining: remainingSeconds))
            startTicker(until: extended)
        case .off, .endOfVideo:
            start(minutes: minutes)
        }
    }

    func setEndOfVideo() {
        tickTask?.cancel()
        tickTask = nil
        remainingSeconds = 0
        setVolume(1.0)
        mode = .endOfVideo
    }

    func cancel() {
        tickTask?.cancel()
        tickTask = nil
        remainingSeconds = 0
        mode = .off
        setVolume(1.0)
    }

    func handleVideoEnded() {
        if mode == .endOfVideo {
            cancel()
            onExpire?()
        }
    }

    private func setVolume(_ value: Double) {
        guard abs(value - currentVolume) > 0.001 else { return }
        currentVolume = value
        onVolumeChange?(value)
    }

    private func startTicker(until endDate: Date) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = endDate.timeIntervalSinceNow
                if remaining <= 0 {
                    self.remainingSeconds = 0
                    self.mode = .off
                    self.setVolume(0.0)
                    self.onExpire?()
                    // Restore volume after pausing so the next playback starts at normal loudness
                    self.setVolume(1.0)
                    return
                }
                self.remainingSeconds = remaining
                self.setVolume(Self.fadeVolume(forRemaining: remaining))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
