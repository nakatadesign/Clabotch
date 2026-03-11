import Foundation
import os.log

/// ClabotchEvent を受けて MascotPhase を遷移させるステートマシン。
/// main thread 専用。AppDelegate が所有するグローバル 1 インスタンス。
final class StateMachine {

    // MARK: - 公開状態

    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle

    // MARK: - コールバック

    var onPhaseChanged: ((MascotPhase) -> Void)?
    var onEphemeralDone: ((Int) -> Void)?

    // MARK: - レース対策

    private var transitionEpoch: UInt = 0
    private var pendingTransition: DispatchWorkItem?

    // MARK: - Sleep タイマー

    private var sleepTimer: Timer?
    private let sleepThreshold: TimeInterval

    // MARK: - Auto-transition delay

    private let errorAutoTransitionDelay: TimeInterval
    private let doneAutoTransitionDelay: TimeInterval

    // MARK: - DI seams

    private let now: () -> Date

    init(
        sleepThreshold: TimeInterval = 300,
        errorAutoTransitionDelay: TimeInterval = 2.5,
        doneAutoTransitionDelay: TimeInterval = 4.0,
        now: @escaping () -> Date = { Date() }
    ) {
        self.sleepThreshold = sleepThreshold
        self.errorAutoTransitionDelay = errorAutoTransitionDelay
        self.doneAutoTransitionDelay = doneAutoTransitionDelay
        self.now = now
    }

    // MARK: - ライフサイクル

    /// 初期フェーズ同期 + sleep タイマー始動。
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        onPhaseChanged?(displayPhase)
        startSleepTimerIfNeeded()
    }

    // MARK: - イベント処理

    /// ClabotchEvent を受けて phase 遷移を行う。main thread 限定。
    func handle(event: ClabotchEvent) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Step 1: Ownership 判定（副作用ゼロ）
        guard isOwned(event) else {
            handleForeign(event)
            return
        }

        // Step 2: 副作用適用（owned 確定後のみ）
        transitionEpoch &+= 1
        pendingTransition?.cancel()
        pendingTransition = nil
        cancelSleepTimer()

        // Step 3: 状態遷移
        let currentDate = now()
        switch event {
        case .sessionStart(let sessionID):
            session = SessionState(
                sessionID: sessionID,
                phase: .thinking,
                startedAt: currentDate,
                lastEventAt: currentDate
            )
            transition(to: .thinking)

        case .toolStart(_, let toolName):
            session?.lastEventAt = currentDate
            session?.phase = .working(toolName: toolName)
            transition(to: .working(toolName: toolName))

        case .toolEnd(let sessionID, let toolName, _, let isError, let errorMessage):
            session?.lastEventAt = currentDate
            if isError {
                let p = MascotPhase.error(toolName: toolName, message: errorMessage)
                session?.phase = p
                transition(to: p)
                scheduleAutoTransition(to: .thinking, after: errorAutoTransitionDelay,
                                       expectedSessionID: sessionID)
            } else {
                session?.phase = .thinking
                transition(to: .thinking)
            }

        case .sessionDone(_, let elapsedMs):
            session = nil
            transition(to: .done(elapsedMs: elapsedMs))
            scheduleAutoTransition(to: .idle, after: doneAutoTransitionDelay,
                                   expectedSessionID: nil)

        case .unknown:
            break
        }
    }

    // MARK: - Ownership Guard

    private func isOwned(_ event: ClabotchEvent) -> Bool {
        switch event {
        case .sessionStart:
            return session == nil
        case .toolStart(let id, _),
             .toolEnd(let id, _, _, _, _),
             .sessionDone(let id, _):
            return isActiveSession(id)
        case .unknown:
            return false
        }
    }

    private func isActiveSession(_ id: String) -> Bool {
        session?.sessionID == id
    }

    // MARK: - Foreign Event

    private func handleForeign(_ event: ClabotchEvent) {
        switch event {
        case .sessionDone(_, let elapsedMs):
            guard elapsedMs > 0 else { return }
            onEphemeralDone?(elapsedMs)
        case .sessionStart(let id):
            if session?.sessionID == id {
                os_log(.debug, "重複 session_start（no-op）: %{public}@", id)
            } else {
                os_log(.debug, "foreign session_start 無視: %{public}@", id)
            }
        case .toolStart(let id, _):
            os_log(.debug, "foreign tool_start 無視: %{public}@", id)
        case .toolEnd(let id, _, _, _, _):
            os_log(.debug, "foreign tool_end 無視: %{public}@", id)
        case .unknown:
            break
        }
    }

    // MARK: - Phase 遷移

    private func transition(to phase: MascotPhase) {
        guard displayPhase != phase else { return }
        displayPhase = phase

        if case .idle = phase {
            startSleepTimerIfNeeded()
        }

        onPhaseChanged?(phase)
    }

    // MARK: - Auto-transition（遅延遷移）

    private func scheduleAutoTransition(
        to phase: MascotPhase,
        after delay: TimeInterval,
        expectedSessionID: String?
    ) {
        let epoch = transitionEpoch
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.transitionEpoch == epoch else { return }
            guard expectedSessionID == nil
               || self.session?.sessionID == expectedSessionID
            else { return }
            self.transition(to: phase)
        }
        pendingTransition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Sleep タイマー

    private func startSleepTimerIfNeeded() {
        guard session == nil else { return }
        guard case .idle = displayPhase else { return }
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: sleepThreshold, repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            guard self.session == nil else { return }
            self.transition(to: .sleeping)
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }
}
