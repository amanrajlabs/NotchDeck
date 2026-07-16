import SwiftUI

private func providerColor(_ provider: String) -> Color {
    provider == "codex" ? .cyan : .orange
}

struct AIWaitingPill: View {
    let session: AISession
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hourglass").font(.system(size: 10))
            Text(session.projectName).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.yellow)
    }
}

struct AICodingPanelView: View {
    @ObservedObject var module: AICodingModule
    var body: some View {
        Group {
            if module.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No recent AI coding sessions").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(module.sessions) { session in
                            AISessionRow(session: session) { module.focus(session) }  // focus: Task 10
                        }
                    }
                }
            }
        }
        .onAppear { module.refresh() }
    }
}

struct AISessionRow: View {
    let session: AISession
    let onTap: () -> Void
    @State private var hovering = false

    private var statusText: String {
        switch session.status {
        case .waitingApproval: "waiting for approval"
        case .running: "running"
        case .done: "done"
        case .idle: "idle"
        }
    }
    private var statusColor: Color {
        switch session.status {
        case .waitingApproval: .yellow
        case .running: .green
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 6)
                .fill(providerColor(session.provider).opacity(0.18))
                .overlay(Circle().fill(statusColor).frame(width: 6, height: 6))
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.projectName).font(.system(size: 11, weight: .bold)).lineLimit(1)
                    if let model = session.model {
                        Text(model.replacingOccurrences(of: "claude-", with: ""))
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                Text(statusText).font(.system(size: 8)).foregroundStyle(statusColor)
                if let msg = session.lastMessage {
                    Text(msg).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(session.lastActivity, style: .relative)
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                Text("\(AISessionRow.compact(session.tokens)) tok")
                    .font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.cardHover : Theme.card))
        .onHover { hovering = $0 }
        .onTapGesture { onTap() }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }
}
