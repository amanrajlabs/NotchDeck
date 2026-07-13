import AppKit
import SwiftUI

public struct PullRequest: Identifiable, Equatable, Sendable {
    public enum Provider: String, Sendable {
        case github = "GitHub"
        case gitlab = "GitLab"
        case bitbucket = "Bitbucket"
    }

    public var id: String
    public var title: String
    public var repo: String
    public var url: URL
    public var updated: Date?
    public var provider: Provider
    public var isReviewRequest: Bool

    public init(id: String, title: String, repo: String, url: URL, updated: Date?, provider: Provider, isReviewRequest: Bool) {
        self.id = id
        self.title = title
        self.repo = repo
        self.url = url
        self.updated = updated
        self.provider = provider
        self.isReviewRequest = isReviewRequest
    }
}

/// Pure payload parsers, one per provider. Tested with fixtures.
public enum GitPayloadParser {
    static func date(_ raw: Any?) -> Date? {
        guard let string = raw as? String else { return nil }
        // ISO8601DateFormatter isn't Sendable; make fresh ones per call —
        // parsing runs rarely (per fetch), not in a hot path.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
            ?? ISO8601DateFormatter().date(from: string)
    }

    /// GitHub search API (`/search/issues?q=type:pr…`).
    public static func github(data: Data, isReviewRequest: Bool) -> [PullRequest] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let title = item["title"] as? String,
                  let urlString = item["html_url"] as? String,
                  let url = URL(string: urlString),
                  let number = item["number"] as? NSNumber else { return nil }
            // repository_url: https://api.github.com/repos/owner/name
            let repoURL = item["repository_url"] as? String ?? ""
            let repo = repoURL.components(separatedBy: "/repos/").last ?? ""
            return PullRequest(
                id: "gh-\(repo)-\(number)",
                title: title,
                repo: repo,
                url: url,
                updated: date(item["updated_at"]),
                provider: .github,
                isReviewRequest: isReviewRequest
            )
        }
    }

    /// GitLab `/api/v4/merge_requests?...`.
    public static func gitlab(data: Data, isReviewRequest: Bool) -> [PullRequest] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let title = item["title"] as? String,
                  let urlString = item["web_url"] as? String,
                  let url = URL(string: urlString),
                  let iid = item["iid"] as? NSNumber else { return nil }
            let repo = (item["references"] as? [String: Any])?["full"] as? String
                ?? url.pathComponents.dropFirst().prefix(2).joined(separator: "/")
            return PullRequest(
                id: "gl-\(repo)-\(iid)",
                title: title,
                repo: repo.components(separatedBy: "!").first ?? repo,
                url: url,
                updated: date(item["updated_at"]),
                provider: .gitlab,
                isReviewRequest: isReviewRequest
            )
        }
    }

    /// Bitbucket Cloud `/2.0/pullrequests/{user}`.
    public static func bitbucket(data: Data) -> [PullRequest] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["values"] as? [[String: Any]] else { return [] }
        return values.compactMap { item in
            guard let title = item["title"] as? String,
                  let idNumber = item["id"] as? NSNumber,
                  let links = item["links"] as? [String: Any],
                  let html = links["html"] as? [String: Any],
                  let urlString = html["href"] as? String,
                  let url = URL(string: urlString) else { return nil }
            let repo = ((item["destination"] as? [String: Any])?["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            return PullRequest(
                id: "bb-\(repo)-\(idNumber)",
                title: title,
                repo: repo,
                url: url,
                updated: date(item["updated_on"]),
                provider: .bitbucket,
                isReviewRequest: false
            )
        }
    }
}

// MARK: - Module

@MainActor
final class GitModule: NotchModule, ObservableObject {
    static let moduleID = "git"
    let id = GitModule.moduleID
    let name = "Pull Requests"
    let icon = "arrow.triangle.pull"
    let hasPanel = true

    @Published private(set) var pullRequests: [PullRequest] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?

    @Published var githubToken: String {
        didSet { UserDefaults.standard.set(githubToken, forKey: "git.github.token") }
    }
    @Published var gitlabToken: String {
        didSet { UserDefaults.standard.set(gitlabToken, forKey: "git.gitlab.token") }
    }
    @Published var gitlabHost: String {
        didSet { UserDefaults.standard.set(gitlabHost, forKey: "git.gitlab.host") }
    }
    @Published var bitbucketUser: String {
        didSet { UserDefaults.standard.set(bitbucketUser, forKey: "git.bitbucket.user") }
    }
    @Published var bitbucketAppPassword: String {
        didSet { UserDefaults.standard.set(bitbucketAppPassword, forKey: "git.bitbucket.password") }
    }

