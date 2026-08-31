# フェーズ0 スパイク結果

## スパイクA: F9/F10 捕捉（実施日: 2026-08-31）
- Fn なし F9/F10 の捕捉: 可（F9=101/F10=109 とも DOWN/UP 取得）
- イベント消費（ミュート抑止）: 可（副作用の報告なし）
- autorepeat フラグ: 取得可（長押しで repeat=true が連続、UP は repeat=false）
- 判定: F9/F10 をデフォルトホットキーとして採用確定

## スパイクB: SpeechAnalyzer（実施日: 2026-08-31）
- API 修正点: なし（Task説明のコード例が macOS 26.2 SDK（Xcode 26.3）の実 API シグネチャと一致しており、コンパイルエラーは発生しなかった）。ただし以下2点を実施:
  1. `main.swift` を `SpikeSpeech.swift` にリネーム。`@main` は `main.swift` という名前のファイルでは使用できないため（トップレベルコード方式との衝突）。
  2. Swift 6 strict concurrency により、`installTap` の `@Sendable` クロージャ内で `AVAudioPCMBuffer`（Sendable 非準拠）を捕捉・返却する箇所、および `var fed` を並行実行コード内で変更する箇所で warning が出るが、error ではなくビルドは成功する。タップコールバックは AVAudioEngine 内部の単一の直列キューから順に呼ばれるため実際には安全と判断し、挙動を変える `nonisolated(unsafe)` ラップ等は行わず warning のまま許容した（`nonisolated(unsafe)` を変数宣言に付けてもガード文・重複宣言でエラーになるケースがあり、必要以上に複雑化するため見送り）。
- 初回実行: installTap クロージャの MainActor 隔離推論により dispatch_assert_queue_fail でクラッシュ → AudioPipe クラス（@unchecked Sendable）+ @Sendable クロージャで修正。**本番 AudioRecorder / AppleSpeechEngine でも audio コールバックは必ず nonisolated + @Sendable にすること（フェーズ2への必須申し送り）**
- 日本語認識品質の所感: 良好（句読点も自動付与、volatileストリーミング動作）
- 日英混在（例: 「ClaudeでPR作って」）: 弱い。技術用語がカタカナ化される（Firebase→ファイアーベース、ChatGPT→チャット GPT）。一部はラテン文字化（GPT/iOS は成功）→ AI整形プロンプトで英語表記へ戻すルールを追加して対処
- finalize 遅延: 304ms（体感待ちなし。追加UI不要）
- モデルダウンロード所要: 数秒（2回目以降はスキップ）

## スパイクC: ペースト合成（実施日: 2026-08-31）
- TextEdit: 未計測（フォーカス移動が間に合わずターミナルへ貼り付け）
- ターミナル(Claude Code入力欄): 成功（合成Cmd+Vで貼り付け確認）
- VS Code: 未計測
- ブラウザ(テキストエリア): 未計測
- 事前コピーした画像の復元: 復元ロジック動作確認（changeCount一致で復元実施、1アイテム）
- 必要だった権限: post-event access は preflight 時点で許可済み（追加プロンプトなし）
