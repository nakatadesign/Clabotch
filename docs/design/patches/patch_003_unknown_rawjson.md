# patch_003: ClabotchEvent.unknown の型変更

## 対象

v11 §14.2 `ClabotchEvent.unknown` ケース

## 正典（v11）

```swift
case unknown(raw: [String: Any])
```

## 変更後

```swift
case unknown(rawJSON: String)
```

## 理由

1. `[String: Any]` は `Equatable` に適合しないため、手動 `==` 実装が必要になる
2. JSON キー順序の非決定性により、辞書の等値比較が不安定（テスト脆弱性の原因）
3. `rawJSON: String` なら `Equatable` 自動合成が可能で、テストの `XCTAssertEqual` がそのまま使える
4. unknown イベントの内容を後で再パースする要件はなく、ログ出力・デバッグ用途には String で十分

## 決定経緯

実装計画 003（EventParser / EventDeduplicator）の Codex レビューで承認済み。
計画書の逸脱テーブルへの登録漏れを本 patch で補完。

## 影響範囲

- `ClabotchEvent.swift`: enum ケース定義
- `EventParser.swift`: default ブランチで `String(data:encoding:)` を使用
- `EventParserTests.swift`: `testUnknownEventPreservesRawJSON` で String 比較
