import Foundation

/// Readium can replace a web view during reflow. A JavaScript callback from the
/// old view must neither lock the controls forever nor become a newer capture.
@MainActor enum ReaderCaptureDeadline {
    static func evaluate<Value>(timeout: Duration = .seconds(8), operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let race = CaptureRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                guard !race.finished else { return }
                race.work = Task { @MainActor [weak race] in
                    do { let value = try await operation(); race?.finish(.success(value)) }
                    catch { race?.finish(.failure(error)) }
                }
                race.deadline = Task { @MainActor [weak race] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    race?.finish(.failure(BookError.message("The reader page stopped responding. Close Read aloud, reopen the chapter from Contents, then try again.")))
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor private final class CaptureRace<Value> {
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    var work: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var finished: Bool { result != nil }
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        if let result { continuation.resume(with: result) }
        else { self.continuation = continuation }
    }
    func finish(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result); continuation = nil
        work?.cancel(); deadline?.cancel(); work = nil; deadline = nil
    }
}
