# 会議録音・文字起こしモード 実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Google Meet / Zoom 等の会議音声（自分=マイク＋相手=システム音声）を Koe でローカル録音・オンデバイス文字起こしし、話者別タイムスタンプ付き Markdown 議事録＋AI要約を自動保存する。

**Architecture:** Core Audio プロセスタップ（`AudioHardwareCreateProcessTap`, macOS 14.2+）でシステム再生音声を取得し、既存の `AppleSpeechEngine` を2インスタンス（マイク用/システム音声用）並走させる。各エンジンの確定セグメントを `MeetingTranscriptBuilder`（KoeCore・純ロジック）が時刻順にマージし、停止時に `MeetingStore` が Markdown 保存。AI整形ONなら `RefinementService` 流用で要約を先頭に付与。

**Tech Stack:** Swift 6 / SwiftPM / AudioToolbox（プロセスタップ）/ AVFoundation / Speech（SpeechAnalyzer）/ SwiftUI MenuBarExtra

**方針メモ:**
- 話者分離は「自分（マイク）/ 相手（システム音声）」の2値。相手側の複数話者分離はしない（YAGNI）
- 保存先は `~/Library/Application Support/Koe/meetings/`（TCC不要）。保存後 Finder で自動表示
- 既存の F9/F10 音声入力とは独立動作（エンジン・レコーダーは別インスタンス）
- 安全弁として3時間で自動停止

---

## File Structure

| ファイル | 責務 |
|---|---|
| `Spikes/SpikeSystemAudio/SpikeSystemAudio.swift` | 新規: プロセスタップ検証スパイク |
| `Sources/KoeCore/MeetingTranscript.swift` | 新規: セグメント蓄積とMarkdown描画（純ロジック・TDD） |
| `Sources/KoeCore/MeetingStore.swift` | 新規: 議事録ファイルの命名・保存（TDD） |
| `Sources/KoeCore/MeetingSummaryPrompt.swift` | 新規: 要約用システムプロンプト定数 |
| `Sources/KoeApp/TranscriptionEngine.swift` | 変更: `TranscriptUpdate` に `finalizedSegment` 追加 |
| `Sources/KoeApp/AppleSpeechEngine.swift` | 変更: isFinal 時に finalizedSegment を yield |
| `Sources/KoeApp/SystemAudioCapture.swift` | 新規: プロセスタップ→AVAudioPCMBuffer |
| `Sources/KoeApp/MeetingRecorder.swift` | 新規: 会議モードのオーケストレーター |
| `Sources/KoeApp/KoeApp.swift` | 変更: ポップオーバーに会議録音UI追加 |
| `Resources/Info.plist` | 変更: `NSAudioCaptureUsageDescription` 追加 |
| `Package.swift` | 変更: SpikeSystemAudio ターゲット追加 |

---

### Task 0: ブランチ作成

- [ ] **Step 1: feature ブランチを切る**

```bash
cd ~/ghq/github.com/luxgo-inc/Koe
git checkout -b feature/meeting-recorder
```

---

### Task 1: スパイクD — システム音声プロセスタップ検証

**目的:** `AudioHardwareCreateProcessTap` → 集約デバイス → IOProc でシステム再生音声の PCM バッファが取れることを、本実装前に単体で確認する。ここが本機能唯一の技術リスク。

**Files:**
- Create: `Spikes/SpikeSystemAudio/SpikeSystemAudio.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Package.swift にターゲット追加**

`.executableTarget(name: "SpikePaste", ...)` の行の後に追加:

```swift
.executableTarget(name: "SpikeSystemAudio", path: "Spikes/SpikeSystemAudio"),
```

- [ ] **Step 2: スパイク本体を書く**

`Spikes/SpikeSystemAudio/SpikeSystemAudio.swift`:

```swift
import AudioToolbox
import AVFoundation
import Foundation

// スパイクD: システム音声のプロセスタップ検証。
// 全プロセスのシステム出力をタップ→集約デバイス経由でIOProcに受け、
// 10秒間 1秒ごとに RMS レベルを表示する。音楽を再生しながら実行し、
// レベルが 0 以外で動くことを確認する。
// 注意: TCC「システム音声録音」プロンプトはターミナル（実行元）に対して出る。

