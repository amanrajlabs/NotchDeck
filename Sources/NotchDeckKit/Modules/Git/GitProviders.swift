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
    let name = "PRs / MRs"
    let icon = "arrow.triangle.pull"
    let hasPanel = true
    var preferredHeight: CGFloat { 158 }

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

    func headerBadge() -> AnyView? {
        let toReview = pullRequests.filter(\.isReviewRequest).count
        return AnyView(
            Text("\(toReview) to review")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        )
    }

    func headerActions() -> AnyView? {
        AnyView(
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    CircleIconButton(icon: "arrow.clockwise", size: 20) { [weak self] in
                        self?.refresh()
                    }
                }
            }
        )
    }

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
        Group {
            if !module.hasAnyToken {
                VStack(spacing: 7) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("Connect providers")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Add a Personal Access Token for GitHub, GitLab, or Bitbucket in Settings to see PRs/MRs requesting your review.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    OpenSettingsButton()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    sidebar.frame(width: 130)
                    list.frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { module.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 10)).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PRs / MRs").font(.system(size: 11, weight: .semibold))
                    Text("\(module.pullRequests.count) open")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Circle().fill(Color.white).frame(width: 4, height: 4)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pipelines").font(.system(size: 11, weight: .semibold))
                    Text("0 pipelines").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .opacity(0.55)
            Spacer(minLength: 0)
        }
    }

    private var list: some View {
        Group {
            if module.pullRequests.isEmpty {
                Text(module.statusMessage ?? "No open pull requests")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(module.pullRequests) { pr in
                            PullRequestRow(pr: pr)
                        }
                    }
                }
            }
        }
    }
}

struct PullRequestRow: View {
    let pr: PullRequest
    @State private var hovering = false

    private var providerColor: Color {
        switch pr.provider {
        case .github: Color(red: 0.55, green: 0.45, blue: 1.0)
        case .gitlab: Color(red: 0.99, green: 0.43, blue: 0.16)
        case .bitbucket: Color(red: 0.16, green: 0.42, blue: 0.99)
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(providerColor.opacity(0.35))
                .overlay(
                    Text(String(pr.repo.prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                )
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(pr.title)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(pr.repo)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(pr.provider.rawValue)
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
                        .foregroundStyle(.secondary)
                    if pr.isReviewRequest {
                        Text("review")
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.3)))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 0)
            if let updated = pr.updated {
                Text(updated, style: .relative)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            CircleIconButton(icon: "arrow.up.right", size: 20) {
                NSWorkspace.shared.open(pr.url)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.cardHover : Theme.card))
        .onHover { hovering = $0 }
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
