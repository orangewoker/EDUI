# EDUI

EDUI 是一款面向 iPhone 的模型额度监控工具。它可以读取模型服务商的余额、每日消费额度和请求速率，并通过 WidgetKit 小组件显示在主屏幕。

## 已支持

- AMD Radeon API/OpenAI 兼容服务：通过最小聊天请求读取 `x-ratelimit-*` 响应头。
- DeepSeek：通过官方 `/user/balance` 接口读取余额。
- 自定义 JSON：支持自定义 GET 路径及点号字段路径。
- iOS 小号、中号和大号 Widget。
- iOS 26 clear/tinted Liquid Glass 与 accented rendering mode。
- API Key 使用 iOS Keychain 保存；Widget 只读取 App Group 中的额度快照。

## AMD Radeon API

默认已填写：

- Base URL：`https://developer.amd.com.cn/radeon/api/v1`
- 探测模型：`Qwen3.6-35B-A3B`

出于安全考虑，API Key 不会写入源码。首次打开 EDUI 后编辑默认账户并填写 Key。

## 本地验证

```powershell
flutter pub get
dart analyze lib test
flutter test --no-pub
```

Windows 不能构建 iOS App。推送 `ios` 分支后，GitHub Actions 会使用 macOS Runner 构建并发布无签名 IPA。

## Widget 配置

主应用和 Widget 使用 App Group：

```text
group.com.orangewoker.edui
```

安装并重新签名 IPA 时，签名工具需要保留 Widget Extension 和 App Group entitlement，小组件才能读取主应用写入的快照。

## 安全说明

- 不要将真实 API Key 提交到 Git。
- WidgetKit 数据只包含服务名称、额度数值和更新时间。
- OpenAI 兼容额度探针会产生一次极小的真实 API 请求，因此不适合高频刷新。