@main
struct SpikeSystemAudio {
    static func main() throws {
        // 1. 全プロセス対象のタップを作成（除外リスト空 = 全部）
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "SpikeTap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { fatalError("tap creation failed: \(status)") }
        print("tap created: \(tapID)")

        // 2. タップのフォーマット取得
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            fatalError("format read failed: \(status)")
        }
        print("format: \(format)")

        // 3. タップを含む private 集約デバイスを作成
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpikeAgg",
            kAudioAggregateDeviceUIDKey: "jp.luxgo.koe.spike-agg",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard status == noErr else { fatalError("aggregate creation failed: \(status)") }
        print("aggregate created: \(aggID)")

        // 4. IOProc で受信、RMS を表示
        nonisolated(unsafe) var latestRMS: Float = 0
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inInputData, _, _, _ in
            let ablPointer = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let buf = ablPointer.first, let data = buf.mData else { return }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard n > 0 else { return }
            let samples = data.bindMemory(to: Float.self, capacity: n)
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            latestRMS = (sum / Float(n)).squareRoot()
        }
        guard status == noErr else { fatalError("ioproc failed: \(status)") }
        status = AudioDeviceStart(aggID, procID)
        guard status == noErr else { fatalError("start failed: \(status)") }

        print("capturing 10s... 音楽やYouTubeを再生してください")
        for i in 1...10 {
            Thread.sleep(forTimeInterval: 1)
            print("t=\(i)s rms=\(latestRMS)")
        }

        AudioDeviceStop(aggID, procID)
        if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
        AudioHardwareDestroyAggregateDevice(aggID)
        AudioHardwareDestroyProcessTap(tapID)
        print("done")
    }
}
```

- [ ] **Step 3: 実行して検証**

Run: 何か音（YouTube等）を再生した状態で `swift run SpikeSystemAudio`
Expected: TCC プロンプト（初回）→ 許可後、`rms=` が 0 以外の値で変動する
（TCCプロンプトが出ない/常に rms=0 の場合はここで止めて原因調査。API シグネチャ違いはこのファイル内で修正して再検証）

- [ ] **Step 4: 結果を docs/spike-results.md に「スパイクD」として追記しコミット**

```bash
git add Package.swift Spikes/SpikeSystemAudio docs/spike-results.md
git commit -m "スパイクD: システム音声プロセスタップの検証（会議録音モード用）"
```

---

### Task 2: MeetingTranscriptBuilder（KoeCore・TDD）

**Files:**
- Create: `Sources/KoeCore/MeetingTranscript.swift`
- Test: `Tests/KoeCoreTests/MeetingTranscriptTests.swift`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/KoeCoreTests/MeetingTranscriptTests.swift`:

```swift
import Testing
@testable import KoeCore

@Suite struct MeetingTranscriptTests {
    @Test func 空のビルダーはisEmpty() {
        let b = MeetingTranscriptBuilder()
        #expect(b.isEmpty)
    }

    @Test func セグメントを時刻順にマージしてMarkdown描画する() {
        var b = MeetingTranscriptBuilder()
        b.add(speaker: "自分", seconds: 65, text: "こんにちは")
        b.add(speaker: "相手", seconds: 3, text: "本日はよろしくお願いします")
        let md = b.renderMarkdown(title: "テスト会議")
        #expect(md == """
        # テスト会議

        - [00:03] **相手**: 本日はよろしくお願いします
        - [01:05] **自分**: こんにちは

        """)
    }

    @Test func 空白のみのテキストは無視する() {
        var b = MeetingTranscriptBuilder()
        b.add(speaker: "自分", seconds: 0, text: "  \n ")
        #expect(b.isEmpty)
    }

    @Test func 同時刻セグメントは追加順を保つ() {
        var b = MeetingTranscriptBuilder()
        b.add(speaker: "自分", seconds: 5, text: "A")
        b.add(speaker: "相手", seconds: 5, text: "B")
        let md = b.renderMarkdown(title: "t")
        #expect(md.range(of: "A")!.lowerBound < md.range(of: "B")!.lowerBound)
    }

    @Test func 一時間超はhmmss表記() {
        #expect(MeetingTranscriptBuilder.timestamp(3725) == "1:02:05")
        #expect(MeetingTranscriptBuilder.timestamp(59) == "00:59")
    }

    @Test func 全文テキストは話者名なしで結合する() {
        var b = MeetingTranscriptBuilder()
        b.add(speaker: "自分", seconds: 10, text: "後半")
        b.add(speaker: "相手", seconds: 2, text: "前半")
        #expect(b.plainText() == "相手: 前半\n自分: 後半")
    }
}
```

