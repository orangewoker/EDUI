# EDUI

EDUI 是一款面向 iPhone 的模型额度监控工具。它可以读取模型服务商的余额、每日消费额度和请求速率，并通过 WidgetKit 小组件显示在主屏幕。

## 已支持

- AMD Radeon API/OpenAI 兼容服务：优先自动识别 Sub2API、New API / One API 账户余额；站点未提供余额接口时，再通过最小聊天请求读取 USD、Token 和请求数 `x-ratelimit-*` 响应头，不要求手动选择模型。
- DeepSeek：通过官方 `/user/balance` 接口读取余额。
- OpenAI API：通过官方 Organization Costs API 汇总最近 30 天用量；可填写月预算上限以显示剩余额度。
- Sub2API：使用官方兼容的 `GET /v1/usage` 读取账户钱包余额或订阅剩余额度，不发送聊天探测请求。
- 官方账户 / 自定义 JSON：支持 API Key 或手动 Cookie、自定义 GET 路径及点号字段路径。
- 官方登录跳转：优先使用 Universal Link 打开已安装的官方 App，否则打开网页登录页。
- 账户添加页默认隐藏高级字段；OpenAI 兼容中转只需要填写 Base URL 和 API Key，额度格式会自动识别。
- 兼容只返回 `X-Ratelimit-Limit-Tokens` / `X-Ratelimit-Remaining-Tokens` 的中转站，并同时显示请求数额度。
- iOS 小号、中号和大号 Widget。
- Widget 可选择“液态玻璃（半透明）”或“纯白”主题，并支持 iOS 26 clear/tinted Liquid Glass 与 accented rendering mode。
- 主应用 API Key 使用 iOS Keychain 保存；Widget 通过 App Group 读取账户名称和已同步额度快照，不读取 API Key。

## Codex / ChatGPT 订阅

Codex 账户支持两种凭证：完整 Cookie Header，或 Sub2API 导出的 `sub2api-data` JSON。粘贴导出 JSON 后，EDUI 会在发起额度请求时提取 `accounts[].credentials.access_token` 和 `chatgpt_account_id`，调用 ChatGPT 的 `/backend-api/wham/usage` 读取 5 小时与本周额度；只有一个额度窗口时也能显示。Cookie 仍然兼容。两种凭证都只保存在 iOS Keychain，不会写入 Widget 或普通账户配置。OAuth access token 过期后需要重新导出或重新登录。

OpenAI API 组织账户不需要 Cookie。请使用组织 Admin API Key 调用官方 Costs API；普通项目 API Key通常没有读取组织成本的权限。

### Sub2API 配置

选择“Sub2API 余额”，填站点根地址和用户 API Key 即可，例如：

```text
站点地址：https://sub2.zhisheji.fun:1100
余额接口（自动）：/v1/usage
```

Sub2API 源码在网关路由中注册了 `/v1/usage`，钱包模式返回 `remaining`、`balance`、`unit`，订阅模式还返回 `quota` / `rate_limits`。已有的“OpenAI 兼容额度”账户也会先自动尝试这个接口，因此无需重新添加账户。

这里不要填写后台面板的 `/api/v1/usage`：那是 JWT 登录后的面板用量接口；用户 API Key 余额接口是网关的 `/v1/usage`。

### New API / One API 中转站

选择“OpenAI 兼容额度（自动识别）”或快速配置里的“New API / 中转站”，只需填 Base URL 和 API Key。EDUI 会先识别站点的 `/api/status`，再读取 `/v1/dashboard/billing/subscription` 与 `/v1/dashboard/billing/usage`，计算账户剩余额，不会产生模型调用费用。新版 New API 仅开放 API Key 余额时，也会自动回退到带尾斜杠的 `/api/usage/token/` 并按站点公开的 `quota_per_unit` 换算币种。Base URL 可以填写站点根地址，也可以以 `/v1` 结尾。

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

添加 EDUI Widget 后，长按小组件并选择“编辑小组件”，即可从 EDUI 主应用已经配置的账户中选择一个或全部账户，并选择“液态玻璃（半透明）”或“纯白”外观。请先在主应用保存账户并成功刷新一次。

## 安全说明

- 不要将真实 API Key 提交到 Git。
- Widget 不接触 API Key 或 Cookie，只读取 App Group 中的名称和额度快照。
- OpenAI 兼容额度探针会产生一次极小的真实 API 请求，因此不适合高频刷新。
