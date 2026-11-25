import SwiftUI

/// Is everything working? Each part of the chain a title passes through is checked, the result is
/// OK, WARN, FAIL or Not set, and anything that isn't OK says what to do and links there. Below the
/// checks: recent alerts, and a report to share when asking for help.
struct StatusView: View {
    @State private var log: [AppLog.Entry] = AppLog.entries
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var trakt: TraktStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var memory: SourceMemory
    @EnvironmentObject private var alerts: AlertCenter
    @EnvironmentObject private var router: AppRouter
    @Environment(\.openURL) private var openURL
    @StateObject private var health = HealthModel()

    var body: some View {
        List {
            Section {
                summary
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section("Checks") {
                ForEach(sortedChecks) { check in row(check) }
            }

            Section {
                if alerts.recent.isEmpty {
                    Text("No alerts yet.").foregroundStyle(Theme.secondaryText)
                }
                ForEach(alerts.recent.prefix(20)) { alert in alertRow(alert) }
            } header: {
                HStack {
                    Text("Recent Alerts")
                    Spacer()
                    if !alerts.recent.isEmpty {
                        Button("Clear") { alerts.clear() }.font(.caption.weight(.semibold)).textCase(nil)
                    }
                }
            }

            if !log.isEmpty {
                Section {
                    DisclosureGroup("\(log.count) recent errors") {
                        ForEach(log.prefix(30)) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.area) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                                Text(entry.message).font(.caption).textSelection(.enabled)
                            }
                        }
                        Button("Clear Log", role: .destructive) { AppLog.clear(); log = [] }
                    }
                } header: {
                    Text("Log")
                } footer: {
                    Text("Included in the shared report. Keys and tokens are removed before anything is kept.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .navigationTitle("Status")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: health.report) { Image(systemName: "square.and.arrow.up") }
                    .disabled(health.checks.isEmpty || health.isRunning)
                    .accessibilityLabel("Share report")
            }
        }
        .refreshable { await run() }
        .task { await run() }
        .onAppear { alerts.markSeen() }
    }

    private func run() async {
        await health.run(settings: settings, trakt: trakt, downloads: downloads, memory: memory)
    }

    /// Worst first, so what needs doing is at the top.
    private var sortedChecks: [HealthCheck] {
        health.checks.enumerated().sorted { lhs, rhs in
            lhs.element.level == rhs.element.level ? lhs.offset < rhs.offset : lhs.element.level > rhs.element.level
        }
        .map(\.element)
    }

    private var summary: some View {
        let worst = health.worst
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint(worst).opacity(0.18)).frame(width: 56, height: 56)
                if health.isRunning && health.checks.allSatisfy({ $0.detail == "Checking…" }) {
                    ProgressView()
                } else {
                    Image(systemName: symbol(worst)).font(.title2.weight(.semibold)).foregroundStyle(tint(worst))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(health.summary).font(.headline)
                Group {
                    if health.isRunning {
                        Text("Checking…")
                    } else if let ranAt = health.ranAt {
                        Text("Checked \(ranAt.formatted(date: .omitted, time: .shortened)). Pull down to check again.")
                    }
                }
                .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.vertical, 4)
    }

    private func row(_ check: HealthCheck) -> some View {
        let pending = check.detail == "Checking…"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: check.systemImage)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 24)
                Text(check.title).font(.body.weight(.semibold))
                Spacer()
                if pending {
                    ProgressView().controlSize(.small)
                } else {
                    Text(check.level.label)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(tint(check.level))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(tint(check.level).opacity(0.16), in: Capsule())
                }
            }
            Text(check.detail).font(.subheadline).foregroundStyle(pending ? Theme.secondaryText : .white.opacity(0.88))
            if let advice = check.advice, check.level != .ok, !pending {
                Label(advice, systemImage: "lightbulb").font(.caption).foregroundStyle(Theme.secondaryText)
            }
            if let fix = check.fix, let title = check.fixTitle, !pending {
                Button(title) { router.perform(fix, openURL: openURL) }
                    .buttonStyle(.glass)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func alertRow(_ alert: AppAlert) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.systemImage).foregroundStyle(alertTint(alert.level)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.subheadline.weight(.semibold))
                if let message = alert.message {
                    Text(message).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
                }
                Text(alert.date.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 4)
            if let action = alert.action, let title = alert.actionTitle {
                Button(title) { router.perform(action) }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private func tint(_ level: HealthCheck.Level) -> Color {
        switch level {
        case .ok: return Theme.cached
        case .notSet: return Theme.secondaryText
        case .warning: return Theme.warning
        case .problem: return Theme.problem
        }
    }

    private func symbol(_ level: HealthCheck.Level) -> String {
        switch level {
        case .ok, .notSet: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    private func alertTint(_ level: AppAlert.Level) -> Color {
        switch level {
        case .info: return Theme.accent
        case .success: return Theme.cached
        case .warning: return Theme.warning
        case .problem: return Theme.problem
        }
    }
}
