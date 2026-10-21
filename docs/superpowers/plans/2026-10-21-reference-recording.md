# 参考音声の録音モード（F11）実装計画 — 2026-10-21

## 目的

YouTube 動画（Game-Making-History-Videos）のナレーションは ElevenLabs TTS。抑揚が不自然な文は、自分で正しいイントネーションで 1 文読み、ElevenLabs Speech-to-Speech でナレーター声に変換して差し替える。その「1 文を録って、高音質ファイルとして渡す」道具を Koe に持たせる。

## 設計判断

- **RecordingController に `.reference` モードとして同居させる**（会議録音のような独立コントローラにしない）。`RecordingStateMachine` が F9/F10/F11 を排他するので、録音の競合を自動で防げる。タップトグル・押しっぱなし PTT・Esc は raw と同じ遷移。
- **音声認識と並行して `ReferenceAudioWriter` が書く**。`AudioRecorder` のタップは常にハードウェアレートの Float32 なので、リサンプリング無しで保存できる。サンプルレートは最初に届いたバッファから決める（キープアライブ中は start() 直後にバッファが来るため、事前にフォーマットを渡す設計だと取りこぼす）。
- **24bit 固定・モノラル（複数 ch は平均）**。ElevenLabs STS 入力として十分で、設定項目を増やさない。
- **無音トリムはブロックピーク方式**。10ms ごとのピークだけメモリに持ち、閾値 -40 dBFS、前後 0.3 秒残す。全無音なら切らない。本体は一時ファイル → 1MB ずつ WAV へコピー。
- **書き起こしは失敗・空でも WAV を残す**。15 秒で打ち切り。認識セッションの開始失敗でも録音は続ける（通常モードは `.failure` でキャンセルするところを分岐）。
- **録音中のデバイス切替はそこまでで保存**（レートが変わり得るので 1 ファイルにつながない）。
- **置換辞書・AI整形・履歴・直近 3 件には一切触れない**。挿入するのは WAV の絶対パス。

## 変更ファイル

| 層 | ファイル | 内容 |
|---|---|---|
| KoeCore | `ReferenceRecordingNaming.swift` | `yyyyMMdd-HHmmss-<先頭12字>` と禁止文字除去・衝突連番 |
| KoeCore | `SilenceTrimmer.swift` | ブロックピーク配列 → 残すフレーム範囲 |
| KoeCore | `ReferenceSidecar.swift` | サイドカー JSON（snake_case、日本語非エスケープ） |
| KoeCore | `WAVHeader.swift` | 44 バイト PCM ヘッダ |
| KoeCore | `AppSettings.swift` | `referenceHotkeyCode`(103) / `referenceRecordingsDirectory` / `referenceTrimSilence` / `referenceDelivery` / `lastReferenceRecordingPath` |
| KoeCore | `RecordingStateMachine.swift` | `RecordingMode.reference` |
| KoeKit | `ReferenceAudioWriter.swift` | 専用キューで Float32→Int24、ピーク記録、finish で trim+WAV |
| KoeApp | `HotkeyMonitor.swift` | `referenceKeyCode` |
| KoeApp | `RecordingController.swift` | 開始/停止/キャンセル/挿入/デバイス変更の 5 箇所を分岐、`lastReferenceRecording` |
| KoeApp | `RecordingHUD.swift` | 青ドット・「参考音声を録音中」「保存中…」 |
| KoeApp | `SettingsView.swift` | キーキャプチャ 3 本目、参考音声セクション |
| KoeApp | `KoeApp.swift` | 「直前の参考音声」行（再生・Finder・削除） |
| Tests | `KoeCoreTests/ReferenceRecordingTests.swift`、`KoeKitTests/ReferenceAudioWriterTests.swift` | 純粋ロジックと合成音での WAV 検証 |

## 検証

1. `swift test`（KoeCore + KoeKit。合成音で 48kHz/24bit/モノラル、前後 0.3 秒を確認）
2. `bash scripts/build-app.sh --install` → README「参考音声スモークテスト」
