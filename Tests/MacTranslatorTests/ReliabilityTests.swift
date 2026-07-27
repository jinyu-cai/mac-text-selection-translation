import AppKit
import Darwin
import MacTranslatorCore
import ServiceManagement

@main
struct ReliabilityTests {
    static func main() {
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        expect(
            ClipboardRestorePolicy.shouldRestore(capturedChangeCount: 42, currentChangeCount: 42),
            "clipboard: observed generation should be restored"
        )
        expect(
            !ClipboardRestorePolicy.shouldRestore(capturedChangeCount: 42, currentChangeCount: 43),
            "clipboard: a newer generation must not be overwritten"
        )
        expect(
            !ClipboardRestorePolicy.shouldRestore(capturedChangeCount: nil, currentChangeCount: 42),
            "clipboard: timeout without an observed copy must not restore later"
        )

        testPopupSize(expect: expect)
        testGrowingPopup(expect: expect)
        testLoginItemState(expect: expect)
        testOpenAIRequestParameters(expect: expect)

        if failures.isEmpty {
            print("All reliability tests passed (40 assertions).")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }

    private static func testPopupSize(expect: (Bool, String) -> Void) {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = PopupGeometry.constrainedSize(
            CGSize(width: 2_000, height: 2_000),
            minimum: CGSize(width: 300, height: 140),
            maximum: CGSize(width: 900, height: 1_000),
            visibleFrame: visible
        )

        expect(size.width == 784, "popup: oversized width should fit the screen")
        expect(size.height == 584, "popup: oversized height should fit the screen")
    }

    private static func testGrowingPopup(expect: (Bool, String) -> Void) {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 360, height: 460)
        // This top-left fits the initial 180pt popup but a 460pt popup would
        // extend below the screen without the post-growth fitting step.
        let frame = PopupGeometry.frame(
            topLeft: NSPoint(x: 212, y: 188),
            size: size,
            visibleFrame: visible
        )

        expect(frame.minX >= visible.minX + PopupGeometry.margin, "popup: left edge escaped")
        expect(frame.maxX <= visible.maxX - PopupGeometry.margin, "popup: right edge escaped")
        expect(frame.minY >= visible.minY + PopupGeometry.margin, "popup: bottom edge escaped")
        expect(frame.maxY <= visible.maxY - PopupGeometry.margin, "popup: top edge escaped")
    }

    private static func testLoginItemState(expect: (Bool, String) -> Void) {
        expect(LoginItemRegistrationPolicy.isRegistered(.enabled), "login item: enabled should be registered")
        expect(
            LoginItemRegistrationPolicy.isRegistered(.requiresApproval),
            "login item: requiresApproval should remain registered"
        )
        expect(
            !LoginItemRegistrationPolicy.isRegistered(.notRegistered),
            "login item: notRegistered should be false"
        )
        expect(!LoginItemRegistrationPolicy.isRegistered(.notFound), "login item: notFound should be false")
    }

    private static func testOpenAIRequestParameters(expect: (Bool, String) -> Void) {
        let openAIMedium = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5.6-sol",
            reasoning: "medium"
        )
        expect(
            openAIMedium["reasoning_effort"] as? String == "medium",
            "request: medium should use OpenAI reasoning_effort"
        )
        expect(openAIMedium["reasoning"] == nil, "request: must not send a provider-specific reasoning object")
        expect(
            openAIMedium["temperature"] as? Double == 0.2,
            "request: GPT-5.6 should support temperature with reasoning"
        )

