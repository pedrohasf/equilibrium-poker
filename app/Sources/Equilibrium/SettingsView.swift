import DesignSystem
import LLMKit
import SwiftUI

struct SettingsView: View {
    @State private var key = APIKeyStore.keychainValue ?? ""
    @State private var status: String?
    @State private var testing = false
    @AppStorage("solverThreads") private var threads = 0

    var body: some View {
        Form {
            SwiftUI.Section {
                SecureField("sk-or-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save to Keychain") {
                        APIKeyStore.save(key)
                        status = "Saved."
                    }
                    Button("Test connection") { Task { await test() } }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                if APIKeyStore.isFromEnvironment {
                    Label("OPENROUTER_API_KEY is set in the environment and takes precedence.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("OpenRouter")
            } footer: {
                Text("Used for LLM benchmarks and arena matches. Stored in your login keychain; never written to disk in plain text.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section("Solver") {
                Stepper(value: $threads, in: 0...ProcessInfo.processInfo.activeProcessorCount) {
                    Text(threads == 0 ? "Threads: all \(ProcessInfo.processInfo.activeProcessorCount) cores" : "Threads: \(threads)")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        if !key.isEmpty { APIKeyStore.save(key) }
        do {
            let client = try OpenRouterClient.fromStoredKey()
            let models = try await client.models()
            status = "Connected · \(models.count) models available"
        } catch {
            status = error.localizedDescription
        }
    }
}
