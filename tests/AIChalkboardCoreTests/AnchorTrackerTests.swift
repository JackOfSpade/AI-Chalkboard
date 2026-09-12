import XCTest
@testable import AIChalkboardCore

/// Regression suite for `AnchorTracker`'s per-tick sampling/cadence/element
/// re-resolve state machine.
///
/// Every test injects a fake `TargetWindowSampling`, a fake `() -> Date`
/// clock, and (where needed) a fake `AnchorElementResolving` -- no live
/// window, no Screen Recording/Accessibility permission required. Every test
/// also sets `tracker.testDisableRealTimer = true` BEFORE the tracker is
/// wired to a non-empty store: see that property's doc comment for why a
/// real `DispatchSourceTimer` firing on the actual wall clock, in parallel
/// with this suite's deterministic `testOnlyTick()` calls, would make
/// "sampled exactly once" assertions flaky. Every tick is driven explicitly
/// through `testOnlyTick()`, advancing the fake clock between calls instead
/// of waiting on real time.
final class AnchorTrackerTests: XCTestCase {

    // MARK: - Fixtures

    private static let screenId = "main"
    private static let activeIntervalMs = Int((1.0 / 30.0 * 1000).rounded())

    private func fixtureScreens() -> [ScreenInfo] {
        let frame = ScreenCoordinateRect(x: 0, y: 0, width: 4_000, height: 3_000)
        return [
            ScreenInfo(
                id: Self.screenId, index: 0, name: Self.screenId,
                widthPx: Int(frame.width), heightPx: Int(frame.height),
                widthPt: frame.width, heightPt: frame.height,
                backingScaleFactor: 1, isMain: true,
                appKitFrame: frame, windowServerFrame: frame, displayID: 1
            )
        ]
    }

    /// Two connected displays with DIFFERENT backing densities -- the
    /// cross-density drag scenario the `.pin` compensation exists for. The
    /// tracker only reads `id` and `backingScaleFactor` from these; the
    /// frames just need to be plausible and non-overlapping.
    private func mixedDensityScreens() -> [ScreenInfo] {
        let retinaFrame = ScreenCoordinateRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let externalFrame = ScreenCoordinateRect(x: 1_600, y: 0, width: 2_000, height: 1_200)
        return [
            ScreenInfo(
                id: "retina", index: 0, name: "retina",
                widthPx: 3_200, heightPx: 2_000,
                widthPt: retinaFrame.width, heightPt: retinaFrame.height,
                backingScaleFactor: 2, isMain: true,
                appKitFrame: retinaFrame, windowServerFrame: retinaFrame, displayID: 1
            ),
            ScreenInfo(
                id: "external", index: 1, name: "external",
                widthPx: 2_000, heightPx: 1_200,
                widthPt: externalFrame.width, heightPt: externalFrame.height,
                backingScaleFactor: 1, isMain: false,
                appKitFrame: externalFrame, windowServerFrame: externalFrame, displayID: 2
            )
        ]
    }

    private func makeTarget(windowId: UInt64 = 1, processId: Int64 = 100) -> AnchorWindowTarget {
        AnchorWindowTarget(processId: processId, windowId: windowId, appId: "com.example.app")
    }

    private func windowSample(
        windowId: UInt64 = 1, processId: Int64 = 100, frame: CGRect,
        screenId: String = screenId, isOnScreen: Bool = true
    ) -> TargetWindowSample {
        TargetWindowSample(windowId: windowId, processId: processId, frame: frame, screenId: screenId, isOnScreen: isOnScreen)
    }

    private func windowAnchor(
        target: AnchorWindowTarget, referenceFrame: CGRect,
        resize: AnchorResizeBehavior = .pin, referenceScreenId: String = screenId
    ) -> AnnotationAnchor {
        AnnotationAnchor(mode: .window, resize: resize, target: target,
                        referenceWindowFrame: AnchorRect(referenceFrame), referenceScreenId: referenceScreenId)
    }

    private func elementSpec(label: String = "OK") -> AnchorElementSpec {
        AnchorElementSpec(label: label, role: nil, matchMode: "exact", occurrence: 1,
                          maxNodes: 100, timeoutSeconds: 5, shape: "rect", paddingPx: 4)
    }

    private func elementAnchor(
        target: AnchorWindowTarget, referenceFrame: CGRect,
        resize: AnchorResizeBehavior = .pin, referenceScreenId: String = screenId,
        spec: AnchorElementSpec
    ) -> AnnotationAnchor {
        AnnotationAnchor(mode: .element, resize: resize, target: target,
                        referenceWindowFrame: AnchorRect(referenceFrame), referenceScreenId: referenceScreenId, element: spec)
    }

    /// `anchorProjection` is pre-populated with an identity `.tracking`
    /// projection at the reference frame, matching what the design contract
    /// says the (out-of-scope-here) MCP draw-request layer installs in the
    /// SAME store write as the anchor itself -- an `Annotation` built by hand
    /// with no projection at all is a test-only shape `AnnotationStore`
    /// itself never produces.
    private func makeAnnotation(
        id: String = UUID().uuidString, anchor: AnnotationAnchor, kind: AnnotationKind? = nil,
        staticAdjustment: AnchorAdjustment = .identity,
        at sampledAt: Date = Date(timeIntervalSince1970: 0)
    ) -> Annotation {
        let projection = AnchorProjection(
            state: .tracking, adjustment: .identity, effectiveScreenId: anchor.referenceScreenId,
            currentWindowFrame: anchor.referenceWindowFrame, sampledAt: sampledAt, elementResolutionIssue: nil
        )
        return Annotation(
            id: id, screenId: anchor.referenceScreenId,
            kind: kind ?? .vectorPath(
                data: "M0 0 L1 1", strokeColorHex: "#FF0000", strokeWidth: 2, strokeOpacity: 1,
                fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
                coordinateScaleX: 1, coordinateScaleY: 1
            ),
            anchor: anchor, staticAdjustment: staticAdjustment, anchorProjection: projection
        )
    }

    // MARK: - Fakes

    /// Records how many times each windowId was sampled, so tests can assert
    /// "several annotations sharing one target sample it exactly once."
    /// Guarded by a lock even though every access in this suite is already
    /// serialized through `AnchorTracker`'s own queue discipline (a tick is
    /// always awaited via `testOnlyTick()`/`testOnlyFlush()` before the test
    /// thread reads a call count), purely as defense in depth.
    private final class FakeProbe: TargetWindowSampling, @unchecked Sendable {
        private let lock = NSLock()
        private var callCounts: [UInt64: Int] = [:]
        private var results: [UInt64: TargetWindowSample?] = [:]

