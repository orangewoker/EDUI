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
        .white: "纯白",
    ]
}

struct MonitorAccountEntity: AppEntity, Codable, Hashable, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "监控账户"
    static var defaultQuery = MonitorAccountQuery()

    let id: String
    let name: String
    let providerType: String?

    init(id: String, name: String, providerType: String? = nil) {
        self.id = id
        self.name = name
        self.providerType = providerType
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MonitorAccountQuery: EntityQuery {
    func entities(for identifiers: [MonitorAccountEntity.ID]) async throws -> [MonitorAccountEntity] {
        let all = Self.loadAccounts()
        return identifiers.compactMap { identifier in
            all.first(where: { $0.id == identifier })
        }
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
            return []
        }
        return decoded
    }
}

/// A subscription rate-limit window. The bridge sends remaining percentages,
/// which keeps WidgetKit independent from each provider's `used_percent` shape.
struct QuotaWindow: Codable, Hashable, Identifiable {
    let label: String
    let remainingPercent: Double
    let resetAt: String?

    var id: String { label }

    var normalizedRemaining: Double {
        min(max(remainingPercent, 0), 100)
    }

    var ratio: Double {
        normalizedRemaining / 100
    }
}

struct QuotaItem: Decodable, Identifiable {
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
    let quotaWindows: [QuotaWindow]?
    var providerType: String?

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

    var isSubscription: Bool {
        if quotaWindows?.isEmpty == false { return true }
        guard unit.contains("%"), limit == 100 else { return false }
        return providerType == "customJson" || (providerType == nil && message == nil)
    }

