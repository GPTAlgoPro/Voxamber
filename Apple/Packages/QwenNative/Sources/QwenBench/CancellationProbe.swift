import Foundation
import CreationCore
import QwenNative

/// One real, bounded Mac cancellation lifecycle regression. No generated content is logged.
enum CancellationProbe {
    private struct Outcome: Sendable {
        let status: String
        let ended: ContinuousClock.Instant
    }

    static func run(modelDirectory: URL, reportURL: URL) async throws {
        let engine = QwenEngine()
        try await engine.load(modelDirectory: modelDirectory)
        let (firstTokens, firstContinuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let generation = Task(priority: .userInitiated) { () -> Outcome in
            defer { firstContinuation.finish() }
            do {
                _ = try await engine.generateJSON(systemPrompt: ScenePrompt.system,
                    prompt: ScenePrompt.userRequest("生成一个由十个以上部件组成的蓝色机器人，包含头、身体、四肢、双眼和关节，返回完整JSON。"),
                    maxTokens: 3072, onProgress: { progress in
                        if let first = progress.firstTokenSeconds {
                            firstContinuation.yield(first)
                            firstContinuation.finish()
                        }
                    })
                return Outcome(status: "completed_before_cancel", ended: .now)
            } catch is CancellationError {
                return Outcome(status: "cancelled", ended: .now)
            } catch {
                return Outcome(status: "error: " + error.localizedDescription, ended: .now)
            }
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            firstContinuation.finish()
        }
        var iterator = firstTokens.makeAsyncIterator()
        let firstTokenSeconds = await iterator.next()
        timeout.cancel()
        let cancelledAt = ContinuousClock.now
        generation.cancel()
        // Intentionally unload before awaiting the caller task: exercise the real cancellation race.
        await engine.unload()
        let unloadedAt = ContinuousClock.now
        let afterUnload = engine.memorySnapshot()
        var reloadError: String?
        let reloadBegan = ContinuousClock.now
        do { try await engine.load(modelDirectory: modelDirectory) }
        catch { reloadError = error.localizedDescription }
        let reloadedAt = ContinuousClock.now
        let outcome = await generation.value
        var followupValid = false
        var followupError: String?
        if reloadError == nil {
            do {
                let value = try await engine.generateJSON(systemPrompt: "只返回JSON对象。", prompt: "返回ok为true。", maxTokens: 32)
                followupValid = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) is [String: Any]
            } catch { followupError = error.localizedDescription }
        }
        await engine.unload()
        let finalMemory = engine.memorySnapshot()
        let stopSeconds = seconds(cancelledAt.duration(to: outcome.ended))
        let unloadSeconds = seconds(cancelledAt.duration(to: unloadedAt))
        let passed = firstTokenSeconds != nil && outcome.status == "cancelled" && reloadError == nil
            && followupValid && stopSeconds < 3 && unloadSeconds < 3
        let report: [String: Any] = [
            "scope": "Mac real first-token cancellation -> immediate unload -> reload -> follow-up JSON; no UI-label assertions or phone operations",
            "passed": passed, "firstTokenObserved": firstTokenSeconds != nil,
            "firstTokenSeconds": firstTokenSeconds ?? -1, "generationOutcome": outcome.status,
            "cancelToGenerationSettledSeconds": stopSeconds, "cancelToUnloadSeconds": unloadSeconds,
            "reloadSeconds": seconds(reloadBegan.duration(to: reloadedAt)), "reloadError": reloadError ?? "",
            "followupJSONValid": followupValid, "followupError": followupError ?? "",
            "activeBytesAfterUnload": afterUnload.activeBytes, "activeBytesAfterFinalUnload": finalMemory.activeBytes,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        print("Cancellation regression: \(passed ? "PASS" : "FAIL"), stop=\(stopSeconds)s unload=\(unloadSeconds)s reload=\(reloadError == nil ? "PASS" : "FAIL")")
    }

    private static func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }
}