        func setResult(_ sample: TargetWindowSample?, for windowId: UInt64) {
            lock.lock(); results[windowId] = sample; lock.unlock()
        }

        func callCount(for windowId: UInt64) -> Int {
            lock.lock(); defer { lock.unlock() }
            return callCounts[windowId] ?? 0
        }

        func window(id: UInt64, processId: Int64, screens: [ScreenInfo]) -> TargetWindowSample? {
            lock.lock()
            callCounts[id, default: 0] += 1
            let result = results[id] ?? nil
            lock.unlock()
            return result
        }

        func windows(forProcessId processId: Int64, screens: [ScreenInfo]) -> [TargetWindowSample] {
            [] // AnchorTracker only ever calls window(id:processId:screens:).
        }
    }

    /// A clock any queue can read/advance safely. Tests advance it between
    /// `testOnlyTick()` calls to drive cadence/debounce/rate-limit math
    /// deterministically, with no real sleeping.
    private final class FakeClock {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(by seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    }

    private final class FakeElementResolver: AnchorElementResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0
        private var _result: AnchorElementReresolution

        init(result: AnchorElementReresolution) { _result = result }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

        func setResult(_ result: AnchorElementReresolution) {
            lock.lock(); _result = result; lock.unlock()
        }

        func reresolve(annotation: Annotation, spec: AnchorElementSpec, target: AnchorWindowTarget,
                       screens: [ScreenInfo]) -> AnchorElementReresolution {
            lock.lock()
            _callCount += 1
            let result = _result
            lock.unlock()
            return result
        }
    }

    /// A resolver whose walk BLOCKS until the test releases it -- the
    /// deterministic stand-in for a slow AX traversal, so a test can move
    /// the window (and run sampling ticks) WHILE a resolve is provably still
    /// in flight, then let it finish. `release()` must be called exactly
    /// once per expected `reresolve` call, and always BEFORE
    /// `testOnlyWaitForElementQueueIdle()` (which would otherwise deadlock
    /// behind the blocked walk).
    private final class GatedElementResolver: AnchorElementResolving, @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _callCount = 0
        private var _result: AnchorElementReresolution

        init(result: AnchorElementReresolution) { _result = result }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

        func setResult(_ result: AnchorElementReresolution) {
            lock.lock(); _result = result; lock.unlock()
        }

        func release() { gate.signal() }

        /// Blocks (bounded) until `reresolve` has actually been ENTERED on
        /// `elementQueue`. The trigger tick only ENQUEUES the walk, so a
        /// test asserting `callCount` straight after the tick would race
        /// the queue; waiting here makes the assertion deterministic.
        @discardableResult
        func awaitWalkStart(timeout: TimeInterval = 5) -> Bool {
            entered.wait(timeout: .now() + timeout) == .success
        }