- [ ] **Step 2: 失敗を確認**

Run: `swift test --filter MeetingTranscriptTests`
Expected: コンパイルエラー（MeetingTranscriptBuilder 未定義）

- [ ] **Step 3: 実装**

`Sources/KoeCore/MeetingTranscript.swift`:

```swift
import Foundation

public struct MeetingSegment: Equatable, Sendable {
    public let speaker: String
    public let seconds: TimeInterval
    public let text: String
}

/// 会議中に確定した発話セグメントを蓄積し、時刻順の Markdown 議事録に描画する。
/// マイク系統とシステム音声系統の finalize 到着順は前後し得るため、描画時に
/// seconds でソートする（同時刻は追加順を保持）。
public struct MeetingTranscriptBuilder: Sendable {
    private var segments: [MeetingSegment] = []

    public init() {}

    public var isEmpty: Bool { segments.isEmpty }

    public mutating func add(speaker: String, seconds: TimeInterval, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(MeetingSegment(speaker: speaker, seconds: seconds, text: trimmed))
    }

    private var sorted: [MeetingSegment] {
        segments.enumerated()
            .sorted { ($0.element.seconds, $0.offset) < ($1.element.seconds, $1.offset) }
            .map(\.element)
    }

    public func renderMarkdown(title: String) -> String {
        var lines = ["# \(title)", ""]
        for seg in sorted {
            lines.append("- [\(Self.timestamp(seg.seconds))] **\(seg.speaker)**: \(seg.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// AI要約に渡す用のプレーンテキスト。
    public func plainText() -> String {
        sorted.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `swift test --filter MeetingTranscriptTests`
Expected: 6 tests pass

- [ ] **Step 5: コミット**

```bash
git add Sources/KoeCore/MeetingTranscript.swift Tests/KoeCoreTests/MeetingTranscriptTests.swift
git commit -m "会議議事録ビルダー: 2系統の確定セグメントを時刻順Markdownにマージ"
```

---

### Task 3: MeetingStore（KoeCore・TDD）

**Files:**
- Create: `Sources/KoeCore/MeetingStore.swift`
- Test: `Tests/KoeCoreTests/MeetingStoreTests.swift`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/KoeCoreTests/MeetingStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import KoeCore

@Suite struct MeetingStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)")
    }

    @Test func ファイル名は日時ベース() {
        let store = MeetingStore(directory: URL(fileURLWithPath: "/tmp/x"))
        var comps = DateComponents(year: 2026, month: 9, day: 1, hour: 14, minute: 30)
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let url = store.fileURL(for: comps.date!, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(url.lastPathComponent == "2026-09-01-1430-meeting.md")
    }

    @Test func saveはディレクトリを作成して書き込みURLを返す() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(directory: dir)
        let url = try store.save(markdown: "# 会議\n", date: Date())
        #expect(try String(contentsOf: url, encoding: .utf8) == "# 会議\n")
    }
}
```

- [ ] **Step 2: 失敗を確認**

Run: `swift test --filter MeetingStoreTests`
Expected: コンパイルエラー（MeetingStore 未定義）

- [ ] **Step 3: 実装**

`Sources/KoeCore/MeetingStore.swift`:

