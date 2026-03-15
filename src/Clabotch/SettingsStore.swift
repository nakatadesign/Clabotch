import Foundation

/// アプリ設定の永続化と型安全なアクセスを提供する。
/// UserDefaults ラッパー。設定変更時は onChange コールバックで通知する。
final class SettingsStore {

    // MARK: - 設定キー

    private enum Keys {
        static let sleepTimeoutMinutes = "clabotch.sleepTimeoutMinutes"
        static let animationSpeedPreset = "clabotch.animationSpeedPreset"
    }

    // MARK: - DI seam

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - コールバック

    /// 設定変更時に発火する。AppDelegate が StateMachine 等へ伝播する。
    var onChange: (() -> Void)?

    // MARK: - スリープタイムアウト

    /// スリープまでの時間（分）。0 = 無効（スリープしない）。
    /// デフォルト: 5分（StateMachine の sleepThreshold=300s と一致）。
    var sleepTimeoutMinutes: Int {
        get {
            let value = defaults.integer(forKey: Keys.sleepTimeoutMinutes)
            // UserDefaults.integer は未設定時に 0 を返す。
            // 0 は「スリープ無効」なので、未設定と区別するためにセンチネルを使用。
            if !defaults.hasValue(forKey: Keys.sleepTimeoutMinutes) {
                return Self.defaultSleepTimeoutMinutes
            }
            return value
        }
        set {
            defaults.set(newValue, forKey: Keys.sleepTimeoutMinutes)
            onChange?()
        }
    }

    /// スリープタイムアウトを秒に変換。0 分 = TimeInterval.infinity（スリープ無効）。
    var sleepTimeoutSeconds: TimeInterval {
        let minutes = sleepTimeoutMinutes
        if minutes <= 0 {
            return .infinity
        }
        return TimeInterval(minutes * 60)
    }

    /// デフォルトのスリープタイムアウト（分）
    static let defaultSleepTimeoutMinutes = 5

    /// スリープタイムアウトの選択肢
    static let sleepTimeoutOptions: [(label: String, minutes: Int)] = [
        ("1分", 1),
        ("5分（デフォルト）", 5),
        ("10分", 10),
        ("無効", 0),
    ]

    // MARK: - アニメーション速度

    /// アニメーション速度のプリセットインデックス。
    /// 0=ゆっくり, 1=標準, 2=速い。デフォルト: 1（標準）。
    var animationSpeedPreset: Int {
        get {
            if !defaults.hasValue(forKey: Keys.animationSpeedPreset) {
                return Self.defaultAnimationSpeedPreset
            }
            let value = defaults.integer(forKey: Keys.animationSpeedPreset)
            // 範囲外チェック
            guard value >= 0, value < Self.animationSpeedOptions.count else {
                return Self.defaultAnimationSpeedPreset
            }
            return value
        }
        set {
            defaults.set(newValue, forKey: Keys.animationSpeedPreset)
            onChange?()
        }
    }

    /// アニメーション間隔の倍率。1.0 が標準。大きいほどゆっくり。
    var animationSpeedMultiplier: Double {
        let options = Self.animationSpeedOptions
        let index = animationSpeedPreset
        guard index >= 0, index < options.count else { return 1.0 }
        return options[index].multiplier
    }

    /// デフォルトのプリセットインデックス（標準）
    static let defaultAnimationSpeedPreset = 1

    /// アニメーション速度の選択肢
    static let animationSpeedOptions: [(label: String, multiplier: Double)] = [
        ("ゆっくり", 1.5),
        ("標準", 1.0),
        ("速い", 0.6),
    ]

    // MARK: - テスト用

    /// 全設定をリセットする。
    func resetForTesting() {
        defaults.removeObject(forKey: Keys.sleepTimeoutMinutes)
        defaults.removeObject(forKey: Keys.animationSpeedPreset)
    }
}

// MARK: - UserDefaults ヘルパー

private extension UserDefaults {
    /// キーに値が設定されているか判定する（integer のゼロと未設定を区別）。
    func hasValue(forKey key: String) -> Bool {
        object(forKey: key) != nil
    }
}
