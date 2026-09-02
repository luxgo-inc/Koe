import KoeCore
import KoeKit
import SwiftUI

struct IOSSettingsView: View {
    @State private var apiKey = ""
    @State private var apiKeySaved = false
    @State private var aiEnabled = AppSettings().aiRefinementEnabled
    @State private var google = GoogleOAuthClient.shared
    @State private var googleMessage: String?

    private let settings = AppSettings()

    var body: some View {
        NavigationStack {
            Form {
                Section("Google Docs 連携") {
                    if google.isSignedIn {
                        Label("サインイン済み", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("保存した議事録は Google ドライブの「Koe」フォルダに Google ドキュメントとして自動アップロードされます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("サインアウト", role: .destructive) {
                            google.signOut()
                        }
                    } else {
                        Button("Google にサインイン") {
                            Task {
                                do {
                                    try await google.signIn()
                                    await UploadQueue.shared.drain()
                                } catch {
                                    googleMessage = error.localizedDescription
                                }
                            }
                        }
                        Text("議事録を Google ドキュメントとして自動保存するにはサインインしてください。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("AI要約（Claude API・従量課金）") {
                    Toggle("保存時にAI要約を付ける", isOn: $aiEnabled)
                        .onChange(of: aiEnabled) { _, newValue in
                            settings.aiRefinementEnabled = newValue
                        }
                    SecureField("Anthropic APIキー", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(apiKeySaved ? "保存しました ✓" : "APIキーを保存") {
                        KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        apiKey = ""
                        apiKeySaved = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            apiKeySaved = false
                        }
                    }
                    .disabled(apiKey.isEmpty)
                    if KeychainStore.loadAPIKey()?.isEmpty == false {
                        Text("APIキーは設定済みです（Keychain保存）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("保存先") {
                    Text("議事録はこの iPhone の「ファイル」アプリ > Koe > meetings にも保存されます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .alert("Google サインイン", isPresented: .init(
                get: { googleMessage != nil },
                set: { if !$0 { googleMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(googleMessage ?? "")
            }
        }
    }
}