```swift
import Foundation

/// 議事録 Markdown のファイル保存。保存先ディレクトリは呼び出し側が注入する
/// （本番: Application Support/Koe/meetings）。
public struct MeetingStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(for date: Date, timeZone: TimeZone = .current) -> URL {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return directory.appendingPathComponent("\(fmt.string(from: date))-meeting.md")
    }

    @discardableResult
    public func save(markdown: String, date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: date)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `swift test --filter MeetingStoreTests`
Expected: 2 tests pass

- [ ] **Step 5: コミット**

```bash
git add Sources/KoeCore/MeetingStore.swift Tests/KoeCoreTests/MeetingStoreTests.swift
git commit -m "MeetingStore: 議事録Markdownの日時ベース命名と保存"
```

---

### Task 4: 要約プロンプト定数（KoeCore）

**Files:**
- Create: `Sources/KoeCore/MeetingSummaryPrompt.swift`

- [ ] **Step 1: 実装（定数のみ・テスト不要）**

```swift
import Foundation

public enum MeetingSummaryPrompt {
    /// RefinementService に渡す会議要約用システムプロンプト。
    /// 入力は「話者: 発話」形式のプレーンテキスト議事録。
    public static let instruction = """
    あなたは会議議事録の要約器です。渡された「話者: 発話」形式の書き起こしを読み、\
    次の構成の Markdown だけを出力してください。該当がないセクションは省略します。
    ## 決定事項
    ## TODO（担当があれば明記）
    ## 論点・持ち越し
    ## その他要点
    - 書き起こしの誤認識と思われる箇所は文脈から自然に補って構いません
    - 挨拶や前置きは出力しない
    """
}
```

- [ ] **Step 2: ビルド確認とコミット**

Run: `swift build`
Expected: success

```bash
git add Sources/KoeCore/MeetingSummaryPrompt.swift
git commit -m "会議要約用システムプロンプト定数を追加"
```

---

### Task 5: TranscriptUpdate に確定セグメントを追加

**Files:**
- Modify: `Sources/KoeApp/TranscriptionEngine.swift`
- Modify: `Sources/KoeApp/AppleSpeechEngine.swift`（results 購読ループ）

- [ ] **Step 1: TranscriptUpdate 拡張**

`TranscriptionEngine.swift` の struct を置き換え:

```swift
struct TranscriptUpdate: Sendable {
    /// 確定済みテキスト＋現在の volatile 部分を結合した「現時点の全文」
    let displayText: String
    /// この更新で新たに確定したセグメント（volatile 更新時は nil）。
    /// 会議モードが話者別タイムスタンプ付き議事録を組み立てるために使う。
    let finalizedSegment: String?

