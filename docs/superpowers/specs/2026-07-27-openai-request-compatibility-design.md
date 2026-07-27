# OpenAI 原生后端请求兼容设计

## 目标

修复 `api.openai.com` 后端使用 GPT-5.6 等推理模型时返回 HTTP 400 的问题，同时保证 DeepSeek、OpenRouter、Nebius、NVIDIA、SiliconFlow、DashScope 等其他 OpenAI 兼容后端的请求体保持现状。

## 根因

当前客户端为所有后端共用同一套请求体：

- 非“自动”思考模式使用 OpenRouter 风格的 `reasoning` 对象。
- 所有模型固定发送 `temperature: 0.2`。

OpenAI Chat Completions 使用顶层字符串字段 `reasoning_effort`，不接受当前的 OpenRouter `reasoning` 对象。GPT-5 和 o 系列推理模型也不应由本客户端强制发送采样温度。

DeepSeek V4 能成功，是因为其思考模式默认开启且默认 effort 为 `high`，并会为兼容现有客户端而忽略不支持的采样参数。成功响应不表示当前 `reasoning` 对象真正控制了 DeepSeek 的思考强度。本次修改遵循用户要求，不改变 DeepSeek 或任何其他后端的现有请求。

## 方案

### 提供商识别

通过解析 Base URL，仅当规范化后的主机名严格等于 `api.openai.com` 时启用 OpenAI 原生规则。

不按模型名前缀识别提供商，因为代理服务和第三方平台也可能托管以 `gpt-`、`o` 或 `openai/` 开头的模型。也不新增持久化的提供商枚举，以避免扩大设置界面和配置迁移范围。

### 请求体映射

对 `api.openai.com`：

- `auto`：不发送推理控制字段。
- `off`：发送 `"reasoning_effort": "none"`。
- `low`、`medium`、`high`：发送同名的 `reasoning_effort` 字符串。
- 永远不发送 OpenRouter 风格的 `reasoning` 对象。
- 当规范化后的模型名以 `gpt-5` 开头，或以字母 `o` 加数字开头（例如 `o1`、`o3-mini`、`o4-mini`）时，省略固定的 `temperature`。
- 其他 OpenAI 模型继续保留现有 `temperature: 0.2` 行为。

对所有其他主机：

- 保持现有 OpenRouter 风格 `reasoning` 映射不变。
- 保持现有 `temperature: 0.2` 不变。
- 不更改端点拼接、认证、消息结构、流式解析或响应解析。

## 代码边界

将“Base URL 是否为 OpenAI 官方主机”和“请求体参数映射”提取为可独立测试的纯逻辑。`OpenAIClient` 仍负责 URLRequest、认证、网络调用和 SSE 解析，只消费该纯逻辑生成的请求体。

纯逻辑放入 `MacTranslatorCore`，使现有命令行测试目标无需依赖 AppKit、SwiftUI 或真实网络即可验证请求兼容规则。

## 测试

先写失败测试并确认失败，再实现最小代码：

1. `api.openai.com` + `gpt-5.6-sol` + `medium`：
   - 包含 `reasoning_effort = medium`。
   - 不包含 `reasoning`。
   - 不包含 `temperature`。
2. `api.openai.com` + GPT-5 + `off`：
   - 包含 `reasoning_effort = none`。
3. `api.openai.com` + `gpt-4o-mini` + `auto`：
   - 不包含推理字段。
   - 保留 `temperature = 0.2`。
4. DeepSeek + `high`：
   - 继续包含原有 `reasoning.effort = high`。
   - 继续包含 `temperature = 0.2`。
   - 不包含 `reasoning_effort`。
5. Base URL 带尾部斜杠、大小写主机名或额外路径时，仍只根据解析后的精确主机名识别 OpenAI。

## 非目标

- 不迁移 OpenAI 后端到 Responses API。
- 不修正或重新设计 DeepSeek 的思考参数。
- 不新增提供商选择器。
- 不修改用户已保存的后端配置或 API Key。
- 不发起真实的收费 API 请求。
