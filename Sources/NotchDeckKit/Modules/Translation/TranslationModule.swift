import SwiftUI

/// Extracts translated text from OpenAI / Ollama response JSON. Pure, tested.
public enum TranslationResponseParser {
    public static func openAIText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func ollamaText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class TranslationModule: NotchModule, ObservableObject {
    static let moduleID = "translation"
    let id = TranslationModule.moduleID
    let name = "Translation"
    let icon = "character.bubble.fill"
    let hasPanel = true
    var preferredHeight: CGFloat { 176 }

    enum Engine: String, CaseIterable {
        case openAI = "OpenAI"
        case ollama = "Ollama"
    }

    static let languages = [
        "English", "Hindi", "Spanish", "French", "German", "Japanese",
        "Chinese", "Korean", "Portuguese", "Arabic",
    ]

    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var targetLanguage: String {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "translation.target") }
    }
    @Published var engine: Engine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "translation.engine") }
    }
    @Published var isTranslating = false
    @Published var errorMessage: String?

    // Settings-pane fields.
    @Published var openAIKey: String {
        didSet { KeychainStore.set(openAIKey, for: "translation.openai.key") }
    }
    @Published var ollamaURL: String {
        didSet { UserDefaults.standard.set(ollamaURL, forKey: "translation.ollama.url") }
    }
    @Published var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "translation.ollama.model") }
    }

    init() {
        let defaults = UserDefaults.standard
        targetLanguage = defaults.string(forKey: "translation.target") ?? "English"
        engine = Engine(rawValue: defaults.string(forKey: "translation.engine") ?? "") ?? .openAI
        openAIKey = KeychainStore.migrateFromDefaults(key: "translation.openai.key")
        ollamaURL = defaults.string(forKey: "translation.ollama.url") ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: "translation.ollama.model") ?? "llama3.2"
    }

    func activate() {}
    func deactivate() {}

    func panelView() -> AnyView { AnyView(TranslationPanelView(module: self)) }

    func settingsView() -> AnyView { AnyView(TranslationSettingsView(module: self)) }

    func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isTranslating else { return }
        isTranslating = true
        errorMessage = nil
        let prompt = "Translate the following text to \(targetLanguage). Reply with ONLY the translation, nothing else.\n\n\(text)"
        Task { [weak self] in
            guard let self else { return }
            do {
                let result: String?
                switch self.engine {
                case .openAI: result = try await self.callOpenAI(prompt: prompt)
                case .ollama: result = try await self.callOllama(prompt: prompt)
                }
                self.translatedText = result ?? ""
                if result == nil { self.errorMessage = "Unexpected response" }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isTranslating = false
        }
    }

    private func callOpenAI(prompt: String) async throws -> String? {
        guard !openAIKey.isEmpty else {
            throw NSError(domain: "NotchDeck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Add your OpenAI API key in Settings",
            ])
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini",
            "messages": [["role": "user", "content": prompt]],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return TranslationResponseParser.openAIText(from: data)
    }

    private func callOllama(prompt: String) async throws -> String? {
        guard let url = URL(string: ollamaURL + "/api/chat") else {
            throw NSError(domain: "NotchDeck", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid Ollama URL",
            ])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": ollamaModel,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return TranslationResponseParser.ollamaText(from: data)
    }
}

struct TranslationPanelView: View {
    @ObservedObject var module: TranslationModule

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $module.engine) {
                    ForEach(TranslationModule.Engine.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer()
                Text("to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $module.targetLanguage) {
                    ForEach(TranslationModule.languages, id: \.self) { Text($0) }
                }
                .frame(width: 110)
                Button {
                    module.translate()
                } label: {
                    if module.isTranslating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                }
                .disabled(module.isTranslating)
            }
            HStack(spacing: 8) {
                TextEditor(text: $module.sourceText)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: .constant(module.translatedText))
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                    if let error = module.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(8)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                .overlay(alignment: .bottomTrailing) {
                    if !module.translatedText.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(module.translatedText, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .help("Copy translation")
                    }
                }
            }
        }
    }
}

struct TranslationSettingsView: View {
    @ObservedObject var module: TranslationModule

    var body: some View {
        Section("Translation") {
            SecureField("OpenAI API key", text: $module.openAIKey)
            TextField("Ollama URL", text: $module.ollamaURL)
            TextField("Ollama model", text: $module.ollamaModel)
        }
    }
}
