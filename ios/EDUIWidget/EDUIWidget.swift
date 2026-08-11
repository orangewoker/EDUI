import AppIntents
import Foundation
import SwiftUI
import WidgetKit

private let baseAppGroupId = "group.com.orangewoker.edui"
private let widgetKind = "EDUIWidget"

private var appGroupId: String {
    let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
    return groups?.first(where: { $0.contains(baseAppGroupId) }) ?? baseAppGroupId
}

enum WidgetAppearance: String, AppEnum, Sendable {
    case liquidGlass
    case white

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "小组件外观"
    static var caseDisplayRepresentations: [WidgetAppearance: DisplayRepresentation] = [
        .liquidGlass: "液态玻璃（半透明）",
        .white: "纯白"
    ]
}

struct MonitorAccountEntity: AppEntity, Codable, Hashable, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "监控账户"
    static var defaultQuery = MonitorAccountQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MonitorAccountQuery: EntityQuery {
    func entities(for identifiers: [MonitorAccountEntity.ID]) async throws -> [MonitorAccountEntity] {
        let all = Self.loadAccounts()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MonitorAccountEntity] {
        Self.loadAccounts()
    }

    func defaultResult() async -> MonitorAccountEntity? {
        Self.loadAccounts().first
    }

    static func loadAccounts() -> [MonitorAccountEntity] {
        let defaults = UserDefaults(suiteName: appGroupId)
        guard
            let raw = defaults?.string(forKey: "quota_accounts"),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([MonitorAccountEntity].self, from: data),
            !decoded.isEmpty
        else {
            return [MonitorAccountEntity(id: "__all__", name: "全部账户")]
        }
        return [MonitorAccountEntity(id: "__all__", name: "全部账户")] + decoded
    }
}

struct QuotaItem: Codable, Identifiable {
    let accountId: String
    let accountName: String
    let remaining: Double
    let limit: Double?
    let used: Double?
    let unit: String
    let updatedAt: String
    let resetAt: String?
    let requestLimit: Int?
    let requestRemaining: Int?
    let message: String?

    var id: String { accountId }

    var ratio: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(remaining / limit, 0), 1)
    }

    var formattedRemaining: String {
        if abs(remaining) >= 100 { return String(format: "%.0f", remaining) }
        if abs(remaining) >= 1 { return String(format: "%.2f", remaining) }
        return String(format: "%.4f", remaining)
    }
}

struct QuotaEntry: TimelineEntry {
    let date: Date
    let items: [QuotaItem]
    let message: String?
    let appearance: WidgetAppearance
}

struct QuotaWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "额度账户"
    static var description = IntentDescription("选择 EDUI 主应用中已经配置的监控账户。")

    @Parameter(title: "监控账户")
    var account: MonitorAccountEntity?

    @Parameter(title: "外观", default: .liquidGlass)
    var appearance: WidgetAppearance

    init() {
        account = nil
        appearance = .liquidGlass
    }
}

struct QuotaTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: .now, items: [previewItem], message: nil, appearance: .liquidGlass)
    }

    func snapshot(
        for configuration: QuotaWidgetConfiguration,
        in context: Context
    ) async -> QuotaEntry {
        loadEntry(for: configuration)
    }

    func timeline(
        for configuration: QuotaWidgetConfiguration,
        in context: Context
    ) async -> Timeline<QuotaEntry> {
        let entry = loadEntry(for: configuration)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now)
            ?? .now.addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private var previewItem: QuotaItem {
        QuotaItem(
            accountId: "preview",
            accountName: "DeepSeek",
            remaining: 110,
            limit: nil,
            used: nil,
            unit: "CNY",
            updatedAt: ISO8601DateFormatter().string(from: .now),
            resetAt: nil,
            requestLimit: nil,
            requestRemaining: nil,
            message: "余额可用"
        )
    }

    private func loadEntry(for configuration: QuotaWidgetConfiguration) -> QuotaEntry {
        let selectedId = configuration.account?.id
            ?? MonitorAccountQuery.loadAccounts().dropFirst().first?.id
        guard let selectedId else {
            return QuotaEntry(
                date: .now,
                items: [],
                message: "请先在 EDUI 中添加监控账户",
                appearance: configuration.appearance
            )
        }
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let raw = defaults.string(forKey: "quota_payload"),
            let data = raw.data(using: .utf8),
            let allItems = try? JSONDecoder().decode([QuotaItem].self, from: data)
        else {
            return QuotaEntry(
                date: .now,
                items: [],
                message: "打开 EDUI 并刷新账户后再添加小组件",
                appearance: configuration.appearance
            )
        }
        let items = selectedId == "__all__"
            ? allItems
            : allItems.filter { $0.accountId == selectedId }
        return QuotaEntry(
            date: .now,
            items: items,
            message: items.isEmpty ? "该账户还没有同步数据" : nil,
            appearance: configuration.appearance
        )
    }
}

