# フェーズ0 スパイク結果

## スパイクA: F9/F10 捕捉（実施日: 未実施）
- Fn なし F9/F10 の捕捉: <未計測>
- イベント消費（ミュート抑止）: <未計測>
- autorepeat フラグ: <未計測>
- 判定: <未計測>

## スパイクB: SpeechAnalyzer（実施日: 未実施）
- API 修正点: なし（Task説明のコード例が macOS 26.2 SDK（Xcode 26.3）の実 API シグネチャと一致しており、コンパイルエラーは発生しなかった）。ただし以下2点を実施:
  1. `main.swift` を `SpikeSpeech.swift` にリネーム。`@main` は `main.swift` という名前のファイルでは使用できないため（トップレベルコード方式との衝突）。
  2. Swift 6 strict concurrency により、`installTap` の `@Sendable` クロージャ内で `AVAudioPCMBuffer`（Sendable 非準拠）を捕捉・返却する箇所、および `var fed` を並行実行コード内で変更する箇所で warning が出るが、error ではなくビルドは成功する。タップコールバックは AVAudioEngine 内部の単一の直列キューから順に呼ばれるため実際には安全と判断し、挙動を変える `nonisolated(unsafe)` ラップ等は行わず warning のまま許容した（`nonisolated(unsafe)` を変数宣言に付けてもガード文・重複宣言でエラーになるケースがあり、必要以上に複雑化するため見送り）。
- 日本語認識品質の所感: <未計測>
- 日英混在（例: 「ClaudeでPR作って」）: <未計測>
- finalize 遅延: <未計測>
- モデルダウンロード所要: <未計測>

## スパイクC: ペースト合成（実施日: 未実施）
- TextEdit: <未計測>
- ターミナル(Claude Code入力欄): <未計測>
- VS Code: <未計測>
- ブラウザ(テキストエリア): <未計測>
- 事前コピーした画像の復元: <未計測>
- 必要だった権限: <未計測>
