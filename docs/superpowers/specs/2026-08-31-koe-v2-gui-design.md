# Koe v2 — GUI/UX 強化 設計書

日付: 2026-08-31 / 前提: v1（初期実装）マージ済み・動作確認済み

## 目的

日常使用の快適性を上げる GUI/UX 強化リリース。7 項目:
履歴ビューア / メニューバー UI 強化 / キーキャプチャ UI / HUD リッチ化 /
置換辞書 / プロンプトプリセット / 軽量アップデート機構。

販売はしない（2026-08-31 代表決定）。AI 導入支援の事例として記事・SNS で紹介する。

## 1. 履歴ビューア

- メニューから「履歴…」で専用ウィンドウ（600x480、通常ウィンドウ・複数起動しない）
- 一覧: 日時（相対表示）・モードバッジ・テキスト先頭 2 行。新しい順
- インクリメンタル検索（テキスト部分一致）
- 行操作: クリックで全文表示、コピー ボタン、削除。ツールバーに「全削除」（確認つき）
- **履歴保存のデフォルトを ON に変更**（ビューアの前提。1MB ローテーション・設定トグルは維持）
- KoeCore `HistoryLogger` に読み取り API を追加（TDD）:
  `entries() -> [HistoryEntry]`（jsonl パース、破損行スキップ、ローテーション分 .1 も古い側として読む）、
  `delete(at:)` / `clear()`（書き戻し）

## 2. メニューバー UI 強化

- `MenuBarExtra` を `.menuBarExtraStyle(.window)` のポップオーバーに変更:
  - ヘッダ: 現在モード（素のまま/AI整形）＋ AI 整形トグル
  - プロンプトプリセット切替（Picker、§6）
  - **直近 3 件の書き起こし**（クリックでクリップボードへコピー、コピー済みフィードバック表示）
  - 権限欠落時のみ警告バナー（クリックで権限画面）
  - フッタ: 履歴… / 設定… / 音声モデル再DL / アップデートを確認 / 終了
- 直近 3 件は履歴 OFF のときも表示する（メモリ上のリングバッファ 3 件を RecordingController が保持。
  履歴 OFF = ディスクに残さないだけ、と役割を分離）

## 3. ホットキーのキーキャプチャ UI

- 設定画面のホットキー欄を「クリック → 『キーを押してください…』表示 → 押されたキーを登録」方式に
- 捕捉は `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`（設定ウィンドウがキーのため
  ローカルモニタで足りる。修飾キー単独は対象外・Esc でキャンセル）
- 素のまま／AI 整形に同じキーを登録しようとしたら警告して拒否
- 数値直接入力欄は廃止。現在のキー名を表示（keycode→表示名の簡易マップ、未知コードは "key 101" 形式）

## 4. HUD リッチ化

- レベルメーターを**スクロール波形**に変更: 直近 40 サンプルのレベル履歴をバーで描画、
  右から左へ流れる（`audioLevel` 更新ごとに追記）
- 録音中は赤ドットをパルスアニメーション
- 挿入完了時: HUD を即時 hide せず**チェックマーク＋「挿入しました」を 0.6 秒表示**してからフェードアウト
  （キャンセル時は従来どおり即時 hide）

## 5. 置換辞書（KoeCore・TDD）

- 固定文字列置換ルール `[{from, to}]`。適用順 = 配列順。大文字小文字は区別
- **適用タイミング: 認識確定直後**（AI 整形より前・素のままモードでも適用）
- 保存先: `~/Library/Application Support/Koe/replacements.json`
- KoeCore `ReplacementDictionary`（TDD）: `apply(to:) -> String` / load / save（破損時は空扱い＋通知）
- 設定画面に表エディタ: 追加・削除・上下並び替え・インライン編集

## 6. プロンプトプリセット（KoeCore・TDD）

- `[{id, name, instruction}]`。デフォルトで「AIエージェント用」（現 defaultInstruction）を 1 件生成
- 保存先: `~/Library/Application Support/Koe/prompt-presets.json`。選択中 ID は UserDefaults
- KoeCore `PromptPresetStore`（TDD）: load / save / selected / CRUD。選択中プリセットの instruction を
  RefinementService に渡す（AppSettings.refinementInstruction は廃止し、マイグレーション:
  初回起動時に既存カスタム値があれば「カスタム」プリセットとして取り込む）
- 設定画面: プリセット一覧＋名前変更＋本文編集＋追加・削除。ポップオーバーに切替 Picker（§2）

## 7. 軽量アップデート機構（Sparkle 不採用）

- メニュー「アップデートを確認」→ `~/ghq/github.com/luxgo-inc/Koe` で
  `git fetch origin main` し、ローカル main と origin/main の差分有無を確認
  - 差分なし → 「最新です」通知
  - 差分あり → 確認ダイアログ →「Terminal で更新スクリプトを実行」:
    `scripts/update-app.sh`（git pull → build-app.sh --install。アプリ自身は事前に quit）を
    Terminal.app で開いて実行（アプリが自分自身を差し替える競合を避けるため Terminal 経由）
- リポジトリパスは設定に持たず既定パス固定（無ければ「リポジトリが見つかりません」通知）

## 変更が入る既存コンポーネント

| 対象 | 変更 |
|---|---|
| `HistoryLogger` | 読み取り/削除 API 追加、デフォルト ON |
| `AppSettings` | historyEnabled デフォルト ON / refinementInstruction 廃止（プリセットへ移行）/ selectedPresetID 追加 |
| `RecordingController` | 置換辞書適用・直近3件リングバッファ・プリセット instruction 参照・挿入完了 HUD 演出呼び出し |
| `RefinementService` | instruction を引数で受ける形は既存のまま（呼び出し側がプリセットから渡す） |
| `KoeApp` (MenuContent) | ポップオーバー化 |
| `SettingsView` | キーキャプチャ・置換辞書エディタ・プリセットエディタ、instruction 直編集欄の置き換え |
| `RecordingHUD` | 波形・パルス・完了演出 |

## やらないこと

- Sparkle / クラウド同期 / 多言語 UI / テーマ / 正規表現置換（固定文字列のみ）

## テスト方針

- KoeCore（TDD）: HistoryLogger 読み取り・削除・破損行 / ReplacementDictionary 適用順・空辞書・
  永続化 / PromptPresetStore CRUD・選択・マイグレーション / AppSettings 変更分
- UI・アニメーション・アップデート機構は手動スモークテスト（チェックリストを README に追記）