struct EDUIWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: QuotaEntry

    private var isWhiteAppearance: Bool {
        entry.appearance == .white
    }

    /// Keep explicit colors in full-color mode; semantic colors let WidgetKit
    /// choose a readable tint in accented and vibrant rendering modes.
    private var primaryText: Color {
        guard renderingMode == .fullColor else { return .primary }
        return isWhiteAppearance
            ? Color(red: 0.06, green: 0.08, blue: 0.16)
            : .white
    }

    private var secondaryText: Color {
        guard renderingMode == .fullColor else { return .primary.opacity(0.72) }
        return isWhiteAppearance
            ? Color(red: 0.20, green: 0.24, blue: 0.36)
            : Color.white.opacity(0.86)
    }

    private var accentColor: Color {
        guard renderingMode == .fullColor else { return .accentColor }
        return isWhiteAppearance
            ? Color(red: 0.16, green: 0.30, blue: 0.82)
            : Color(red: 0.88, green: 0.93, blue: 1.0)
    }

    private var progressTrackColor: Color {
        guard renderingMode == .fullColor else {
            return .primary.opacity(0.25)
        }
        return isWhiteAppearance
            ? Color.black.opacity(0.14)
            : Color.white.opacity(0.30)
    }

    private var surfaceFill: Color {
        if renderingMode != .fullColor {
            return isWhiteAppearance
                ? Color.white.opacity(0.16)
                : Color.black.opacity(0.16)
        }
        return isWhiteAppearance
            ? Color.white.opacity(0.84)
            : Color.black.opacity(0.28)
    }

    private var surfaceBorder: Color {
        if renderingMode != .fullColor {
            return .primary.opacity(0.20)
        }
        return isWhiteAppearance
            ? Color.white.opacity(0.96)
            : Color.white.opacity(0.30)
    }

    var body: some View {
        Group {
            if entry.items.isEmpty {
                emptyView
            } else if family == .systemSmall {
                smallView(entry.items[0])
            } else {
                listView(limit: family == .systemLarge ? 5 : 3)
            }
        }
        .padding(family == .systemMedium ? 8 : 12)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(surfaceFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(surfaceBorder, lineWidth: 1)
                }
        }
        .containerBackground(for: .widget) {
            if renderingMode == .fullColor {
                if entry.appearance == .white {
                    Color(red: 0.94, green: 0.96, blue: 1.0)
                } else {
                    ZStack {
                        Color(red: 0.04, green: 0.06, blue: 0.14).opacity(0.82)
                        LinearGradient(
                            colors: [
                                Color(red: 0.28, green: 0.42, blue: 0.96).opacity(0.42),
                                Color(red: 0.58, green: 0.30, blue: 0.92).opacity(0.34),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            } else {
                Color.clear
            }
        }
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.title)
                .widgetAccentable()
            Text("EDUI")
                .font(.headline.bold())
            Text(entry.message ?? "打开 EDUI 刷新额度")
                .font(.caption)
                .foregroundStyle(secondaryText)
        }
        .foregroundStyle(primaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func smallView(_ item: QuotaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bolt.fill")
                    .widgetAccentable()
                Spacer()
                Circle()
                    .fill(item.remaining > 0 ? .green : .red)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle()
                            .stroke(primaryText.opacity(0.62), lineWidth: 1)
                    }
            }
            Spacer(minLength: 2)
            Text(item.accountName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(item.formattedRemaining)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(item.unit)
                .font(.caption2)
                .foregroundStyle(secondaryText)
            if let ratio = item.ratio {
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .tint(accentColor)
                    .background(progressTrackColor, in: Capsule())
                    .widgetAccentable()
            }
        }
        .foregroundStyle(primaryText)
    }

    private func listView(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("额度监控", systemImage: "waveform.path.ecg")
                    .font(.headline.bold())
                    .widgetAccentable()
                Spacer()
                Text("EDUI")
                    .font(.caption.bold())
                    .foregroundStyle(secondaryText)
            }
            ForEach(Array(entry.items.prefix(limit))) { item in
                HStack(spacing: 10) {
                    Circle()
                        .fill(item.remaining > 0 ? .green : .red)
                        .frame(width: 7, height: 7)
                        .overlay {
                            Circle()
                                .stroke(primaryText.opacity(0.62), lineWidth: 1)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.accountName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let ratio = item.ratio {
                            ProgressView(value: ratio)
                                .progressViewStyle(.linear)
                                .tint(accentColor)
                                .background(progressTrackColor, in: Capsule())
                                .widgetAccentable()
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(item.formattedRemaining)
                            .font(.system(.body, design: .rounded, weight: .bold))
                        Text(item.unit)
                            .font(.caption2)
                            .foregroundStyle(secondaryText)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(primaryText)
    }
}

@main
struct EDUIWidgetBundle: WidgetBundle {
    var body: some Widget {
        EDUIQuotaWidget()
    }
}

struct EDUIQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: widgetKind,
            intent: QuotaWidgetConfiguration.self,
            provider: QuotaTimelineProvider()
        ) { entry in
            EDUIWidgetView(entry: entry)
        }
        .configurationDisplayName("EDUI 额度")
        .description("选择 EDUI 主应用中已配置的账户，显示余额和额度。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .containerBackgroundRemovable(true)
    }
}
