import AppIntents
import Foundation
import SwiftUI
import WidgetKit

private let widgetKind = "EDUIWidget"

struct QuotaWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "额度账户"
    static var description = IntentDescription("配置小组件直接查询的模型服务商。")

    @Parameter(title: "显示名称", default: "AMD Radeon API")
    var accountName: String

    @Parameter(title: "API Base URL", default: "https://developer.amd.com.cn/radeon/api/v1")
    var baseURL: String

    @Parameter(title: "API Key", default: "")
    var apiKey: String

    @Parameter(title: "探测模型", default: "Qwen3.6-35B-A3B")
    var model: String
}

struct QuotaItem: Identifiable {
    let accountName: String
    let remaining: Double
    let limit: Double?
    let used: Double?
    let unit: String
    let requestLimit: Int?
    let requestRemaining: Int?

    var id: String { accountName }

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
}

struct QuotaTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: .now, items: [previewItem], message: nil)
    }

    func snapshot(
        for configuration: QuotaWidgetConfiguration,
        in context: Context
    ) async -> QuotaEntry {
        if context.isPreview {
            return QuotaEntry(date: .now, items: [previewItem], message: nil)
        }
        return await fetch(configuration)
    }

    func timeline(
        for configuration: QuotaWidgetConfiguration,
        in context: Context
    ) async -> Timeline<QuotaEntry> {
        let entry = await fetch(configuration)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now)
            ?? .now.addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private var previewItem: QuotaItem {
        QuotaItem(
            accountName: "AMD Radeon API",
            remaining: 1,
            limit: 1,
            used: 0,
            unit: "USD/日",
            requestLimit: 30,
            requestRemaining: 29
        )
    }

    private func fetch(_ configuration: QuotaWidgetConfiguration) async -> QuotaEntry {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return QuotaEntry(date: .now, items: [], message: "长按小组件，编辑并填写 API Key")
        }

        let base = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/chat/completions") else {
            return QuotaEntry(date: .now, items: [], message: "API URL 无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "messages": [["role": "user", "content": "Reply with a single dot."]],
            "max_tokens": 1,
            "stream": false,
        ])

        do {
            let (_, rawResponse) = try await URLSession.shared.data(for: request)
            guard let response = rawResponse as? HTTPURLResponse else {
                return QuotaEntry(date: .now, items: [], message: "服务响应无效")
            }
            guard (200..<300).contains(response.statusCode) else {
                return QuotaEntry(
                    date: .now,
                    items: [],
                    message: "API 请求失败：HTTP \(response.statusCode)"
                )
            }

            let limit = doubleHeader("x-ratelimit-limit-user-daily-usd", in: response)
            let remaining = doubleHeader("x-ratelimit-remaining-user-daily-usd", in: response)
            let used = doubleHeader("x-ratelimit-used-user-daily-usd", in: response)
            guard remaining != nil || limit != nil else {
                return QuotaEntry(date: .now, items: [], message: "响应中没有额度信息")
            }
            let resolvedRemaining = remaining ?? max((limit ?? 0) - (used ?? 0), 0)
            let item = QuotaItem(
                accountName: configuration.accountName,
                remaining: resolvedRemaining,
                limit: limit,
                used: used,
                unit: "USD/日",
                requestLimit: intHeader("x-ratelimit-limit-user-rpm", in: response),
                requestRemaining: intHeader("x-ratelimit-remaining-user-rpm", in: response)
            )
            return QuotaEntry(date: .now, items: [item], message: nil)
        } catch {
            return QuotaEntry(date: .now, items: [], message: "刷新失败，请稍后重试")
        }
    }

    private func doubleHeader(_ name: String, in response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: name) else { return nil }
        return Double(value)
    }

    private func intHeader(_ name: String, in response: HTTPURLResponse) -> Int? {
        guard let value = response.value(forHTTPHeaderField: name) else { return nil }
        return Int(Double(value) ?? 0)
    }
}

struct EDUIWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: QuotaEntry

    var body: some View {
        Group {
            if let item = entry.items.first {
                if family == .systemSmall {
                    smallView(item)
                } else {
                    listView(item)
                }
            } else {
                emptyView
            }
        }
        .containerBackground(for: .widget) {
            if renderingMode == .fullColor {
                LinearGradient(
                    colors: [
                        Color(red: 0.15, green: 0.18, blue: 0.38),
                        Color(red: 0.38, green: 0.25, blue: 0.68),
                    ],
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
            Text(entry.message ?? "编辑小组件以配置账户")
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

    private func listView(_ item: QuotaItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("额度监控", systemImage: "waveform.path.ecg")
                    .font(.headline.bold())
                    .widgetAccentable()
                Spacer()
                Text("EDUI")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(item.accountName)
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline) {
                Text(item.formattedRemaining)
                    .font(.system(size: family == .systemLarge ? 44 : 34, weight: .black, design: .rounded))
                Text(item.unit)
                    .foregroundStyle(.secondary)
                Spacer()
                if let remaining = item.requestRemaining, let limit = item.requestLimit {
                    Text("\(remaining)/\(limit) RPM")
                        .font(.caption)
                }
            }
            if let ratio = item.ratio {
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .widgetAccentable()
            }
            Spacer(minLength: 0)
            Text("更新于 \(entry.date, style: .time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        AppIntentConfiguration(
            kind: widgetKind,
            intent: QuotaWidgetConfiguration.self,
            provider: QuotaTimelineProvider()
        ) { entry in
            EDUIWidgetView(entry: entry)
        }
        .configurationDisplayName("EDUI 额度")
        .description("在桌面查看模型服务商的每日额度和请求限制。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .containerBackgroundRemovable(true)
    }
}
