import Foundation
import os.log

/// ClabotchEvent を受けて MascotPhase を遷移させるステートマシン。
/// main thread 専用。AppDelegate が所有するグローバル 1 インスタンス。
/// v0.3: 複数セッションを並列追跡し、displayPriority で表示フェーズを決定する。
final class StateMachine {

    // MARK: - 公開状態

    /// 全セッションの状態。セッション ID でキー。
    private(set) var sessions: [String: SessionState] = [:]

    /// 表示フェーズ。全セッションの中で最も優先度が高いフェーズ。
    /// セッションが空なら .idle。
    private(set) var displayPhase: MascotPhase = .idle

    /// 後方互換: 最も優先度が高いアクティブセッション（.done を除く）を返す。
    var session: SessionState? {
        sessions.values
            .filter { !$0.phase.isDone }
            .min { $0.phase.displayPriority < $1.phase.displayPriority
                   || ($0.phase.displayPriority == $1.phase.displayPriority
                       && $0.startedAt < $1.startedAt) }
    }

    // MARK: - コールバック

    var onPhaseChanged: ((MascotPhase) -> Void)?
    var onEphemeralDone: ((Int) -> Void)?
    /// セッション数が変化したときに発火する。バブルテキストの [+N] サフィックス更新に使用。
    var onSessionCountChanged: ((Int) -> Void)?

    // MARK: - セッション数追跡

    private var lastNotifiedSessionCount: Int = 0

    // MARK: - レース対策（セッション単位）

    private var sessionEpochs: [String: UInt] = [:]
    private var pendingTransitions: [String: DispatchWorkItem] = [:]

    // MARK: - Sleep タイマー

    private var sleepTimer: Timer?
    private(set) var sleepThreshold: TimeInterval

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
    /// 全セッションのイベントを受理する（ownership guard 廃止）。
    func handle(event: ClabotchEvent) {
        dispatchPrecondition(condition: .onQueue(.main))

        let currentDate = now()

        switch event {
        case .sessionStart(let sessionID):
            // 重複 session_start は no-op（§14.3 不変条件 4）
            guard sessions[sessionID] == nil else { return }
            cancelSleepTimer()
            sessions[sessionID] = SessionState(
                sessionID: sessionID,
                phase: .thinking,
                startedAt: currentDate,
                lastEventAt: currentDate
            )
            sessionEpochs[sessionID] = 0
            recalculateDisplayPhase()

        case .toolStart(let sessionID, let toolName):
            guard let s = sessions[sessionID], !s.phase.isDone else { return }
            bumpEpoch(for: sessionID)
            sessions[sessionID]?.lastEventAt = currentDate
            sessions[sessionID]?.phase = .working(toolName: toolName)
            recalculateDisplayPhase()

        case .toolEnd(let sessionID, let toolName, _, let isError, let errorMessage):
            guard let s = sessions[sessionID], !s.phase.isDone else { return }
            bumpEpoch(for: sessionID)
            sessions[sessionID]?.lastEventAt = currentDate
            if isError {
                let p = MascotPhase.error(toolName: toolName, message: errorMessage)
                sessions[sessionID]?.phase = p
                recalculateDisplayPhase()
                scheduleAutoTransition(
                    for: sessionID, toPhase: .thinking,
                    after: errorAutoTransitionDelay
                )
            } else {
                sessions[sessionID]?.phase = .thinking
                recalculateDisplayPhase()
            }

        case .sessionDone(let sessionID, let hookElapsedMs):
            // 未追跡セッション: ephemeral 通知のみ
            guard let session = sessions[sessionID] else {
                if hookElapsedMs > 0 {
                    onEphemeralDone?(hookElapsedMs)
                }
                return
            }

            // Hook が elapsed_ms を提供しなかった場合（ツール未使用セッション等）、
            // app が記録した startedAt からフォールバック計算する。
            let elapsedMs: Int
            if hookElapsedMs > 0 {
                elapsedMs = hookElapsedMs
            } else {
                let computedMs = Int(currentDate.timeIntervalSince(session.startedAt) * 1000)
                elapsedMs = max(0, computedMs)
            }

            bumpEpoch(for: sessionID)
            sessions[sessionID]?.lastEventAt = currentDate
            sessions[sessionID]?.phase = .done(elapsedMs: elapsedMs)
            recalculateDisplayPhase()
            scheduleSessionRemoval(for: sessionID, after: doneAutoTransitionDelay)

            // 非プライマリセッションの完了: ephemeral 通知
            // displayPhase が .done でない場合、より高優先のセッションが表示中なので
            // ephemeral bubble でユーザーに通知する
            if !displayPhase.isDone, elapsedMs > 0 {
                onEphemeralDone?(elapsedMs)
            }

        case .unknown:
            break
        }
    }

