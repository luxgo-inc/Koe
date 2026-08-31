# Koe — macOS 音声入力アプリ 設計書

日付: 2026-08-31（Codexレビュー反映済み改訂版） / 対象: 自分専用（販売・公開なし）

## 目的

superwhisper 代替の常駐音声入力アプリ。日本語入力と AI エージェント（Claude Code 等）への
プロンプト入力に最適化する。無料枠制限なし・音声はローカル処理を基本とする
（AI 整形モード使用時のみ認識テキストが Claude API に送信される。UI 上で明示する）。

## 前提・環境

- macOS 26.3+ / Apple Silicon / Xcode 26.3
- Swift 6 / SwiftUI / メニューバー常駐（`MenuBarExtra`）
- App Store 配布なし。Developer 署名のローカルビルドを `/Applications/Koe.app` に固定配置
  （署名・bundle ID・配置パスが変わると TCC 許可が外れるため、署名と配置は固定運用）
- App Sandbox 無効（アクセシビリティ・CGEventTap が必要なため）

## 操作フロー

- **F9** = 素のままモードで録音開始 / **F10** = AI 整形モードで録音開始
- ⚠️ F9/F10 は Apple キーボード標準設定ではメディアキー。**実装フェーズ 0 のスパイクで
  CGEventTap がメディアキー設定のまま F9/F10 を捕捉できるか実機検証**し、不可なら
  設定画面のホットキー変更（任意キー・修飾キー組合せ）で回避する。ホットキーは設定変更可能
- Event Tap は **active tap**（イベントを消費し、他アプリへ F9/F10 を流さない）
- 両キーとも **タップでトグル**、**押しっぱなし（0.4 秒以上）で PTT** を自動判別。
  key repeat は無視。録音中の反対キー押下は現在の録音を確定してからモード切替はしない（無視）
- **Esc** = 録音キャンセル（Esc はアプリ側で消費し、挿入なし）
- 確定するとアクティブアプリのカーソル位置に自動ペースト。**挿入先は録音開始時点の
  フロントアプリ**を記録し、確定時にそのアプリへ挿入（変わっていたら現フロントに挿入し通知）
- 録音中は画面下部に小型フローティング HUD（nonactivating NSPanel、フォーカスを奪わない。
  波形レベル＋認識途中経過＋現在モード表示）

## モード

| モード | 動作 |
|---|---|
| 素のまま (F9) | SpeechAnalyzer の認識結果をそのまま挿入。オフライン動作 |
| AI 整形 (F10) | 認識結果を Claude API（モデル ID 固定: `claude-haiku-4-5-20251001`、設定で変更可）でフィラー除去・句読点整形してから挿入 |

### AI 整形の ON/OFF トグル

- メニューバーと設定画面に「AI 整形を有効にする」トグルを配置。**デフォルト OFF**
- OFF・API キー未設定のとき: F10 も素のまま挿入。Claude API には一切アクセスしない
  （API キー未設定で F10 を押した場合、初回のみ「素のままで挿入します」と通知）
- HUD に現在のモード（素のまま / AI 整形）を常時表示する

### AI 整形の仕様

- フィラー（「えー」「あの」等）除去、句読点・改行の整形。カタカナ化された技術用語の英語表記復元（例: ファイアーベース→Firebase。スパイクBで確認された認識弱点への対処）。内容の要約・言い換えはしない。
  AI エージェントへの指示口調を崩さない。プロンプト本文は設定画面から編集可能
- 原文はプロンプト内で区切り記号で明確にデータとして区切る
- **wall-clock 3 秒タイムアウト**（接続〜応答全体）。超過時は Task をキャンセルし原文へフォールバック
- 異常系はすべて原文フォールバック＋通知: HTTP エラー / 空出力 / max_tokens 到達 /
  出力長が原文の 3 倍超 or 3 分の 1 未満（大幅改変とみなす）

## 録音ステートマシン

単一の actor `RecordingController` が全状態を管理する:

```
idle → preparing → recording(mode, gesture) → finalizing → [refining] → inserting → idle
                                            ↘ cancelled → idle        ↘ failed → idle
```

- 各録音に **セッション ID** を付与し、旧セッションの遅延認識結果を破棄する
- `finalizing` 以降のホットキー押下は無視（連打対策）
- 無音・空結果は何も挿入せず HUD を静かに閉じる
- 最大録音時間 5 分で自動確定
- マイク切断・入力デバイス変更時は録音をキャンセルして通知
- AI 整形中（refining）の Esc は整形をキャンセルし原文を挿入

## コンポーネント分割

