import Combine
import Foundation

/// Carries a value across to the main thread without checking that it can be sent; the engine's
/// values are only read there once they arrive.
private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

extension Publisher where Failure == Never {
    /// Like `sink`, but the closure always runs on the main actor. AetherEngine publishes from
    /// its own queues as well as from the main thread. A closure written inside a main-actor
    /// type is main-actor isolated, and Swift 6 stops the app if one runs anywhere else. A value
    /// sent on the main thread is delivered at once, so the player keeps up frame for frame.
    /// Any other value is queued for the main thread.
    func sinkOnMain(_ receive: @escaping @MainActor (Output) -> Void) -> AnyCancellable {
        let receive = Unchecked(value: receive)
        return sink { output in
            if Thread.isMainThread {
                MainActor.assumeIsolated { receive.value(output) }
            } else {
                let box = Unchecked(value: output)
                DispatchQueue.main.async { receive.value(box.value) }
            }
        }
    }
}
