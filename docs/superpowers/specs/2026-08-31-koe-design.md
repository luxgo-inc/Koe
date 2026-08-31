# Koe — macOS 音声入力アプリ 設計書

日付: 2026-08-31 / 対象: 自分専用（販売・公開なし）

## 目的

superwhisper 代替の常駐音声入力アプリ。日本語入力と AI エージェント（Claude Code 等）への
プロンプト入力に最適化する。無料枠制限なし・完全ローカル動作を基本とする。

## 前提・環境

- macOS 26.3+ / Apple Silicon / Xcode 26.3
- Swift 6 / SwiftUI / メニューバー常駐（`MenuBarExtra`）
- App Store 配布なし。Developer 署名のローカルビルドを `/Applications` に置いて使う
- App Sandbox 無効（アクセシビリティ・CGEventTap が必要なため）

## 操作フロー

- **F9** = 素のままモードで録音開始
- **F10** = AI 整形モードで録音開始（AI 整形が OFF のときは素のままとして動作）
- 両キーとも **タップでトグル**（もう 1 回押すと停止・確定）、**押しっぱなしで PTT**
  （約 0.4 秒以上ホールド後にキーを離すと停止・確定）を自動判別
- **Esc** = 録音キャンセル（何も挿入しない）
- 確定するとアクティブアプリのカーソル位置に自動ペースト
  （クリップボード退避 → テキストセット → Cmd+V 合成 → クリップボード復元）
- 録音中は画面下部に小型フローティング HUD（波形レベル＋認識途中経過＋現在モード表示）

## モード

| モード | 動作 |
|---|---|
| 素のまま (F9) | SpeechAnalyzer の認識結果をそのまま挿入。完全オフライン・待ちゼロ |
| AI 整形 (F10) | 認識結果を Claude API（claude-haiku-4-5）でフィラー除去・句読点整形してから挿入。3 秒タイムアウト or API エラー時は素のままにフォールバックして通知 |

### AI 整形の ON/OFF トグル

- メニューバーと設定画面に「AI 整形を有効にする」トグルを配置。**デフォルト OFF**
- OFF のとき: F10 も素のまま挿入。Claude API には一切アクセスしない
- HUD に現在のモード（素のまま / AI 整形）を常時表示する

### AI 整形プロンプト方針

- フィラー（「えー」「あの」等）除去、句読点・改行の整形
- 内容の要約・言い換え・敬語化はしない。AI エージェントへの指示口調を崩さない
- プロンプト本文は設定画面から編集可能

## コンポーネント分割

| コンポーネント | 責務 | 実装 |
|---|---|---|
| `HotkeyMonitor` | F9/F10/Esc の keyDown/keyUp 監視、タップ/ホールド判別 | CGEventTap |
| `AudioRecorder` | マイク音声のキャプチャ | AVAudioEngine |
| `TranscriptionEngine` (protocol) | 音声→テキスト。将来 whisper.cpp 追加可能な抽象 | — |
| `AppleSpeechEngine` | 日本語オンデバイス認識（partial 結果ストリーミング） | SpeechAnalyzer / SpeechTranscriber |
| `RefinementService` | Claude API 呼び出し（SDK 不使用、URLSession 直） | claude-haiku-4-5 |
| `TextInserter` | クリップボード経由の Cmd+V 合成＋復元 | NSPasteboard + CGEvent |
| `RecordingHUD` | 録音中フローティング表示 | NSPanel + SwiftUI |
| `Settings` | API キー（Keychain）・整形プロンプト・AI整形ON/OFF・ログイン時起動 | SwiftUI + UserDefaults/Keychain |
| `HistoryLogger` | 確定テキストの追記ログ（UI なし） | `~/Library/Application Support/Koe/history.jsonl` |

## 権限・初回セットアップ

- マイク / アクセシビリティ（Cmd+V 合成）/ 入力監視（CGEventTap）
- 初回起動時にセットアップ画面で各権限へ誘導。未許可時はメニューバーから再誘導
- 日本語音声モデルは AssetInventory で初回に自動ダウンロード

## エラー処理

- 権限未許可 → 録音開始せず、メニューバー通知＋設定誘導
- 音声モデル未ダウンロード → HUD にダウンロード進捗を表示
- Claude API 失敗/タイムアウト → 素のまま挿入＋通知
- 挿入先が取れない（アクティブアプリ不明等）→ クリップボードに残して通知

## やらないこと（YAGNI）

- 履歴閲覧 UI（jsonl ログのみ）
- 多言語切替（SpeechAnalyzer 日本語ロケールで日英混在に対応）
- カスタム辞書・アプリ別モード・クラウド STT
- 自動アップデート機構

## テスト方針

- 単体テスト: 整形プロンプト組み立て / 設定の永続化 / タップ・ホールド判別ステートマシン /
  Claude API レスポンスのパース・フォールバック分岐
- 音声・権限・ペーストまわりは手動スモークテスト（チェックリストを README に記載）