    init(displayText: String, finalizedSegment: String? = nil) {
        self.displayText = displayText
        self.finalizedSegment = finalizedSegment
    }
}
```

- [ ] **Step 2: AppleSpeechEngine の isFinal 分岐で yield**

`AppleSpeechEngine.swift` の results 購読ループ内、

```swift
                    if result.isFinal {
                        finalized += text
                        updateCont.yield(TranscriptUpdate(displayText: finalized))
```

を次に変更:

```swift
                    if result.isFinal {
                        finalized += text
                        updateCont.yield(TranscriptUpdate(displayText: finalized, finalizedSegment: text))
```

- [ ] **Step 3: ビルド・全テスト・コミット**

Run: `swift build && swift test`
Expected: success（既存呼び出しはデフォルト引数で互換）

```bash
git add Sources/KoeApp/TranscriptionEngine.swift Sources/KoeApp/AppleSpeechEngine.swift
git commit -m "TranscriptUpdate: 確定セグメント通知を追加（会議モードの議事録組み立て用）"
```

---

### Task 6: SystemAudioCapture（KoeApp）

**Files:**
- Create: `Sources/KoeApp/SystemAudioCapture.swift`（スパイクDの成果をクラス化。スパイクで API 修正があった場合はそちらを正とする）

- [ ] **Step 1: 実装**

```swift
import AudioToolbox
import AVFoundation

/// Core Audio プロセスタップによるシステム再生音声のキャプチャ。
/// 全プロセスの出力をタップし、private 集約デバイスの IOProc で受けて
/// AVAudioPCMBuffer として onBuffer に流す。
///
/// 注意: onBuffer はリアルタイムオーディオスレッドから呼ばれるため
/// @Sendable の非 MainActor クロージャに限定する（AudioRecorder と同じ制約。
/// docs/spike-results.md スパイクB 参照）。
/// TCC「システム音声録音」の許可が必要（Info.plist NSAudioCaptureUsageDescription）。
final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var format: AVAudioFormat?

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    enum CaptureError: Error {
        case tapCreation(OSStatus)
        case formatRead(OSStatus)
        case aggregateCreation(OSStatus)
        case ioProc(OSStatus)
        case deviceStart(OSStatus)
    }

    func start() throws {
        stop()  // 再入時は掃除してから

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "KoeMeetingTap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw CaptureError.tapCreation(status) }
        tapID = tap

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            let s = status
            stop()
            throw CaptureError.formatRead(s)
        }
        format = fmt

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Koe-MeetingCapture",
            kAudioAggregateDeviceUIDKey: "jp.luxgo.koe.meeting-agg",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard status == noErr else {
            let s = status
            stop()
            throw CaptureError.aggregateCreation(s)
        }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self, let format = self.format else { return }
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: UnsafeMutablePointer(mutating: inInputData),
                deallocator: nil) else { return }
            self.onBuffer?(pcm)
        }
        guard status == noErr, proc != nil else {
            let s = status
            stop()
            throw CaptureError.ioProc(s)
        }
        procID = proc

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            let s = status
            stop()
            throw CaptureError.deviceStart(s)
        }
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        format = nil
    }
}
```

- [ ] **Step 2: ビルド・コミット**

Run: `swift build`
Expected: success

```bash
git add Sources/KoeApp/SystemAudioCapture.swift
git commit -m "SystemAudioCapture: プロセスタップでシステム再生音声をPCMバッファ化"
```

---

### Task 7: MeetingRecorder（オーケストレーター）

**Files:**
- Create: `Sources/KoeApp/MeetingRecorder.swift`

- [ ] **Step 1: 実装**

```swift
import AppKit
import AVFoundation
import Foundation
import KoeCore
import UserNotifications

/// 会議録音モード: マイク（自分）とシステム音声（相手）を並行キャプチャし、
/// AppleSpeechEngine 2系統で文字起こし→停止時に Markdown 議事録を保存する。
/// F9/F10 の通常音声入力（RecordingController）とは完全に独立したインスタンス群で動く。
@MainActor
@Observable
final class MeetingRecorder {
    private(set) var isRecording = false
    private(set) var isFinishing = false
    private(set) var startedAt: Date?
    private(set) var lastSavedURL: URL?
    private(set) var errorMessage: String?

    static let meetingsDir = RecordingController.appSupportDir.appendingPathComponent("meetings")

    private let micRecorder = AudioRecorder()
    private let micEngine = AppleSpeechEngine()
    private let systemCapture = SystemAudioCapture()
    private let systemEngine = AppleSpeechEngine()
    private let store = MeetingStore(directory: MeetingRecorder.meetingsDir)
    private var builder = MeetingTranscriptBuilder()
    private var consumeTasks: [Task<Void, Never>] = []
    private var autoStopTask: Task<Void, Never>?
    private var didPrepare = false
    var settings = AppSettings()

    /// 3時間の安全弁（止め忘れ対策）
    static let maxDuration: Duration = .seconds(3 * 60 * 60)