    init() {
        let defaults = UserDefaults.standard
        githubToken = defaults.string(forKey: "git.github.token") ?? ""
        gitlabToken = defaults.string(forKey: "git.gitlab.token") ?? ""
        gitlabHost = defaults.string(forKey: "git.gitlab.host") ?? "https://gitlab.com"
        bitbucketUser = defaults.string(forKey: "git.bitbucket.user") ?? ""
        bitbucketAppPassword = defaults.string(forKey: "git.bitbucket.password") ?? ""
    }

    func activate() {}
    func deactivate() { pullRequests = [] }

    func panelView() -> AnyView { AnyView(GitPanelView(module: self)) }
    func settingsView() -> AnyView { AnyView(GitSettingsView(module: self)) }

    var hasAnyToken: Bool {
        !githubToken.isEmpty || !gitlabToken.isEmpty
            || (!bitbucketUser.isEmpty && !bitbucketAppPassword.isEmpty)
    }

    func refresh() {
        guard hasAnyToken, !isLoading else {
            if !hasAnyToken { statusMessage = "Add a token in Settings" }
            return
        }
        isLoading = true
        statusMessage = nil
        Task { [weak self] in
            guard let self else { return }
            var collected: [PullRequest] = []
            if !self.githubToken.isEmpty {
                collected += await self.fetchGitHub()
            }
            if !self.gitlabToken.isEmpty {
                collected += await self.fetchGitLab()
            }
            if !self.bitbucketUser.isEmpty, !self.bitbucketAppPassword.isEmpty {
                collected += await self.fetchBitbucket()
            }
            var seen = Set<String>()
            self.pullRequests = collected
                .filter { seen.insert($0.id).inserted }
                .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
            if self.pullRequests.isEmpty { self.statusMessage = "No open pull requests" }
            self.isLoading = false
        }
    }

    private func getJSON(_ url: URL, headers: [String: String]) async -> Data? {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func fetchGitHub() async -> [PullRequest] {
        let headers = [
            "Authorization": "Bearer \(githubToken)",
            "Accept": "application/vnd.github+json",
        ]
        var results: [PullRequest] = []
        let queries: [(String, Bool)] = [
            ("type:pr+state:open+author:@me", false),
            ("type:pr+state:open+review-requested:@me", true),
        ]
        for (query, isReview) in queries {
            let url = URL(string: "https://api.github.com/search/issues?q=\(query)&per_page=20")!
            if let data = await getJSON(url, headers: headers) {
                results += GitPayloadParser.github(data: data, isReviewRequest: isReview)
            }
        }
        return results
    }

    private func fetchGitLab() async -> [PullRequest] {
        let headers = ["PRIVATE-TOKEN": gitlabToken]
        var results: [PullRequest] = []
        let scopes: [(String, Bool)] = [
            ("created_by_me", false),
            ("assigned_to_me", true),
        ]
        for (scope, isReview) in scopes {
            let url = URL(string: "\(gitlabHost)/api/v4/merge_requests?state=opened&scope=\(scope)&per_page=20")!
            if let data = await getJSON(url, headers: headers) {
                results += GitPayloadParser.gitlab(data: data, isReviewRequest: isReview)
            }
        }
        return results
    }

    private func fetchBitbucket() async -> [PullRequest] {
        let credentials = Data("\(bitbucketUser):\(bitbucketAppPassword)".utf8).base64EncodedString()
        let url = URL(string: "https://api.bitbucket.org/2.0/pullrequests/\(bitbucketUser)?state=OPEN")!
        guard let data = await getJSON(url, headers: ["Authorization": "Basic \(credentials)"]) else {
            return []
        }
        return GitPayloadParser.bitbucket(data: data)
    }
}

// MARK: - Views

struct GitPanelView: View {
    @ObservedObject var module: GitModule

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Open pull requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if module.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        module.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
            if let status = module.statusMessage, module.pullRequests.isEmpty {
                VStack(spacing: 8) {
                    Text(status).foregroundStyle(.secondary)
                    if !module.hasAnyToken { OpenSettingsButton() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(module.pullRequests) { pr in
                            Button {
                                NSWorkspace.shared.open(pr.url)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: pr.isReviewRequest ? "eye.fill" : "arrow.triangle.pull")
                                        .font(.system(size: 11))
                                        .foregroundStyle(pr.isReviewRequest ? .orange : .green)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(pr.title).font(.system(size: 12)).lineLimit(1)
                                        Text("\(pr.provider.rawValue) · \(pr.repo)")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if let updated = pr.updated {
                                        Text(updated, style: .relative)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { module.refresh() }
    }
}

struct GitSettingsView: View {
    @ObservedObject var module: GitModule

    var body: some View {
        Section("Pull Requests") {
            SecureField("GitHub token (PAT)", text: $module.githubToken)
            SecureField("GitLab token", text: $module.gitlabToken)
            TextField("GitLab host", text: $module.gitlabHost)
            TextField("Bitbucket username", text: $module.bitbucketUser)
            SecureField("Bitbucket app password", text: $module.bitbucketAppPassword)
        }
    }
}