        let terraXHigh = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5.6-terra",
            reasoning: "xhigh"
        )
        expect(
            terraXHigh["reasoning_effort"] as? String == "xhigh",
            "request: GPT-5.6 Terra should support xhigh reasoning"
        )
        expect(
            terraXHigh["temperature"] as? Double == 0.2,
            "request: GPT-5.6 Terra should retain temperature"
        )

        let lunaMax = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5.6-luna",
            reasoning: "max"
        )
        expect(
            lunaMax["reasoning_effort"] as? String == "max",
            "request: GPT-5.6 Luna should support max reasoning"
        )
        expect(
            lunaMax["temperature"] as? Double == 0.2,
            "request: GPT-5.6 Luna should retain temperature"
        )

        let openAIOff = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5",
            reasoning: "off"
        )
        expect(
            openAIOff["reasoning_effort"] as? String == "none",
            "request: off should map to OpenAI reasoning_effort none"
        )
        expect(openAIOff["temperature"] == nil, "request: GPT-5 must omit temperature even when reasoning is off")

        let gpt55High = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5.5",
            reasoning: "high"
        )
        expect(
            gpt55High["temperature"] as? Double == 0.2,
            "request: GPT-5.5 should retain temperature"
        )

        let gpt54Medium = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5.4",
            reasoning: "medium"
        )
        expect(
            gpt54Medium["temperature"] == nil,
            "request: GPT-5.4 must omit temperature when reasoning is enabled"
        )

        let gpt54Off = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5.4",
            reasoning: "off"
        )
        expect(
            gpt54Off["reasoning_effort"] as? String == "none",
            "request: GPT-5.4 off should explicitly select reasoning none"
        )
        expect(
            gpt54Off["temperature"] as? Double == 0.2,
            "request: GPT-5.4 should support temperature with reasoning none"
        )

        let gpt52Off = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5.2",
            reasoning: "off"
        )
        expect(
            gpt52Off["temperature"] as? Double == 0.2,
            "request: GPT-5.2 should support temperature with reasoning none"
        )

        let gpt51Off = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5.1",
            reasoning: "off"
        )
        expect(
            gpt51Off["temperature"] as? Double == 0.2,
            "request: GPT-5.1 should support temperature with reasoning none"
        )

        let codexReasoning = ChatCompletionRequestPolicy.parameters(
            model: "gpt-5.3-codex",
            reasoning: "off"
        )
        expect(
            codexReasoning["temperature"] == nil,
            "request: GPT-5 Codex models must omit temperature"
        )

        let openAIAuto = ChatCompletionRequestPolicy.parameters(
            model: "gpt-4o-mini",
            reasoning: "auto"
        )
        expect(openAIAuto["reasoning_effort"] == nil, "request: auto must omit reasoning_effort")
        expect(openAIAuto["reasoning"] == nil, "request: auto must omit provider-specific reasoning")
        expect(
            openAIAuto["temperature"] as? Double == 0.2,
            "request: non-reasoning models should retain temperature"
        )

        let compatibleBackend = ChatCompletionRequestPolicy.parameters(
            model: "deepseek-chat",
            reasoning: "high"
        )
        expect(
            compatibleBackend["reasoning_effort"] as? String == "high",
            "request: every compatible backend should receive OpenAI reasoning_effort"
        )
        expect(
            compatibleBackend["reasoning"] == nil,
            "request: compatible backends must not receive provider-specific reasoning"
        )
        expect(
            compatibleBackend["temperature"] as? Double == 0.2,
            "request: compatible non-OpenAI model names should retain temperature"
        )

        let routedGPT = ChatCompletionRequestPolicy.parameters(
            model: "openai/gpt-5.6",
            reasoning: "low"
        )
        expect(
            routedGPT["temperature"] as? Double == 0.2,
            "request: routed GPT-5.6 model names should retain temperature"
        )

        let snapshotGPT = ChatCompletionRequestPolicy.parameters(
            model: "openai/gpt-5.6-sol-2026-07-01",
            reasoning: "medium"
        )
        expect(
            snapshotGPT["temperature"] as? Double == 0.2,
            "request: GPT-5.6 snapshots should retain temperature"
        )

        let oSeries = ChatCompletionRequestPolicy.parameters(
            model: "o4-mini",
            reasoning: "high"
        )
        expect(oSeries["temperature"] == nil, "request: o-series models must omit temperature")

        let routedOSeries = ChatCompletionRequestPolicy.parameters(
            model: "openai/o3",
            reasoning: "low"
        )
        expect(routedOSeries["temperature"] == nil, "request: routed o-series model names must omit temperature")

        let unknownReasoning = ChatCompletionRequestPolicy.parameters(
            model: "qwen2.5:7b",
            reasoning: "future-value"
        )
        expect(unknownReasoning["reasoning_effort"] == nil, "request: unknown reasoning values must be omitted")
    }
}