| コンポーネント | 責務 | 実装 |
|---|---|---|
| `HotkeyMonitor` | ホットキー/Esc の捕捉。コールバック内では判定のみ行い即 return（`.tapDisabledByTimeout` 対策）、処理は actor へ転送。tap 無効化イベント・スリープ復帰・デバイス変更時に tap を再生成 | CGEventTap (active) |
| `RecordingController` | 上記ステートマシン | actor |
| `AudioRecorder` | マイク音声のキャプチャ | AVAudioEngine |
| `TranscriptionEngine` (protocol) | 音声→テキスト。将来 whisper.cpp 追加可能な抽象 | — |
| `AppleSpeechEngine` | 日本語オンデバイス認識。`bestAvailableAudioFormat` へのフォーマット変換、volatile 結果の**置換ベース統合**（追記しない）、停止時は入力 sequence を finish し `finalizeAndFinishThroughEndOfInput()` を await してから確定文を取得。起動時に `prepareToAnalyze` で予熱 | SpeechAnalyzer / SpeechTranscriber |
| `RefinementService` | Claude API 呼び出し（SDK 不使用、URLSession 直） | claude-haiku-4-5-20251001 |
| `TextInserter` | ペースト合成とクリップボード退避・復元（下記） | NSPasteboard + CGEvent |
| `RecordingHUD` | 録音中フローティング表示（nonactivating） | NSPanel + SwiftUI |
| `Settings` | ホットキー変更・API キー（Keychain）・整形プロンプト・AI整形ON/OFF・履歴ON/OFF・ログイン時起動 | SwiftUI + UserDefaults/Keychain |
| `HistoryLogger` | 確定テキストの追記ログ。**デフォルト OFF**（プロンプトに秘密情報が入り得るため）。上限 1MB でローテーション | `~/Library/Application Support/Koe/history.jsonl` |

### クリップボード退避・復元の仕様

1. 退避: `NSPasteboardItem` の**全アイテム・全 type を丸ごと保存**（文字列だけにしない）
2. 退避時の `changeCount` を記録
3. テキストをセットし Cmd+V を CGEvent で合成
4. 0.6 秒待ってから復元。ただし**復元直前の `changeCount` が自分のセット以降に他者によって
   変わっていた場合は復元しない**（ユーザーのコピー操作を破壊しない）
5. 遅延提供（promised data）は退避不能なため、その場合は復元を諦め認識文をクリップボードに残す

## 権限・初回セットアップ

- マイク（`NSMicrophoneUsageDescription`）/ 音声認識（`NSSpeechRecognitionUsageDescription`）/
  アクセシビリティ / 入力監視
- 判定はそれぞれ専用 API で行う: `CGPreflightListenEventAccess` / `CGPreflightPostEventAccess` /
  `AXIsProcessTrusted` ＋ Event Tap 生成の成否
- 初回起動時にセットアップ画面で各権限へ誘導。**権限付与後は tap を再生成**し、それでも
  失敗する場合はアプリ再起動を案内
- 日本語音声モデル: 起動時に `SpeechTranscriber` の対応 locale を実機判定し、未ダウンロード
  なら AssetInventory でダウンロード（HUD に進捗表示）。失敗時は通知＋メニューから再試行

## エラー処理

- 権限未許可 → 録音開始せず、通知＋設定誘導
- Claude API 失敗/タイムアウト/異常出力 → 原文挿入＋通知
- 挿入先が取れない・ペースト失敗の疑い → クリップボードに認識文を残して通知

## やらないこと（YAGNI）

- 履歴閲覧 UI（jsonl ログのみ、デフォルト OFF）
- 多言語切替（日本語 locale 固定。日英混在の精度はフェーズ 0 で実測評価）
- カスタム辞書・アプリ別モード・クラウド STT・自動アップデート
- secure input 検出・パスワード欄除外（パスワード欄では使わない運用でカバー）
- メディアキー（systemDefined イベント）レイヤーの捕捉実装（スパイクで必要と判明した場合のみ）

## 実装順序（Codex レビュー反映）

基盤制約を先に実機検証してから積み上げる:

1. **フェーズ 0（スパイク）**: (a) CGEventTap で F9/F10 捕捉可否＋権限フロー、
   (b) SpeechAnalyzer の日本語認識・日英混在精度・finalize 遅延を録音 fixture で測定、
   (c) TextEdit / Terminal / VS Code / ブラウザでペースト合成の成否検証
2. スパイク結果でホットキー方式・クリップボード復元方針を確定（必要ならスペック改訂）
3. RecordingController（ステートマシン）＋ AudioRecorder ＋ AppleSpeechEngine
4. TextInserter ＋ HUD
5. Settings ＋ 権限セットアップ画面
6. RefinementService（AI 整形）＋ HistoryLogger

## テスト方針

- 単体テスト: ステートマシン遷移（タップ/ホールド判別・連打・キャンセル・セッション ID 破棄）/
  整形プロンプト組み立て / Claude API レスポンスのパース・フォールバック分岐 /
  クリップボード復元判定（changeCount ロジック）/ 設定の永続化
- 音声・権限・ペーストまわりは手動スモークテスト（チェックリストを README に記載）