    func start() async {
        guard !isRecording, !isFinishing else { return }
        errorMessage = nil
        builder = MeetingTranscriptBuilder()

        do {
            if !didPrepare {
                try await micEngine.prepare()
                didPrepare = true
            }
            let start = Date()

            // 認識セッションを先に開き、確定セグメントを収集するタスクを張る
            let micUpdates = try await micEngine.startSession()
            let sysUpdates = try await systemEngine.startSession()
            consumeTasks = [
                consume(micUpdates, speaker: "自分", start: start),
                consume(sysUpdates, speaker: "相手", start: start),
            ]

            // マイク系統
            micEngine.configureMicFormat(micRecorder.inputFormat)
            let micEngineRef = micEngine
            micRecorder.onBuffer = { @Sendable buffer in micEngineRef.feed(buffer) }
            try micRecorder.start()

            // システム音声系統（フォーマットは start() 後に確定する）
            try systemCapture.start()
            if let fmt = systemCapture.format {
                systemEngine.configureMicFormat(fmt)
            }
            let sysEngineRef = systemEngine
            systemCapture.onBuffer = { @Sendable buffer in sysEngineRef.feed(buffer) }

            startedAt = start
            isRecording = true
            autoStopTask = Task { [weak self] in
                try? await Task.sleep(for: Self.maxDuration)
                guard !Task.isCancelled else { return }
                await self?.stopAndSave()
            }
        } catch {
            await teardownCapture()
            await micEngine.cancelSession()
            await systemEngine.cancelSession()
            errorMessage = "開始に失敗しました: \(error.localizedDescription)"
        }
    }