    // MARK: - セッション epoch 管理

    private func bumpEpoch(for sessionID: String) {
        cancelPendingTransition(for: sessionID)
        sessionEpochs[sessionID, default: 0] &+= 1
    }

    private func cancelPendingTransition(for sessionID: String) {
        pendingTransitions[sessionID]?.cancel()
        pendingTransitions.removeValue(forKey: sessionID)
    }

    // MARK: - Auto-transition（遅延遷移、セッション単位）

    private func scheduleAutoTransition(
        for sessionID: String,
        toPhase phase: MascotPhase,
        after delay: TimeInterval
    ) {
        let epoch = sessionEpochs[sessionID] ?? 0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.sessionEpochs[sessionID] == epoch else { return }
            self.sessions[sessionID]?.phase = phase
            self.pendingTransitions.removeValue(forKey: sessionID)
            self.recalculateDisplayPhase()
        }
        pendingTransitions[sessionID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// session_done 後の遅延セッション削除。
    private func scheduleSessionRemoval(for sessionID: String, after delay: TimeInterval) {
        let epoch = sessionEpochs[sessionID] ?? 0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.sessionEpochs[sessionID] == epoch else { return }
            guard self.sessions[sessionID] != nil else { return }
            self.sessions.removeValue(forKey: sessionID)
            self.sessionEpochs.removeValue(forKey: sessionID)
            self.pendingTransitions.removeValue(forKey: sessionID)
            self.recalculateDisplayPhase()
        }
        pendingTransitions[sessionID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - displayPhase 再計算

    /// sessions から displayPhase を再計算し、変化があれば onPhaseChanged を発火する。
    /// 同一 displayPriority のセッションが複数ある場合は startedAt が早い方を選択する（決定的）。
    /// セッション数が変化した場合は onSessionCountChanged を発火する。
    private func recalculateDisplayPhase() {
        let primary = sessions.values.min { a, b in
            if a.phase.displayPriority != b.phase.displayPriority {
                return a.phase.displayPriority < b.phase.displayPriority
            }
            return a.startedAt < b.startedAt
        }
        updateDisplayPhase(to: primary?.phase ?? .idle)
        notifySessionCountIfNeeded()
    }

    /// セッション数が前回通知時と異なる場合に onSessionCountChanged を発火する。
    private func notifySessionCountIfNeeded() {
        let count = sessions.count
        guard count != lastNotifiedSessionCount else { return }
        lastNotifiedSessionCount = count
        onSessionCountChanged?(count)
    }

    /// displayPhase を直接更新する。sleep タイマー管理 + コールバック発火。
    private func updateDisplayPhase(to newPhase: MascotPhase) {
        guard displayPhase != newPhase else { return }
        displayPhase = newPhase

        if case .idle = newPhase, sessions.isEmpty {
            startSleepTimerIfNeeded()
        }

        onPhaseChanged?(newPhase)
    }

    // MARK: - Sleep タイマー

    private func startSleepTimerIfNeeded() {
        guard sessions.isEmpty else { return }
        guard case .idle = displayPhase else { return }
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: sleepThreshold, repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            guard self.sessions.isEmpty else { return }
            self.updateDisplayPhase(to: .sleeping)
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    // MARK: - 設定変更

    /// スリープタイムアウトを動的に変更する。
    /// .infinity を指定するとスリープ無効。変更後、必要なら sleep タイマーを再スケジュールする。
    func updateSleepThreshold(_ newThreshold: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        sleepThreshold = newThreshold
        cancelSleepTimer()
        if newThreshold.isFinite {
            startSleepTimerIfNeeded()
        }
    }
}

// MARK: - MascotPhase ヘルパー

extension MascotPhase {
    /// .done かどうかを判定する。
    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}
