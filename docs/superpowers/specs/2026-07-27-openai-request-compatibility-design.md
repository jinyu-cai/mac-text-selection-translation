# 全后端 OpenAI 请求兼容设计

## 目标

修复 GPT-5.6 等推理模型因请求字段不符合 OpenAI Chat Completions
规范而返回 HTTP 400 的问题。所有可配置 AI 后端都声明为 OpenAI
兼容端点，因此 OpenAI、DeepSeek、OpenRouter、Nebius、NVIDIA、
SiliconFlow、DashScope 以及本地服务必须收到同一套 OpenAI 标准字段。

## 根因

当前客户端为所有后端共用同一套请求体：

- 非“自动”思考模式错误地使用 OpenRouter 私有的 `reasoning` 对象。
- 所有模型固定发送 `temperature: 0.2`。

OpenAI Chat Completions 使用顶层字符串字段 `reasoning_effort`，不接受当前的
OpenRouter `reasoning` 对象。采样温度兼容性还取决于具体 GPT-5 代际和有效
推理强度，不能用一个笼统的 `gpt-5` 前缀规则处理。

兼容后端即使容忍或忽略私有/不支持的字段，也不表示这些高级参数真正生效。
客户端不再根据服务商猜测协议方言，而是统一执行设置页已经承诺的 OpenAI
兼容契约。

## 方案

### 统一协议

Base URL 只决定请求发送到哪里，不参与参数字段选择。不解析主机名、不维护
服务商枚举，也不为任何后端生成 OpenRouter 私有字段。这样同一个模型经官方
地址、代理地址或本地网关调用时，请求语义保持一致。

### 请求体映射

对所有 AI 后端：

- `auto`：不发送推理控制字段。
- `off`：发送 `"reasoning_effort": "none"`。
- `low`、`medium`、`high`、`xhigh`、`max`：发送同名的
  `reasoning_effort` 字符串。
- 永远不发送 OpenRouter 风格的 `reasoning` 对象。
- GPT-5.5 和 GPT-5.6（包括 Sol、Terra、Luna、快照和带路由前缀的模型名）
  保留 `temperature: 0.2`。
- GPT-5.1、GPT-5.2 和 GPT-5.4 只在思考模式为“关闭”、请求明确包含
  `reasoning_effort: none` 时保留 `temperature: 0.2`；其他推理强度省略。
- 更早的 GPT-5、GPT-5 Codex 变体以及以字母 `o` 加数字开头的模型
  （例如 `o1`、`o3-mini`、`o4-mini`）省略 `temperature`。
- 其他模型保留 `temperature: 0.2`。
- 不更改端点拼接、认证、消息结构、流式解析或响应解析。

## 代码边界

将请求体高级参数映射提取为可独立测试的纯逻辑。该逻辑不接收 Base URL，
从类型边界上避免重新引入按提供商分流。`OpenAIClient` 仍负责 URLRequest、
认证、网络调用和 SSE 解析，只消费该纯逻辑生成的请求参数。

纯逻辑放入 `MacTranslatorCore`，使现有命令行测试目标无需依赖 AppKit、SwiftUI 或真实网络即可验证请求兼容规则。

## 测试

先写失败测试并确认失败，再实现最小代码：

1. `gpt-5.6-sol` + `medium`：
   - 包含 `reasoning_effort = medium`。
   - 不包含 `reasoning`。
   - 保留 `temperature = 0.2`。
2. GPT-5.6 Terra/Luna + `xhigh`/`max`：
   - 包含相应的 `reasoning_effort`。
   - 保留 `temperature = 0.2`。
3. GPT-5.4 + `medium`：
   - 不包含 `temperature`。
4. GPT-5.4/GPT-5.2/GPT-5.1 + `off`：
   - 包含 `reasoning_effort = none`。
   - 保留 `temperature = 0.2`。
5. 更早的 GPT-5 或 GPT-5 Codex：
   - 不包含 `temperature`。
6. `gpt-4o-mini` + `auto`：
   - 不包含推理字段。
   - 保留 `temperature = 0.2`。
7. DeepSeek + `high`：
   - 包含 `reasoning_effort = high`。
   - 不包含 `reasoning`。
   - 保留 `temperature = 0.2`。
8. `openai/gpt-5.6` 和 GPT-5.6 快照仍保留 `temperature`；
   `openai/o3` 仍省略。

## 非目标

- 不迁移 OpenAI 后端到 Responses API。
- 不新增提供商选择器。
- 不修改用户已保存的后端配置或 API Key。
- 不发起真实的收费 API 请求。