    var displayWindows: [QuotaWindow] {
        if let quotaWindows, !quotaWindows.isEmpty {
            return Array(quotaWindows.prefix(2))
        }
        guard isSubscription else { return [] }
        return [
            QuotaWindow(
                label: "5 小时额度",
                remainingPercent: min(max(remaining, 0), 100),
                resetAt: resetAt
            ),
        ]
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
    static var description = IntentDescription("选择要在这个小组件中显示的 EDUI 账户；不选择时按尺寸自动显示。")

    @Parameter(
        title: "显示账户",
        default: [],
        size: [
            .systemSmall: IntentCollectionSize(min: 0, max: 2),
            .systemMedium: IntentCollectionSize(min: 0, max: 4),
            .systemLarge: IntentCollectionSize(min: 0, max: 20),
            .systemExtraLarge: IntentCollectionSize(min: 0, max: 50),
        ]
    )
    var accounts: [MonitorAccountEntity]

    @Parameter(title: "外观", default: .liquidGlass)
    var appearance: WidgetAppearance

    init() {
        accounts = []
        appearance = .liquidGlass
    }
}

struct QuotaTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(
            date: .now,
            items: [previewSubscription, previewBalance],
            message: nil,
            appearance: .liquidGlass
        )
    }

    func snapshot(
        for configuration: QuotaWidgetConfiguration,
        in context: Context
    ) async -> QuotaEntry {
        if context.isPreview {
            return QuotaEntry(
                date: .now,
                items: [previewSubscription, previewBalance],
                message: nil,
                appearance: configuration.appearance
            )
        }
        return loadEntry(for: configuration)
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

    private var previewSubscription: QuotaItem {
        QuotaItem(
            accountId: "preview-codex",
            accountName: "Codex · Plus",
            remaining: 64,
            limit: 100,
            used: 36,
            unit: "%",
            updatedAt: ISO8601DateFormatter().string(from: .now),
            resetAt: ISO8601DateFormatter().string(
                from: .now.addingTimeInterval(3 * 3600)
            ),
            requestLimit: nil,
            requestRemaining: nil,
            message: nil,
            quotaWindows: [
                QuotaWindow(
                    label: "5 小时额度",
                    remainingPercent: 64,
                    resetAt: ISO8601DateFormatter().string(
                        from: .now.addingTimeInterval(3 * 3600)
                    )
                ),
                QuotaWindow(
                    label: "周额度",
                    remainingPercent: 58,
                    resetAt: ISO8601DateFormatter().string(
                        from: .now.addingTimeInterval(4 * 24 * 3600)
                    )
                ),
            ],
            providerType: "customJson"
        )
    }

    private var previewBalance: QuotaItem {
        QuotaItem(
            accountId: "preview-deepseek",
            accountName: "DeepSeek",
            remaining: 12.8,
            limit: nil,
            used: nil,
            unit: "CNY",
            updatedAt: ISO8601DateFormatter().string(from: .now),
            resetAt: nil,
            requestLimit: nil,
            requestRemaining: nil,
            message: "余额可用",
            quotaWindows: nil,
            providerType: "deepSeek"
        )
    }

    private func loadEntry(for configuration: QuotaWidgetConfiguration) -> QuotaEntry {
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let raw = defaults.string(forKey: "quota_payload"),
            let data = raw.data(using: .utf8),
            var allItems = try? JSONDecoder().decode([QuotaItem].self, from: data)
        else {
            return QuotaEntry(
                date: .now,
                items: [],
                message: "打开 EDUI 并刷新账户后再添加小组件",
                appearance: configuration.appearance
            )
        }

        let accountMetadata = Dictionary(
            uniqueKeysWithValues: MonitorAccountQuery.loadAccounts().compactMap { account in
                account.providerType.map { (account.id, $0) }
            }
        )
        for index in allItems.indices {
            allItems[index].providerType = accountMetadata[allItems[index].accountId]
        }

        let selectedIds = configuration.accounts.map(\.id)
        let items: [QuotaItem]
        if selectedIds.isEmpty {
            items = allItems
        } else {
            let indexedItems = Dictionary(
                allItems.map { ($0.accountId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            items = selectedIds.compactMap { indexedItems[$0] }
        }
        return QuotaEntry(
            date: .now,
            items: items,
            message: items.isEmpty ? "所选账户还没有同步数据" : nil,
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

    private var primaryText: Color {
        guard renderingMode == .fullColor else { return .primary }
        return isWhiteAppearance
            ? Color(red: 0.05, green: 0.07, blue: 0.12)
            : .white
    }

    private var secondaryText: Color {
        guard renderingMode == .fullColor else { return .primary.opacity(0.72) }
        return isWhiteAppearance
            ? Color(red: 0.25, green: 0.28, blue: 0.34)
            : Color.white.opacity(0.78)
    }

    private var accentColor: Color {
        guard renderingMode == .fullColor else { return .accentColor }
        return isWhiteAppearance
            ? Color(red: 0.12, green: 0.46, blue: 0.94)
            : Color(red: 0.38, green: 0.72, blue: 1.0)
    }

    private var progressTrackColor: Color {
        guard renderingMode == .fullColor else { return .primary.opacity(0.18) }
        return isWhiteAppearance ? Color.black.opacity(0.10) : Color.white.opacity(0.18)
    }

    private var visibleItems: [QuotaItem] {
        switch family {
        case .systemSmall:
            return Array(entry.items.prefix(2))
        case .systemMedium:
            return Array(entry.items.prefix(4))
        case .systemLarge:
            return entry.items
        case .systemExtraLarge:
            return entry.items
        default:
            return Array(entry.items.prefix(1))
        }
    }

    private var cardIsCompact: Bool {
        switch family {
        case .systemSmall:
            return visibleItems.count > 1
        case .systemMedium:
            return visibleItems.count > 1
        case .systemLarge:
            return visibleItems.count > 1
        case .systemExtraLarge:
            return visibleItems.count > 1
        default:
            return false
        }
    }

    private var gridColumnCount: Int {
        let itemCount = max(visibleItems.count, 1)
        switch family {
        case .systemMedium:
            return itemCount == 1 ? 1 : 2
        case .systemLarge:
            if itemCount <= 2 { return itemCount }
            if itemCount <= 4 { return 2 }
            if itemCount <= 9 { return 3 }
            return 4
        case .systemExtraLarge:
            if itemCount <= 2 { return itemCount }
            if itemCount <= 4 { return 2 }
            if itemCount <= 8 { return 4 }
            if itemCount <= 15 { return 5 }
            if itemCount <= 24 { return 6 }
            if itemCount <= 35 { return 7 }
            return 10
        default:
            return 1
        }
    }

    private var gridRowCount: Int {
        max(1, Int(ceil(Double(visibleItems.count) / Double(gridColumnCount))))
    }

    private var gridSpacing: CGFloat {
        switch family {
        case .systemMedium:
            return visibleItems.count > 2 ? 8 : 14
        case .systemLarge:
            if visibleItems.count > 12 { return 7 }
            if visibleItems.count > 4 { return 10 }
            return 14
        case .systemExtraLarge:
            if visibleItems.count > 24 { return 6 }
            if visibleItems.count > 8 { return 8 }
            return 14
        default:
            return 10
        }
    }

    private var gridColumns: [GridItem] {
        return Array(
            repeating: GridItem(.flexible(), spacing: gridSpacing),
            count: gridColumnCount
        )
    }

    private var usesDenseGrid: Bool {
        switch family {
        case .systemMedium:
            return visibleItems.count > 2
        case .systemLarge:
            return visibleItems.count > 4
        case .systemExtraLarge:
            return visibleItems.count > 8
        default:
            return false
        }
    }

    private var usesUltraDenseGrid: Bool {
        switch family {
        case .systemLarge:
            return visibleItems.count > 9
        case .systemExtraLarge:
            return visibleItems.count > 15
        default:
            return false
        }
    }

    var body: some View {
        Group {
            if visibleItems.isEmpty {
                emptyView
            } else if family == .systemSmall {
                if visibleItems.count == 1 {
                    accountCard(visibleItems[0], compact: false)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(visibleItems) { item in
                            smallCompactRow(item)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                GeometryReader { proxy in
                    let availableHeight = max(
                        0,
                        proxy.size.height - CGFloat(gridRowCount - 1) * gridSpacing
                    )
                    let cellHeight = availableHeight / CGFloat(gridRowCount)
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridSpacing) {
                        ForEach(visibleItems) { item in
                            Group {
                                if usesUltraDenseGrid {
                                    ultraDenseAccountCard(item)
                                } else {
                                    accountCard(item, compact: cardIsCompact)
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                minHeight: cellHeight,
                                maxHeight: cellHeight,
                                alignment: .topLeading
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .foregroundStyle(primaryText)
        .containerBackground(for: .widget) {
            widgetBackground
        }
    }

    @ViewBuilder
    private var widgetBackground: some View {
        if renderingMode == .fullColor {
            if isWhiteAppearance {
                ZStack {
                    Color.white.opacity(0.90)
                    LinearGradient(
                        colors: [
                            Color(red: 0.82, green: 0.91, blue: 1.0).opacity(0.25),
                            Color.white.opacity(0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            } else {
                ZStack {
                    Color(red: 0.07, green: 0.08, blue: 0.17).opacity(0.76)
                    LinearGradient(
                        colors: [
                            Color(red: 0.26, green: 0.42, blue: 0.96).opacity(0.48),
                            Color(red: 0.61, green: 0.30, blue: 0.91).opacity(0.38),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        } else {
            Color.clear
        }
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.title2.weight(.semibold))
                .widgetAccentable()
            Text("EDUI")
                .font(.headline.bold())
            Text(entry.message ?? "打开 EDUI 刷新额度")
                .font(.caption)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func accountCard(_ item: QuotaItem, compact: Bool) -> some View {
        if item.isSubscription {
            subscriptionCard(item, compact: compact)
        } else {
            balanceCard(item, compact: compact)
        }
    }

    @ViewBuilder
    private func smallCompactRow(_ item: QuotaItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            accountHeader(item, dense: true)
            if item.isSubscription {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(item.displayWindows) { window in
                        smallQuotaSummary(window)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("可用余额")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(item.formattedRemaining)
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                    Text(item.unit)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smallQuotaSummary(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(window.label)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 1)
                Text("\(percentNumber(window.normalizedRemaining))%")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
            }
            quotaProgress(window.ratio, height: 3)
        }
    }

    private func ultraDenseAccountCard(_ item: QuotaItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            accountHeader(item, dense: true)
            if item.isSubscription {
                ForEach(item.displayWindows) { window in
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(window.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        Spacer(minLength: 1)
                        Text("\(percentNumber(window.normalizedRemaining))%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.65)
                            .lineLimit(1)
                    }
                    quotaProgress(window.ratio, height: 2)
                }
            } else {
                Text("可用余额")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(item.formattedRemaining)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .minimumScaleFactor(0.45)
                        .lineLimit(1)
                    Text(item.unit)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subscriptionCard(_ item: QuotaItem, compact: Bool) -> some View {
        let windows = item.displayWindows
        return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            accountHeader(item)
            if family == .systemSmall, windows.count > 1 {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(windows) { window in
                        miniWindow(window)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if usesDenseGrid {
                ForEach(windows) { window in
                    compactWindow(window, compact: true)
                }
            } else if let first = windows.first {
                prominentWindow(first, compact: compact)
                if windows.count > 1 {
                    compactWindow(windows[1], compact: compact)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountHeader(_ item: QuotaItem, dense: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(item.accountName.uppercased())
                .font(dense ? .system(size: 9, weight: .bold) : .caption2.weight(.bold))
                .tracking(dense ? 0.55 : 1.0)
                .lineLimit(1)
            Spacer(minLength: 2)
            Circle()
                .fill(item.remaining > 0 ? Color.green : Color.red)
                .frame(width: 6, height: 6)
        }
    }

    private func prominentWindow(_ window: QuotaWindow, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            Text(window.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(percentNumber(window.normalizedRemaining))
                    .font(
                        .system(
                            size: compact ? 26 : 36,
                            weight: .black,
                            design: .rounded
                        )
                    )
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Text("%")
                    .font(compact ? .caption.bold() : .body.bold())
            }
            quotaProgress(window.ratio)
            resetLabel(window.resetAt)
        }
    }

    private func compactWindow(_ window: QuotaWindow, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(percentNumber(window.normalizedRemaining))%")
                    .font(compact ? .caption.bold() : .callout.bold())
            }
            quotaProgress(window.ratio)
            if !compact {
                resetLabel(window.resetAt)
            }
        }
        .padding(.top, compact ? 1 : 2)
    }

    private func miniWindow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(percentNumber(window.normalizedRemaining))
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Text("%")
                    .font(.caption2.bold())
            }
            quotaProgress(window.ratio)
        }
    }

    private func balanceCard(_ item: QuotaItem, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            accountHeader(item)
            Text("可用余额")
                .font(.caption2.weight(.medium))
                .foregroundStyle(secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.formattedRemaining)
                    .font(
                        .system(
                            size: compact ? 25 : 34,
                            weight: .black,
                            design: .rounded
                        )
                    )
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text(item.unit)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
            if let ratio = item.ratio {
                quotaProgress(ratio)
            }
            if let resetAt = item.resetAt {
                resetLabel(resetAt)
            } else if !compact {
                Text("余额已同步")
                    .font(.caption2)
                    .foregroundStyle(secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaProgress(_ value: Double, height: CGFloat = 4) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(progressTrackColor)
                Capsule()
                    .fill(accentColor)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
                    .widgetAccentable()
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func resetLabel(_ raw: String?) -> some View {
        if let raw, let date = parseDate(raw) {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 8, weight: .semibold))
                Text(date, style: .relative)
                    .lineLimit(1)
                Text("后重置")
                    .lineLimit(1)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(secondaryText)
        }
    }

    private func parseDate(_ raw: String) -> Date? {
        if let timestamp = Double(raw) {
            let seconds = timestamp > 100_000_000_000 ? timestamp / 1000 : timestamp
            return Date(timeIntervalSince1970: seconds)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private func percentNumber(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
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
        .description("自选账户：订阅显示 5 小时和周额度，API 服务显示余额。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .containerBackgroundRemovable(true)
    }
}
