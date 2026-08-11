import Foundation
import SwiftUI
import WidgetKit

private let appGroupId = "group.com.orangewoker.edui"
private let widgetKind = "EDUIWidget"

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
}

struct QuotaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: .now, items: [
            QuotaItem(
                accountId: "preview",
                accountName: "AMD Radeon API",
                remaining: 1,
                limit: 1,
                used: 0,
                unit: "USD/日",
                updatedAt: ISO8601DateFormatter().string(from: .now),
                resetAt: nil,
                requestLimit: 30,
                requestRemaining: 29,
                message: nil
            )
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: .now, items: loadItems()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let entry = QuotaEntry(date: .now, items: loadItems())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadItems() -> [QuotaItem] {
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let raw = defaults.string(forKey: "quota_payload"),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([QuotaItem].self, from: data)
        else { return [] }
        return decoded
    }
}

struct EDUIWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: QuotaEntry

    var body: some View {
        Group {
            if entry.items.isEmpty {
                emptyView
            } else {
                switch family {
                case .systemSmall:
                    smallView(entry.items[0])
                case .systemLarge:
                    listView(limit: 5)
                default:
                    listView(limit: 3)
                }
            }
        }
        .containerBackground(for: .widget) {
            if renderingMode == .fullColor {
                LinearGradient(
                    colors: [Color(red: 0.15, green: 0.18, blue: 0.38), Color(red: 0.38, green: 0.25, blue: 0.68)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
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
            Text("打开应用并刷新额度")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func smallView(_ item: QuotaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bolt.fill")
                    .widgetAccentable()
                Spacer()
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .widgetAccentable()
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
                .foregroundStyle(.secondary)
            if let ratio = item.ratio {
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .widgetAccentable()
            }
        }
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
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(entry.items.prefix(limit))) { item in
                HStack(spacing: 10) {
                    Circle()
                        .fill(item.remaining > 0 ? .green : .red)
                        .frame(width: 7, height: 7)
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.accountName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let ratio = item.ratio {
                            ProgressView(value: ratio)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .widgetAccentable()
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(item.formattedRemaining)
                            .font(.system(.body, design: .rounded, weight: .bold))
                        Text(item.unit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
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
        StaticConfiguration(kind: widgetKind, provider: QuotaTimelineProvider()) { entry in
            EDUIWidgetView(entry: entry)
        }
        .configurationDisplayName("EDUI 额度")
        .description("在桌面查看模型服务商的余额、每日额度和请求限制。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .containerBackgroundRemovable(true)
    }
}