    private func consume(
        _ updates: AsyncStream<TranscriptUpdate>, speaker: String, start: Date
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await update in updates {
                guard let segment = update.finalizedSegment else { continue }
                // 確定到着時刻ベースのタイムスタンプ（finalize遅延ぶん後ろにずれるが議事録用途では許容）
                self?.builder.add(
                    speaker: speaker,
                    seconds: Date().timeIntervalSince(start),
                    text: segment)
            }
        }
    }

    private func teardownCapture() async {
        micRecorder.onBuffer = nil
        micRecorder.stop()
        systemCapture.onBuffer = nil
        systemCapture.stop()
    }

    func stopAndSave() async {
        guard isRecording, !isFinishing else { return }
        isFinishing = true
        isRecording = false
        autoStopTask?.cancel()
        autoStopTask = nil
        let start = startedAt ?? Date()
        startedAt = nil

        await teardownCapture()
        // finalize で残りの volatile が確定 → consume タスクがストリーム終端まで拾う
        _ = try? await micEngine.finishAndTranscript()
        _ = try? await systemEngine.finishAndTranscript()
        for task in consumeTasks { await task.value }
        consumeTasks = []

        defer { isFinishing = false }
        guard !builder.isEmpty else {
            errorMessage = "音声を認識できませんでした（保存なし）"
            return
        }

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "ja_JP")
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
        let duration = MeetingTranscriptBuilder.timestamp(Date().timeIntervalSince(start))
        let title = "会議メモ \(dateFmt.string(from: start))（\(duration)）"
        var markdown = builder.renderMarkdown(title: title)

        // AI整形ONのときだけ要約を付与（オンデバイス完結を保ちたい場合はOFFで運用）
        if settings.aiRefinementEnabled {
            let service = RefinementService(timeout: .seconds(45))
            let (summary, fallbackReason) = await service.refine(
                builder.plainText(),
                modelID: settings.modelID,
                instruction: MeetingSummaryPrompt.instruction)
            if fallbackReason == nil {
                markdown = "# \(title)\n\n\(summary)\n\n## 全文書き起こし\n\n"
                    + builder.renderMarkdown(title: "").replacingOccurrences(of: "# \n\n", with: "")
            }
        }

        do {
            let url = try store.save(markdown: markdown, date: start)
            lastSavedURL = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
            let content = UNMutableNotificationContent()
            content.title = "議事録を保存しました"
            content.body = url.lastPathComponent
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: ビルド・コミット**

Run: `swift build`
Expected: success

```bash
git add Sources/KoeApp/MeetingRecorder.swift
git commit -m "MeetingRecorder: マイク＋システム音声の2系統文字起こしと議事録保存"
```

---

### Task 8: UI 統合＋Info.plist

**Files:**
- Modify: `Sources/KoeApp/KoeApp.swift`
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Info.plist に使用目的を追加**

`NSMicrophoneUsageDescription` の後に:

```xml
    <key>NSAudioCaptureUsageDescription</key>
    <string>会議の相手側の音声を文字起こしするためにシステム音声を録音します。</string>
```

- [ ] **Step 2: KoeApp.swift に会議録音UIを追加**

`KoeApp` struct に `@State private var meetingRecorder = MeetingRecorder()` を追加し、
MenuBarExtra のアイコンとコンテンツを更新:

```swift
    @State private var meetingRecorder: MeetingRecorder

    init() {
        let c = RecordingController()
        _controller = State(initialValue: c)
        _meetingRecorder = State(initialValue: MeetingRecorder())
        // （既存の Task { ... } はそのまま）
    }

    var body: some Scene {
        MenuBarExtra("Koe", systemImage:
            meetingRecorder.isRecording ? "record.circle.fill"
            : controller.isRecording ? "mic.fill" : "mic") {
            PopoverContent(controller: controller, meetingRecorder: meetingRecorder)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(controller: controller)
        }
    }
```

`PopoverContent` に `@Bindable var meetingRecorder: MeetingRecorder` を追加し、
「直近の書き起こし」セクションの前に会議録音セクションを挿入:

```swift
            Divider()

            // 会議録音（マイク＋システム音声 → 議事録Markdown）
            if meetingRecorder.isRecording {
                HStack {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    if let started = meetingRecorder.startedAt {
                        Text(started, style: .timer).monospacedDigit()
                    }
                    Spacer()
                    Button("停止して保存") {
                        Task { await meetingRecorder.stopAndSave() }
                    }
                }
            } else if meetingRecorder.isFinishing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("議事録を保存中…").font(.caption)
                }
            } else {
                Button {
                    Task { await meetingRecorder.start() }
                } label: {
                    Label("会議録音を開始", systemImage: "record.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if let err = meetingRecorder.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Button("議事録フォルダを開く") {
                try? FileManager.default.createDirectory(
                    at: MeetingRecorder.meetingsDir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(MeetingRecorder.meetingsDir)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
```

- [ ] **Step 3: ビルド・全テスト・コミット**

Run: `swift build && swift test`
Expected: success

```bash
git add Sources/KoeApp/KoeApp.swift Resources/Info.plist
git commit -m "会議録音UI: メニューポップオーバーに開始/停止・経過時間・フォルダ導線を追加"
```

---

### Task 9: 実機スモークテストと README

**Files:**
- Modify: `README.md`（会議録音モードの節を追加）

- [ ] **Step 1: アプリをビルド・インストール**

Run: `bash scripts/build-app.sh --install`
Expected: 署名成功・/Applications/Koe.app 起動

- [ ] **Step 2: スモークテスト（手動）**

1. メニューバー → 「会議録音を開始」→ 初回はシステム音声録音の TCC プロンプト → 許可
2. YouTube 等で日本語音声を再生しつつ、自分でも喋る
3. メニューアイコンが record.circle.fill になり経過時間が進む
4. 「停止して保存」→ Finder で `Application Support/Koe/meetings/YYYY-MM-DD-HHmm-meeting.md` が選択表示される
5. Markdown に「自分」「相手」のセグメントが時刻順で入っている
6. AI整形ONで再テスト → 冒頭に要約セクションが付く
7. 会議録音中に F9 の通常音声入力も動くか確認（動かなければ既知の制限として README に記載）

- [ ] **Step 3: README 追記・最終コミット**

README に「会議録音モード」節（使い方・保存先・TCC 権限・録音は相手の同意を得てから、の注意）を追加。

```bash
git add README.md
git commit -m "README: 会議録音モードの使い方と注意事項を追記"
```

- [ ] **Step 4: main へマージ**

スモークテスト合格後:

```bash
git checkout main && git merge --no-ff feature/meeting-recorder -m "会議録音・文字起こしモードをマージ（マイク＋システム音声→議事録Markdown＋AI要約）"
git push
```

---

## Self-Review メモ

- スパイクD が唯一の技術リスク。API シグネチャ相違があれば Task 6 はスパイクの実コードを正として書き直す
- `MeetingRecorder.builder` は MainActor 隔離プロパティを consume タスク（MainActor 継承 Task）から触るため data race なし
- `RefinementService.refine` は fallback 時に原文（plainText）を返すため、fallbackReason == nil のときだけ要約として採用するガードを入れてある
- 既存 `TranscriptUpdate` 利用箇所（RecordingController）はデフォルト引数で無変更のまま互換
