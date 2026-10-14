import Testing
import Foundation
@testable import PhotoVaultCore

/// Scans can be stopped, and stopping loses nothing.
@Suite("Scan control", .serialized)
struct ScanControlTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    private func thumbCount(_ store: Store) async throws -> Int {
        try await store.items(scope: .all, filter: .all).filter(\.hasThumb).count
    }

    @Test func stoppingAScanKeepsWhatIsDoneAndTheNextScanFinishes() async throws {
        for i in 0..<12 { try vault.writeImage("p\(i).jpg", seed: Double(i) / 12) }
        let slow = Thumbnailer(photoConcurrency: 2, testDelayNanoseconds: 150_000_000)
        let store = try Store(root: vault.root, thumbnailer: slow)

        let scan = Task { try await store.scan(full: true) }
        try await Task.sleep(nanoseconds: 250_000_000)
        scan.cancel()
        let outcome = await scan.result
        #expect(throws: CancellationError.self) { try outcome.get() }

        let partial = try await thumbCount(store)
        #expect(partial < 12, "stopped part-way (\(partial) of 12 done)")
        let all = try await store.items(scope: .all, filter: .all)
        #expect(all.count == 12, "every file was still recorded")
        let noneBadged = all.allSatisfy(\.playable)
        #expect(noneBadged, "a stopped scan must not badge anything as broken")
        await store.close()

        let resumed = try Store(root: vault.root)
        try await resumed.scan()
        #expect(try await thumbCount(resumed) == 12, "the next scan finishes the job")
        await resumed.close()
    }

    /// Quitting mid-scan: close() stops the scan and waits for it, so the
    /// catalog is never closed underneath it — and it still closes cleanly.
    @Test func closingDuringAScanWaitsForItAndClosesCleanly() async throws {
        for i in 0..<8 { try vault.writeImage("p\(i).jpg", seed: Double(i) / 8) }
        let store = try Store(root: vault.root, thumbnailer: Thumbnailer(photoConcurrency: 2, testDelayNanoseconds: 200_000_000))
        let scan = Task { try await store.scan(full: true) }
        try await Task.sleep(nanoseconds: 150_000_000)

        let started = ContinuousClock.now
        await store.close()
        #expect(ContinuousClock.now - started < .seconds(3), "close() stops the scan promptly rather than waiting it out")
        _ = await scan.result

        let reopened = try Store(root: vault.root)
        let needsFull = await reopened.needsFullScan()
        #expect(!needsFull, "recorded as a clean shutdown")
        await reopened.close()
    }

    @Test func aClosedStoreRefusesToScan() async throws {
        let store = try Store(root: vault.root)
        await store.close()
        await #expect(throws: CancellationError.self) { try await store.scan() }
    }

    /// Until 1.2.0 the thumbnailer ran one decode at a time despite its
    /// concurrency limit: decoding happened inside the actor, which runs one
    /// call at a time. Eight photos with 200 ms of thread-holding work each take
    /// 1.6 s one at a time; four at a time, about 0.4 s. (An awaitable sleep
    /// wouldn't show the bug — the actor lets calls overlap while one sleeps.)
    @Test func thumbnailsAreBuiltInParallel() async throws {
        for i in 0..<8 { try vault.writeImage("p\(i).jpg", seed: Double(i) / 8) }
        let store = try Store(root: vault.root, thumbnailer: Thumbnailer(photoConcurrency: 4, testBusyMicroseconds: 200_000))
        let started = ContinuousClock.now
        try await store.scan(full: true)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .milliseconds(1100), "took \(elapsed); one at a time would be over 1.6 s")
        #expect(try await thumbCount(store) == 8)
        await store.close()
    }
}