        func reresolve(annotation: Annotation, spec: AnchorElementSpec, target: AnchorWindowTarget,
                       screens: [ScreenInfo]) -> AnchorElementReresolution {
            lock.lock()
            _callCount += 1
            lock.unlock()
            entered.signal()
            gate.wait()
            lock.lock()
            let result = _result
            lock.unlock()
            return result
        }
    }

    /// Thread-safe tally for `AnnotationStore.onStoreChanged` firings, so a
    /// test can assert exactly how many repaint-driving notifications one
    /// operation produced.
    private final class ChangeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func increment() { lock.lock(); _count += 1; lock.unlock() }
    }

    // MARK: - Test-double wiring helper

    /// Builds a tracker with the real timer disabled and, when `store`
    /// already has anchors installed via `preInstalled`, adds them AFTER the
    /// real-timer flag is set -- see `testDisableRealTimer`'s doc comment for
    /// why the ordering matters (the flag must be visible on `samplingQueue`
    /// before `store.add` can enqueue any work that reads it).
    private func makeTracker(
        store: AnnotationStore, probe: TargetWindowSampling, clock: FakeClock,
        elementResolver: AnchorElementResolving? = nil,
        appIdentity: ((Int64) -> String?)? = nil,
        screens: [ScreenInfo]? = nil
    ) -> AnchorTracker {
        let snapshot = screens
        let tracker = AnchorTracker(
            store: store, probe: probe,
            screens: { [weak self] in snapshot ?? self?.fixtureScreens() ?? [] },
            elementResolver: elementResolver, now: clock.now, appIdentity: appIdentity
        )
        tracker.testDisableRealTimer = true
        return tracker
    }

    // MARK: - Move / resize

    func testMoveUnderPinTranslatesWithoutScaling() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 100, y: 100, width: 200, height: 150), resize: .pin)
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 150, y: 220, width: 200, height: 150)), for: tgt.windowId)
        tracker.testOnlyTick()

        let updated = store.get(id: ann.id)!
        XCTAssertEqual(updated.anchorProjection?.state, .tracking)
        XCTAssertEqual(updated.anchorProjection?.adjustment, AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 50, translateY: 120))
    }

    func testResizeUnderPinKeepsScaleOneAndFollowsTopLeft() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 100, y: 100, width: 200, height: 150), resize: .pin)
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        // Both moves AND grows -- pin must still report scale 1/1.
        probe.setResult(windowSample(frame: CGRect(x: 120, y: 130, width: 500, height: 400)), for: tgt.windowId)
        tracker.testOnlyTick()

        let adjustment = store.get(id: ann.id)!.anchorProjection!.adjustment
        XCTAssertEqual(adjustment, AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 20, translateY: 30))
    }

    func testResizeUnderScaleScalesPerAxisAndTranslates() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 50), resize: .scale)
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 50, y: 50, width: 200, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick()

        let adjustment = store.get(id: ann.id)!.anchorProjection!.adjustment
        XCTAssertEqual(adjustment, AnchorAdjustment(scaleX: 2, scaleY: 2, translateX: 50, translateY: 50))
    }

    func testNilMappingKeepsPreviousAdjustmentAndStaysTracking() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        // Zero-width reference under `.scale` makes `AnchorAdjustment.mapping`
        // return nil unconditionally (see that function's own guard).
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 0, height: 100), resize: .scale)
        var ann = makeAnnotation(anchor: anchor)
        let priorAdjustment = AnchorAdjustment(scaleX: 2, scaleY: 3, translateX: 5, translateY: 7)
        ann.anchorProjection = AnchorProjection(
            state: .tracking, adjustment: priorAdjustment, effectiveScreenId: Self.screenId,
            currentWindowFrame: anchor.referenceWindowFrame, sampledAt: clock.now(), elementResolutionIssue: nil
        )
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 10, y: 10, width: 50, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick()

        let updated = store.get(id: ann.id)!.anchorProjection!
        XCTAssertEqual(updated.state, .tracking, "an unmappable frame must never demote a still-present window out of .tracking")
        XCTAssertEqual(updated.adjustment, priorAdjustment, "a nil mapping result must hold the previous adjustment, never fall back to identity")
    }

    // MARK: - Pin across backing densities

    func testPinAcrossDisplaysCompensatesBackingScaleDensity() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock, screens: mixedDensityScreens())

        let tgt = makeTarget()
        // 400x300 pt window at pt(50,50) on the 2x display: reference frame
        // (100,100,800,600) in retina backing pixels.
        let anchor = windowAnchor(
            target: tgt, referenceFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            resize: .pin, referenceScreenId: "retina"
        )
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        // Same window dragged onto the 1x display: (300,200,400,300) in
        // external backing pixels.
        probe.setResult(
            windowSample(frame: CGRect(x: 300, y: 200, width: 400, height: 300), screenId: "external"),
            for: tgt.windowId
        )
        tracker.testOnlyTick()

        let projection = store.get(id: ann.id)!.anchorProjection!
        XCTAssertEqual(projection.state, .tracking)
        XCTAssertEqual(projection.effectiveScreenId, "external")
        XCTAssertEqual(
            projection.adjustment,
            AnchorAdjustment(scaleX: 0.5, scaleY: 0.5, translateX: 250, translateY: 150),
            "pin across 2x -> 1x must scale by the density ratio, not translate raw pixel deltas"
        )

        // A ring centre stored at in-window offset (200pt,150pt) --
        // (400,300) px from the 2x window origin, absolute (500,400) -- must
        // keep that in-window POINT offset on the 1x display: absolute
        // (500,350). The old translate-only mapping painted it at in-window
        // (400,300) pt and at double the intended size.
        let painted = projection.adjustment.apply(to: CGPoint(x: 500, y: 400))
        XCTAssertEqual(painted, CGPoint(x: 500, y: 350),
                       "the in-window point offset must be invariant across the density change")
        // "Size doubles in neither direction": extents shrink by exactly the
        // density ratio (40 px on 2x == 20 pt == 20 px on 1x), so the
        // on-screen POINT size is unchanged.
        XCTAssertEqual(projection.adjustment.scaleX, 0.5)
        XCTAssertEqual(projection.adjustment.scaleY, 0.5)
    }

    func testPinFallsBackToDensityBlindMappingWhenReferenceScreenIsGone() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock, screens: mixedDensityScreens())

        let tgt = makeTarget()
        // The reference display is no longer in the snapshot AND the anchor
        // never recorded its scale -- the one case where the stored pixel
        // density is unknowable, documented to fall back to the legacy
        // translate-only mapping.
        let anchor = windowAnchor(
            target: tgt, referenceFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            resize: .pin, referenceScreenId: "unplugged"
        )
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(
            windowSample(frame: CGRect(x: 300, y: 200, width: 400, height: 300), screenId: "external"),
            for: tgt.windowId
        )
        tracker.testOnlyTick()

        XCTAssertEqual(
            store.get(id: ann.id)!.anchorProjection!.adjustment,
            AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 200, translateY: 100),
            "an unresolvable reference density must degrade to the pre-density behavior, never invent a scale"
        )
    }

    func testPinAcrossDisplaysUsesTheRecordedReferenceScaleWhenTheReferenceScreenIsGone() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock, screens: mixedDensityScreens())

        let tgt = makeTarget()
        // Reference display disconnected, but its 2x density WAS recorded at
        // anchor (re-)baseline time -- the recorded value must win, keeping
        // the compensation correct with the display gone.
        let anchor = AnnotationAnchor(
            mode: .window, resize: .pin, target: tgt,
            referenceWindowFrame: AnchorRect(CGRect(x: 100, y: 100, width: 800, height: 600)),
            referenceScreenId: "unplugged", referenceScreenScale: 2
        )
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(
            windowSample(frame: CGRect(x: 300, y: 200, width: 400, height: 300), screenId: "external"),
            for: tgt.windowId
        )
        tracker.testOnlyTick()

        XCTAssertEqual(
            store.get(id: ann.id)!.anchorProjection!.adjustment,
            AnchorAdjustment(scaleX: 0.5, scaleY: 0.5, translateX: 250, translateY: 150)
        )
    }

    // MARK: - Hidden / lost / recycled

    func testWindowFoundButOffscreenReportsHiddenAndKeepsAdjustment() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 40, y: 40, width: 100, height: 100), isOnScreen: false), for: tgt.windowId)
        tracker.testOnlyTick()

        let projection = store.get(id: ann.id)!.anchorProjection!
        XCTAssertEqual(projection.state, .hidden)
        XCTAssertEqual(projection.adjustment, .identity, "hidden must keep the last adjustment, not recompute one")
        XCTAssertEqual(projection.currentWindowFrame?.cgRect, CGRect(x: 40, y: 40, width: 100, height: 100))
    }

    func testOneAndTwoConsecutiveAbsencesStayHidden() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann) // probe has no result installed => every sample is an absence (nil)

        tracker.testOnlyTick()
        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .hidden, "1 absence must not lose the window")

        tracker.testOnlyTick()
        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .hidden, "2 absences must not lose the window")
    }

    func testThirdConsecutiveAbsenceBecomesLostAndStopsPollingAndTimer() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        tracker.testOnlyTick() // absence 1 -> hidden
        tracker.testOnlyTick() // absence 2 -> hidden
        tracker.testOnlyTick() // absence 3 -> lost
        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .lost)
        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.currentWindowFrame, nil)
        XCTAssertEqual(probe.callCount(for: tgt.windowId), 3)

        // A target already `.lost` must never be sampled again, and an
        // all-lost anchored set must stop the timer exactly like an empty one.
        tracker.testOnlyTick()
        XCTAssertEqual(probe.callCount(for: tgt.windowId), 3, "a permanently lost target must not be sampled again")
        XCTAssertFalse(tracker.statusSummary().isRunning, "an all-lost anchored set must stop polling")
    }

    func testRecycledWindowIdIsIndistinguishableFromAnyOtherAbsenceAndEventuallyLost() {
        // The probe itself is responsible for rejecting a recycled window id
        // (a different pid now owns that number) by returning nil -- covered
        // separately in TargetWindowProbeTests. From AnchorTracker's side,
        // that failure mode is just another absence, subject to the same
        // 3-consecutive-absence threshold as a closed window.
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget(windowId: 42, processId: 100)
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)
        // No result ever installed for windowId 42 -> the probe reports nil
        // on every sample, simulating the id now belonging to a different pid.

        tracker.testOnlyTick()
        tracker.testOnlyTick()
        tracker.testOnlyTick()
        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .lost)
    }

    func testSuccessAfterTwoAbsencesResetsTheCounter() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        tracker.testOnlyTick() // absence 1 -> hidden
        tracker.testOnlyTick() // absence 2 -> hidden

        probe.setResult(windowSample(frame: CGRect(x: 0, y: 0, width: 100, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick() // success -> tracking, counter resets to 0
        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .tracking)

        probe.setResult(nil, for: tgt.windowId)
        tracker.testOnlyTick() // one more absence: must be treated as absence #1, not #3
        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .hidden,
                       "a successful sample must reset the absence counter, so the very next absence must not immediately lose the window")
    }

    // MARK: - A `.lost` verdict must not poison a later, unrelated anchor
    //
    // Demonstrated repro this covers: anchor A to target T; drive 3 absences
    // so T is `.lost` (A stays in the store, per the no-auto-clear rule);
    // then add a NEW annotation B anchored to the SAME T with a healthy
    // probe result now available. Before the fix, T was never sampled
    // again, B kept its stale creation-time `.tracking` projection forever,
    // and the sampling timer stopped outright (`allLost` was satisfied by
    // both annotations, even though B was never actually sampled). The fix
    // resets `lostTargets`/`targetAbsenceCounts` in `handleAnchoredSetChanged`
    // whenever the anchored set changes, so the very next tick re-derives
    // both A's and B's state from live evidence.

    func testNewAnnotationOnAPreviouslyLostTargetIsSampledAndRecoversBothAnnotations() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget(windowId: 7, processId: 200)
        let anchorA = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let annA = makeAnnotation(anchor: anchorA)
        store.add(annA)

        // Drive T to `.lost`: 3 consecutive absences (no probe result
        // installed for windowId 7 yet), matching
        // `testThirdConsecutiveAbsenceBecomesLostAndStopsPollingAndTimer`.
        tracker.testOnlyTick()
        tracker.testOnlyTick()
        tracker.testOnlyTick()
        XCTAssertEqual(store.get(id: annA.id)!.anchorProjection!.state, .lost)
        XCTAssertFalse(tracker.statusSummary().isRunning, "an all-lost anchored set must stop polling")
        XCTAssertEqual(probe.callCount(for: tgt.windowId), 3)

        // The window was never actually gone -- e.g. it sat off every
        // connected display for 3 ticks (a monitor unplug/reconfiguration)
        // -- so a healthy sample is available again by the time a second
        // annotation gets anchored to the SAME target.
        probe.setResult(windowSample(frame: CGRect(x: 5, y: 5, width: 100, height: 100)), for: tgt.windowId)

        let anchorB = windowAnchor(target: tgt, referenceFrame: CGRect(x: 5, y: 5, width: 100, height: 100))
        let annB = makeAnnotation(anchor: anchorB)
        store.add(annB) // fires onAnchoredSetChanged -> handleAnchoredSetChanged
        tracker.testOnlyFlush() // wait for that async reset + ensureTimer to land

        XCTAssertTrue(tracker.statusSummary().isRunning,
                      "adding a new anchor to a previously all-lost set must restart the timer")

        tracker.testOnlyTick()

        XCTAssertGreaterThan(probe.callCount(for: tgt.windowId), 3,
                             "the target must be sampled again once the anchored set changes, not permanently skipped")
        XCTAssertEqual(store.get(id: annB.id)!.anchorProjection!.state, .tracking,
                       "the new annotation must get a live projection, not its stale creation-time one")
        XCTAssertEqual(store.get(id: annA.id)!.anchorProjection!.state, .tracking,
                       "the original annotation must also recover -- it was never actually stranded")
        XCTAssertTrue(tracker.statusSummary().isRunning, "two annotations, both now tracking, must keep the timer running")
    }

    func testRemovingAnAnnotationAlsoResetsLostBookkeepingForARemainingUnrelatedTarget() {
        // The reset in `handleAnchoredSetChanged` fires on ANY anchored-set
        // change, not just an add -- removing one anchored annotation while
        // a DIFFERENT one shares no target with it must still give a
        // separately-lost target a fresh chance next tick.
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let lostTarget = makeTarget(windowId: 1, processId: 100)
        let otherTarget = makeTarget(windowId: 2, processId: 100)
        let lostAnchor = windowAnchor(target: lostTarget, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let otherAnchor = windowAnchor(target: otherTarget, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let lostAnnotation = makeAnnotation(anchor: lostAnchor)
        let otherAnnotation = makeAnnotation(anchor: otherAnchor)
        store.add(lostAnnotation)
        store.add(otherAnnotation)

        probe.setResult(windowSample(frame: CGRect(x: 0, y: 0, width: 100, height: 100)), for: otherTarget.windowId)
        tracker.testOnlyTick() // absence 1 for lostTarget; otherTarget tracking
        tracker.testOnlyTick() // absence 2
        tracker.testOnlyTick() // absence 3 -> lostTarget becomes .lost
        XCTAssertEqual(store.get(id: lostAnnotation.id)!.anchorProjection!.state, .lost)
        XCTAssertEqual(probe.callCount(for: lostTarget.windowId), 3)

        // Remove the OTHER annotation (unrelated to the lost one) -- the set
        // still changed, so the reset must still fire.
        _ = store.remove(id: otherAnnotation.id)
        tracker.testOnlyFlush()

        probe.setResult(windowSample(frame: CGRect(x: 1, y: 1, width: 100, height: 100)), for: lostTarget.windowId)
        tracker.testOnlyTick()

        XCTAssertGreaterThan(probe.callCount(for: lostTarget.windowId), 3,
                             "removing an unrelated annotation must still reset lost bookkeeping, giving the remaining lost target a fresh chance")
        XCTAssertEqual(store.get(id: lostAnnotation.id)!.anchorProjection!.state, .tracking)
    }

    // MARK: - Display reconfiguration must not leave a live window .lost

    func testDisplayReconfigurationResetsLostVerdictsAndResumesTracking() {
        // A monitor unplug/rearrange makes a live window unmappable onto any
        // connected display for the duration of the reconfiguration -- at
        // the .active cadence, easily 3 consecutive nil samples, i.e. a
        // false `.lost`. `handleDisplayReconfiguration()` (wired to
        // NSApplication.didChangeScreenParametersNotification in production;
        // called directly here, since tests must not post AppKit
        // notifications) must clear the verdict and restart polling so the
        // window is re-acquired the moment the layout settles.
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        tracker.testOnlyTick() // absence 1 (mid-reconfiguration: no display can map the frame)
        tracker.testOnlyTick() // absence 2
        tracker.testOnlyTick() // absence 3 -> falsely .lost; all-lost set stops the timer
        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .lost)
        XCTAssertFalse(tracker.statusSummary().isRunning)
        XCTAssertEqual(probe.callCount(for: tgt.windowId), 3)

        // The layout settles: the window maps cleanly again.
        probe.setResult(windowSample(frame: CGRect(x: 5, y: 5, width: 100, height: 100)), for: tgt.windowId)

        tracker.handleDisplayReconfiguration()
        tracker.testOnlyFlush()
        XCTAssertTrue(tracker.statusSummary().isRunning,
                      "a display reconfiguration must restart polling for a store whose targets were all falsely lost")

        tracker.testOnlyTick()
        XCTAssertGreaterThan(probe.callCount(for: tgt.windowId), 3,
                             "the reconfiguration reset must make the target sampled again, not permanently skipped")
        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .tracking,
                       "a live window falsely lost across a reconfiguration must recover once the layout settles")
    }

    // MARK: - Recycled-pid guard (AnchorWindowTarget.appId)

    func testAppIdMismatchRejectsALiveLookingSampleAsARecycledPid() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        // The pid now resolves to a DIFFERENT app than the one recorded at
        // anchor time -- exactly the recycled-pid scenario `appId` exists to
        // catch, even though the probe's own geometry sample looks perfectly
        // live.
        let tracker = makeTracker(store: store, probe: probe, clock: clock, appIdentity: { _ in "com.different.app" })

        let tgt = makeTarget() // appId: "com.example.app"
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 0, y: 0, width: 100, height: 100)), for: tgt.windowId)

        tracker.testOnlyTick() // rejected sample #1 -> hidden
        tracker.testOnlyTick() // #2
        tracker.testOnlyTick() // #3 -> lost

        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .lost,
                       "a resolved appId that no longer matches the recorded one must be treated as a recycled pid, never a live match")
    }

    func testMatchingAppIdAllowsTrackingToProceedNormally() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock, appIdentity: { _ in "com.example.app" })

        let tgt = makeTarget() // appId: "com.example.app"
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 0, y: 0, width: 100, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick()

        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .tracking,
                       "a resolved appId that matches the recorded one must not block tracking")
    }

    func testNilRecordedAppIdSkipsTheIdentityCheckEntirely() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        // Would reject every target if the check ran unconditionally.
        let tracker = makeTracker(store: store, probe: probe, clock: clock, appIdentity: { _ in "com.whatever.app" })

        let tgt = AnchorWindowTarget(processId: 100, windowId: 1, appId: nil)
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 0, y: 0, width: 100, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick()

        XCTAssertEqual(store.get(id: ann.id)!.anchorProjection!.state, .tracking,
                       "a target with no recorded appId must never be rejected by the identity check")
    }

    // MARK: - Batching

    func testAnnotationsSharingOneTargetAreSampledExactlyOnce() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor1 = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let anchor2 = windowAnchor(target: tgt, referenceFrame: CGRect(x: 10, y: 10, width: 50, height: 50))
        let ann1 = makeAnnotation(anchor: anchor1)
        let ann2 = makeAnnotation(anchor: anchor2)
        store.add(ann1)
        store.add(ann2)

        probe.setResult(windowSample(frame: CGRect(x: 20, y: 20, width: 100, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick()

        XCTAssertEqual(probe.callCount(for: tgt.windowId), 1, "two annotations sharing one target must sample it exactly once per tick")
        XCTAssertEqual(store.get(id: ann1.id)!.anchorProjection!.state, .tracking)
        XCTAssertEqual(store.get(id: ann2.id)!.anchorProjection!.state, .tracking)
    }

    // MARK: - Cadence

    func testCadenceEscalatesThenSettlesThenIdlesThenResetsOnChange() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 10, y: 10, width: 100, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick() // a real change -> active
        XCTAssertEqual(tracker.statusSummary().sampleIntervalMs, Self.activeIntervalMs)

        // Same sample every subsequent tick: no further observed change.
        clock.advance(by: 2.0) // 2s since the change: past the 1s active window
        tracker.testOnlyTick()
        XCTAssertEqual(tracker.statusSummary().sampleIntervalMs, 250, "no change for >1s must settle to 250ms")

        clock.advance(by: 9.0) // 11s since the change: past the 10s settled window
        tracker.testOnlyTick()
        XCTAssertEqual(tracker.statusSummary().sampleIntervalMs, 1000, "no change for >10s must idle to 1000ms")

        probe.setResult(windowSample(frame: CGRect(x: 20, y: 20, width: 100, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick() // a fresh observed change resets to active
        XCTAssertEqual(tracker.statusSummary().sampleIntervalMs, Self.activeIntervalMs)
    }

    func testTimerStopsWhenLastAnchoredAnnotationIsCleared() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)

        let tgt = makeTarget()
        let anchor = windowAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)
        probe.setResult(windowSample(frame: CGRect(x: 0, y: 0, width: 100, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick()
        XCTAssertTrue(tracker.statusSummary().isRunning)

        _ = store.remove(id: ann.id)
        tracker.testOnlyFlush() // wait for AnnotationStore.onAnchoredSetChanged's async stop()
        XCTAssertFalse(tracker.statusSummary().isRunning)
    }

    func testNoTimerRunsWhileNothingIsAnchored() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let tracker = makeTracker(store: store, probe: probe, clock: clock)
        tracker.testOnlyFlush()
        XCTAssertFalse(tracker.statusSummary().isRunning, "no anchored annotation must mean no timer at all")
        XCTAssertEqual(probe.callCount(for: 1), 0)
    }

    // MARK: - Element re-resolve

    func testElementReresolveWaitsForTheFullSettleDebounce() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let resolver = FakeElementResolver(result: .issue("not_found"))
        let tracker = makeTracker(store: store, probe: probe, clock: clock, elementResolver: resolver)

        let tgt = makeTarget()
        let anchor = elementAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100), spec: elementSpec())
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        let movedFrame = CGRect(x: 10, y: 10, width: 100, height: 100)
        probe.setResult(windowSample(frame: movedFrame), for: tgt.windowId)
        tracker.testOnlyTick() // frame just changed -> settledFor == 0, must not trigger yet
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()
        XCTAssertEqual(resolver.callCount, 0)

        clock.advance(by: 0.25) // > 200ms settle delay, same frame
        tracker.testOnlyTick()
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testElementReresolveRateLimitBlocksARetryWithin500ms() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let resolver = FakeElementResolver(result: .issue("not_found"))
        let tracker = makeTracker(store: store, probe: probe, clock: clock, elementResolver: resolver)

        let tgt = makeTarget()
        let anchor = elementAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100), spec: elementSpec())
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        let frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        probe.setResult(windowSample(frame: frame), for: tgt.windowId)
        tracker.testOnlyTick() // t=0: first observation, no trigger

        clock.advance(by: 0.25) // t=0.25: settled -> attempt #1
        tracker.testOnlyTick()
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()
        XCTAssertEqual(resolver.callCount, 1)

        clock.advance(by: 0.25) // t=0.50: only 250ms since attempt #1 -> rate-limited
        tracker.testOnlyTick()
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()
        XCTAssertEqual(resolver.callCount, 1, "a retry inside the 500ms rate limit must be blocked")

        clock.advance(by: 0.30) // t=0.80: 550ms since attempt #1 -> eligible again
        tracker.testOnlyTick()
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()
        XCTAssertEqual(resolver.callCount, 2)
    }

    func testElementReresolveStopsAfterThreeConsecutiveFailuresAgainstAStableFrame() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let resolver = FakeElementResolver(result: .issue("unavailable"))
        let tracker = makeTracker(store: store, probe: probe, clock: clock, elementResolver: resolver)

        let tgt = makeTarget()
        let anchor = elementAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100), spec: elementSpec())
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        let frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        probe.setResult(windowSample(frame: frame), for: tgt.windowId)
        tracker.testOnlyTick() // t=0: first observation

        func attempt(afterAdvancing seconds: TimeInterval) {
            clock.advance(by: seconds)
            tracker.testOnlyTick()
            tracker.testOnlyWaitForElementQueueIdle()
            tracker.testOnlyFlush()
        }

        attempt(afterAdvancing: 0.25) // settled -> attempt #1 fails
        XCTAssertEqual(resolver.callCount, 1)
        attempt(afterAdvancing: 0.5) // rate limit clears -> attempt #2 fails
        XCTAssertEqual(resolver.callCount, 2)
        attempt(afterAdvancing: 0.5) // attempt #3 fails -> backoff engages
        XCTAssertEqual(resolver.callCount, 3)

        attempt(afterAdvancing: 0.5) // rate limit clears again, but backoff blocks it
        XCTAssertEqual(resolver.callCount, 3, "3 consecutive failures against an unchanged frame must stop further attempts")

        XCTAssertEqual(
            store.get(id: ann.id)!.anchorProjection?.elementResolutionIssue, "unavailable",
            "the last reason code must be recorded even while backed off"
        )
    }

    func testElementReresolveResumesAndCanSucceedAfterAFrameChangeFollowingBackoff() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let resolver = FakeElementResolver(result: .issue("unavailable"))
        let tracker = makeTracker(store: store, probe: probe, clock: clock, elementResolver: resolver)

        let tgt = makeTarget()
        let anchor = elementAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100), spec: elementSpec())
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        let frameA = CGRect(x: 10, y: 10, width: 100, height: 100)
        probe.setResult(windowSample(frame: frameA), for: tgt.windowId)

        func tick(afterAdvancing seconds: TimeInterval) {
            clock.advance(by: seconds)
            tracker.testOnlyTick()
            tracker.testOnlyWaitForElementQueueIdle()
            tracker.testOnlyFlush()
        }

        tick(afterAdvancing: 0)     // first observation
        tick(afterAdvancing: 0.25) // attempt #1 fails
        tick(afterAdvancing: 0.5)  // attempt #2 fails
        tick(afterAdvancing: 0.5)  // attempt #3 fails -> backoff engaged
        XCTAssertEqual(resolver.callCount, 3)

        // A new, settled frame -- plus a successful result -- must resume
        // and reset the failure count.
        let frameB = CGRect(x: 40, y: 40, width: 100, height: 100)
        probe.setResult(windowSample(frame: frameB), for: tgt.windowId)
        let newKind = AnnotationKind.vectorPath(
            data: "M5 5 L6 6", strokeColorHex: "#00FF00", strokeWidth: 3, strokeOpacity: 1,
            fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
            coordinateScaleX: 1, coordinateScaleY: 1
        )
        resolver.setResult(.resolved(kind: newKind, screenId: Self.screenId))

        tick(afterAdvancing: 0.1) // frame change observed -> resets failures, restarts debounce (not yet settled)
        XCTAssertEqual(resolver.callCount, 3, "a frame change alone must not itself trigger an attempt before the debounce elapses")

        // Settled against frameB (>= 200ms since the change above) AND past
        // the 500ms rate limit measured from attempt #3's start (t=1.25) --
        // both gates must clear before attempt #4 fires.
        tick(afterAdvancing: 0.45)
        XCTAssertEqual(resolver.callCount, 4)

        let updated = store.get(id: ann.id)!
        if case .vectorPath(let data, _, _, _, _, _, _, _, _, _) = updated.kind {
            XCTAssertEqual(data, "M5 5 L6 6")
        } else {
            XCTFail("a successful element re-resolve must replace the annotation's kind with the rebuilt one")
        }
        XCTAssertEqual(updated.anchor?.referenceWindowFrame.cgRect, frameB, "a successful resolve must re-baseline the reference frame")
        XCTAssertEqual(updated.anchor?.referenceScreenId, Self.screenId)
        XCTAssertEqual(updated.anchorProjection?.adjustment, .identity, "a successful resolve must reset the live adjustment to identity")
        XCTAssertNil(updated.anchorProjection?.elementResolutionIssue, "a successful resolve must clear any previously recorded issue")
    }

    // MARK: - Element re-resolve: success gate against a stationary window

    private static let resolvedKind = AnnotationKind.vectorPath(
        data: "M5 5 L6 6", strokeColorHex: "#00FF00", strokeWidth: 3, strokeOpacity: 1,
        fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
        coordinateScaleX: 1, coordinateScaleY: 1
    )

    func testElementReresolveDoesNotRepeatAfterSuccessWhileTheWindowStaysPut() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let resolver = FakeElementResolver(result: .resolved(kind: Self.resolvedKind, screenId: Self.screenId))
        let tracker = makeTracker(store: store, probe: probe, clock: clock, elementResolver: resolver)

        let tgt = makeTarget()
        let anchor = elementAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100), spec: elementSpec())
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 10, y: 10, width: 100, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick() // first observation

        clock.advance(by: 0.25)
        tracker.testOnlyTick() // settled -> attempt #1 succeeds and is applied
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()
        XCTAssertEqual(resolver.callCount, 1)

        let afterSuccess = store.get(id: ann.id)!
        let revisionAfterSuccess = afterSuccess.revision
        let projectionAfterSuccess = afterSuccess.anchorProjection

        // The window then sits perfectly still. Every 0.6 s advance clears
        // the 0.5 s rate limit again, `settledFor` only grows, and the
        // failure count is zero -- before the success gate, EVERY one of
        // these ticks re-ran a full AX tree walk plus two no-op store
        // writes, forever.
        for _ in 0..<5 {
            clock.advance(by: 0.6)
            tracker.testOnlyTick()
            tracker.testOnlyWaitForElementQueueIdle()
            tracker.testOnlyFlush()
        }
        XCTAssertEqual(resolver.callCount, 1,
                       "a resolved, stationary window must not be re-walked just because the rate limit re-armed")
        let later = store.get(id: ann.id)!
        XCTAssertEqual(later.revision, revisionAfterSuccess,
                       "no writes may land against a resolved, stationary window (a revision bump can spuriously stale a caller's CAS)")
        XCTAssertEqual(later.anchorProjection, projectionAfterSuccess,
                       "not even a fresh sampledAt may be written against a resolved, stationary window")

        // A REAL window change re-arms the gate: after it settles, exactly
        // one new resolve runs.
        probe.setResult(windowSample(frame: CGRect(x: 60, y: 80, width: 100, height: 100)), for: tgt.windowId)
        clock.advance(by: 0.6)
        tracker.testOnlyTick() // frame change observed -> gate lifted, debounce restarts
        clock.advance(by: 0.25)
        tracker.testOnlyTick() // settled again -> attempt #2
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()
        XCTAssertEqual(resolver.callCount, 2,
                       "a new frame change followed by a settle must lift the success gate")
    }

    // MARK: - Element re-resolve: no-op writes are skipped entirely

    func testElementReresolveSkipsTheStoreWriteWhenTheResolveReproducesStoredState() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let resolver = FakeElementResolver(result: .resolved(kind: Self.resolvedKind, screenId: Self.screenId))
        let tracker = makeTracker(store: store, probe: probe, clock: clock, elementResolver: resolver)

        let tgt = makeTarget()
        let anchor = elementAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100), spec: elementSpec())
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        let frameA = CGRect(x: 10, y: 10, width: 100, height: 100)
        probe.setResult(windowSample(frame: frameA), for: tgt.windowId)
        tracker.testOnlyTick() // first observation

        clock.advance(by: 0.25)
        tracker.testOnlyTick() // attempt #1: applied (kind replaced, anchor re-baselined to frameA)
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()
        XCTAssertEqual(resolver.callCount, 1)
        let revisionAfterFirstApply = store.get(id: ann.id)!.revision

        // Jiggle the window away and straight back without letting it
        // settle in between: two real frame changes (each lifts the success
        // gate) that leave the window EXACTLY where the applied resolve
        // already baselined it.
        probe.setResult(windowSample(frame: CGRect(x: 40, y: 40, width: 100, height: 100)), for: tgt.windowId)
        clock.advance(by: 0.1)
        tracker.testOnlyTick()
        probe.setResult(windowSample(frame: frameA), for: tgt.windowId)
        clock.advance(by: 0.1)
        tracker.testOnlyTick()
        let projectionBeforeRetry = store.get(id: ann.id)!.anchorProjection

        clock.advance(by: 0.6)
        tracker.testOnlyTick() // settled at frameA -> attempt #2 runs...
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()

        XCTAssertEqual(resolver.callCount, 2, "the resolve itself must run -- this exercises the write suppression, not the gate")
        let after = store.get(id: ann.id)!
        XCTAssertEqual(after.revision, revisionAfterFirstApply,
                       "a resolve that reproduces exactly what is stored must not consume a revision")
        XCTAssertEqual(after.anchorProjection, projectionBeforeRetry,
                       "sampledAt freshness alone must not count as a difference: the projection must not be rewritten either")
        if case .vectorPath(let data, _, _, _, _, _, _, _, _, _) = after.kind {
            XCTAssertEqual(data, "M5 5 L6 6")
        } else {
            XCTFail("the previously applied rebuilt kind must survive the skipped write")
        }
    }

    // MARK: - Element re-resolve: a window that moves during the walk

    func testResolveApplyIsRejectedWhenTheWindowMovedDuringTheWalk() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let resolver = GatedElementResolver(result: .resolved(kind: Self.resolvedKind, screenId: Self.screenId))
        let tracker = makeTracker(store: store, probe: probe, clock: clock, elementResolver: resolver)

        let tgt = makeTarget()
        let referenceFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let anchor = elementAnchor(target: tgt, referenceFrame: referenceFrame, spec: elementSpec())
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        let frameA = CGRect(x: 10, y: 10, width: 100, height: 100)
        probe.setResult(windowSample(frame: frameA), for: tgt.windowId)
        tracker.testOnlyTick() // first observation

        clock.advance(by: 0.25)
        tracker.testOnlyTick() // settled -> attempt #1 triggers
        XCTAssertTrue(resolver.awaitWalkStart(), "attempt #1 must start; the walk is now BLOCKED on the gate")
        XCTAssertEqual(resolver.callCount, 1)

        // The window moves while the walk is provably still in flight, and
        // a sampling tick observes the move (ticks never stop for a walk --
        // the two run on separate queues by design).
        let frameB = CGRect(x: 200, y: 220, width: 100, height: 100)
        probe.setResult(windowSample(frame: frameB), for: tgt.windowId)
        clock.advance(by: 0.1)
        tracker.testOnlyTick()

        resolver.release() // the walk finally returns geometry resolved around frameA
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()

        let afterReject = store.get(id: ann.id)!
        if case .vectorPath(let data, _, _, _, _, _, _, _, _, _) = afterReject.kind {
            XCTAssertEqual(data, "M0 0 L1 1", "geometry resolved against a superseded frame must not be installed")
        } else {
            XCTFail("the original kind must survive a rejected apply")
        }
        XCTAssertEqual(afterReject.anchor?.referenceWindowFrame.cgRect, referenceFrame,
                       "a rejected apply must not re-baseline the anchor to the stale pre-walk frame")
        XCTAssertEqual(afterReject.anchorProjection?.adjustment,
                       AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 200, translateY: 220),
                       "the live projection must keep tracking the window's REAL position throughout")

        // Once the window settles at its new position, a fresh resolve runs
        // and THIS one applies -- the rejection is a deferral, not a dead end.
        clock.advance(by: 0.6)
        tracker.testOnlyTick() // settled at frameB -> attempt #2 triggers
        XCTAssertTrue(resolver.awaitWalkStart(), "the rejected apply must not block a retry once the window settles")
        XCTAssertEqual(resolver.callCount, 2)
        resolver.release()
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()

        let afterRetry = store.get(id: ann.id)!
        if case .vectorPath(let data, _, _, _, _, _, _, _, _, _) = afterRetry.kind {
            XCTAssertEqual(data, "M5 5 L6 6")
        } else {
            XCTFail("the retry against the settled frame must apply")
        }
        XCTAssertEqual(afterRetry.anchor?.referenceWindowFrame.cgRect, frameB)
        XCTAssertEqual(afterRetry.anchorProjection?.adjustment, .identity)
    }

    // MARK: - Element re-resolve: frozen staticAdjustment must not offset rebuilt geometry

    func testSuccessfulResolveClearsAFrozenStaticAdjustment() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let resolver = FakeElementResolver(result: .resolved(kind: Self.resolvedKind, screenId: Self.screenId))
        let tracker = makeTracker(store: store, probe: probe, clock: clock, elementResolver: resolver)

        let tgt = makeTarget()
        let anchor = elementAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100), spec: elementSpec())
        // An `anchor_resize` policy change keeps `.element` mode while
        // folding the live adjustment into `staticAdjustment` -- exactly the
        // state that used to leave the ring permanently offset after the
        // next resolve installed absolute geometry underneath it.
        let frozen = AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 37, translateY: -12)
        let ann = makeAnnotation(anchor: anchor, staticAdjustment: frozen)
        store.add(ann)

        probe.setResult(windowSample(frame: CGRect(x: 10, y: 10, width: 100, height: 100)), for: tgt.windowId)
        tracker.testOnlyTick()
        clock.advance(by: 0.25)
        tracker.testOnlyTick()
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()
        XCTAssertEqual(resolver.callCount, 1)

        let updated = store.get(id: ann.id)!
        if case .vectorPath(let data, _, _, _, _, _, _, _, _, _) = updated.kind {
            XCTAssertEqual(data, "M5 5 L6 6")
        } else {
            XCTFail("the rebuilt kind must be installed")
        }
        XCTAssertEqual(updated.staticAdjustment, .identity,
                       "installing absolutely-positioned rebuilt geometry must absorb any frozen adjustment")
        XCTAssertEqual(updated.anchorProjection?.adjustment, .identity)
        XCTAssertEqual(updated.effectiveAdjustment, .identity,
                       "the rebuilt geometry must paint exactly where it was resolved -- no residual offset")
    }

    // MARK: - Element re-resolve: kind, anchor, and projection commit atomically

    func testSuccessfulResolveCommitsKindAnchorAndProjectionInOneStoreNotification() {
        let store = AnnotationStore()
        let probe = FakeProbe()
        let clock = FakeClock()
        let resolver = GatedElementResolver(result: .resolved(kind: Self.resolvedKind, screenId: Self.screenId))
        let tracker = makeTracker(store: store, probe: probe, clock: clock, elementResolver: resolver)

        let tgt = makeTarget()
        let anchor = elementAnchor(target: tgt, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100), spec: elementSpec())
        let ann = makeAnnotation(anchor: anchor)
        store.add(ann)

        let frameA = CGRect(x: 10, y: 10, width: 100, height: 100)
        probe.setResult(windowSample(frame: frameA), for: tgt.windowId)
        tracker.testOnlyTick()
        clock.advance(by: 0.25)
        tracker.testOnlyTick() // trigger; the walk blocks on the gate, so nothing can write yet
        XCTAssertTrue(resolver.awaitWalkStart())
        XCTAssertEqual(resolver.callCount, 1)

        // `notifyChange` delivers `onStoreChanged` via `MainThread.enqueue`
        // (a NEW main-queue turn -- see that method's doc comment), and each
        // queued block resolves `self?.onStoreChanged` at EXECUTION time. So
        // before attaching the counter, drain every notification already
        // enqueued by the setup writes above (`store.add`, the ticks'
        // `applyAnchorProjections`) while the callback is still nil --
        // otherwise those stale blocks would run against the counter and be
        // miscounted as commits from the resolve under test. Same discipline
        // as AnnotationStoreTests' notification-counting tests.
        let setupDrained = expectation(description: "setup notifications drained")
        DispatchQueue.main.async { setupDrained.fulfill() }
        wait(for: [setupDrained], timeout: 2)

        // Count repaint-driving notifications from here on. Safe to assign
        // now: the walk is blocked on the gate and the sampling queue is
        // drained, so no writer can race this assignment.
        let counter = ChangeCounter()
        store.onStoreChanged = { counter.increment() }

        resolver.release()
        tracker.testOnlyWaitForElementQueueIdle()
        tracker.testOnlyFlush()

        // The commit's own notification is now sitting in the main queue;
        // drain one more turn so it (and any erroneous second one) has
        // actually run before counting.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertEqual(counter.count, 1,
                       "the rebuilt kind, re-baselined anchor, and reset projection must land as ONE store write -- " +
                       "a second notification would be a paintable frame pairing new geometry with the old adjustment")
        let updated = store.get(id: ann.id)!
        if case .vectorPath(let data, _, _, _, _, _, _, _, _, _) = updated.kind {
            XCTAssertEqual(data, "M5 5 L6 6")
        } else {
            XCTFail("the single write must carry the rebuilt kind")
        }
        XCTAssertEqual(updated.anchor?.referenceWindowFrame.cgRect, frameA,
                       "the single write must carry the re-baselined anchor")
        XCTAssertEqual(updated.anchorProjection?.adjustment, .identity,
                       "the single write must carry the reset projection")
    }
}
