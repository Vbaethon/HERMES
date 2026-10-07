import AppKit
import QuartzCore

enum ZoomChecks {
    @MainActor static func run() {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            if !condition {
                FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
                exit(1)
            }
            checks += 1
        }
        for width: CGFloat in [640, 680, 900, 1080, 1512, 1920] {
            for (level, columns) in ZoomGeometry.columns.enumerated() {
                for prefix in 0..<columns {
                    let spec = ZoomGridSpec(level: level, leadingSlots: prefix)
                    let last = spec.frame(index: columns - 1 - prefix, width: width)
                    let next = spec.frame(index: columns - prefix, width: width)
                    check(abs(last.maxX - (width - ZoomGeometry.inset)) < 0.0001, "row fills available width")
                    check(next.minX == ZoomGeometry.inset && next.minY > last.maxY, "persistent column count and row offset")
                    let slots = (0..<100).map { index in
                        let frame = spec.frame(index: index, width: width)
                        return (frame.minY, frame.minX)
                    }
                    check(zip(slots, slots.dropFirst()).allSatisfy {
                        $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1)
                    }, "precomputed row shifts preserve asset order")
                }
            }
        }
        let width: CGFloat = 1080
        let base = ZoomGridSpec(level: 0)
        let frame = base.frame(index: 333, width: width)
        let point = CGPoint(x: frame.minX + frame.width * 0.73, y: frame.minY + frame.height * 0.26)
        let anchor = ZoomAnchor(index: 333, frame: frame, documentPoint: point,
                                viewportPoint: CGPoint(x: point.x, y: 220))
        let plan = ZoomPlan(anchor: anchor, base: base, width: width, height: 600, count: 900)
        for position in stride(from: 0.0, through: 3.0, by: 0.025) {
            var alpha = ZoomAlphaPresentation(level: 0)
            alpha.update(position: position)
            let states = plan.specs.map {
                ZoomLayerState(spec: $0, position: position, width: width,
                    focusCenter: plan.focusCenter(width: width, height: 600, count: 900, position: position), weights: alpha.weights)
            }
            check(abs(alpha.weights.reduce(0, +) - 1) < 0.0001, "color weights conserve opacity")
            // Recover each grid's effective source-over color contribution.
            for level in 0..<4 {
                let contribution = states[(level + 1)...].reduce(CGFloat(states[level].opacity)) {
                    $0 * (1 - CGFloat($1.opacity))
                }
                check(abs(contribution - alpha.weights[level]) < 0.0001, "actual layer opacities produce a dissolve without darkening")
                let state = states[level]
                let mappedPointerX = state.spec.frame(index: state.spec.visualAnchorIndex, width: width).midX * state.scale + state.offset.x
                check(abs(mappedPointerX - plan.focusCenterX(width: width, position: position)) < 0.0001, "all endpoint grids share the same focal-row center")
                let cell = state.cellFrame(index: state.spec.visualAnchorIndex, width: width)
                check(abs(cell.minY + cell.height * anchor.unitPoint.y - anchor.viewportPoint.y) < 0.001,
                      "precomputed visual anchors share vertical focus")
            }
        }
        for spec in plan.specs {
            let weights: [CGFloat] = (0..<4).map { $0 == spec.level ? 1 : 0 }
            let endpoint = ZoomLayerState(spec: spec, position: CGFloat(spec.level), width: width,
                focusCenter: plan.focusCenter(width: width, height: 600, count: 900, position: CGFloat(spec.level)), weights: weights)
            check(endpoint.scale == 1 && endpoint.offset.x == 0, "settled endpoint has no horizontal correction")
            let targetFrame = spec.frame(index: anchor.index, width: width)
            check(targetFrame.contains(CGPoint(x: anchor.viewportPoint.x, y: targetFrame.midY)),
                  "deep-library row shift retains the pointer's asset")
        }
        for baseLevel in 0..<4 {
            for column in 0..<ZoomGeometry.columns[baseLevel] {
                for unitX: CGFloat in [0.05, 0.5, 0.95] {
                    let index = 900 + column
                    let baseSpec = ZoomGridSpec(level: baseLevel)
                    let cell = baseSpec.frame(index: index, width: width)
                    let pointer = CGPoint(x: cell.minX + cell.width * unitX, y: 200)
                    let rowAnchor = ZoomAnchor(index: index, frame: cell,
                        documentPoint: CGPoint(x: pointer.x, y: cell.midY), viewportPoint: pointer)
                    let family = ZoomPlan(anchor: rowAnchor, base: baseSpec, width: width, height: 600, count: 1800)
                    let centers = (0..<4).map { family.focusCenterX(width: width, position: CGFloat($0)) }
                    let changes = zip(centers, centers.dropFirst()).map { $1 - $0 }
                    check(changes.allSatisfy { $0 >= -0.001 } || changes.allSatisfy { $0 <= 0.001 },
                          "complete-family anchor planning prevents left/right reversals across levels")
                }
            }
        }
        for windowWidth: CGFloat in [680, 900, 1080, 1512, 1920] {
            for level in 0..<4 {
                let source = ZoomGridSpec(level: level)
                for index in [0, 2, 8, 16, 36, 67] {
                    let cell = source.frame(index: index, width: windowWidth)
                    let at = ZoomAnchor(index: index, frame: cell,
                        documentPoint: CGPoint(x: cell.midX, y: cell.midY),
                        viewportPoint: CGPoint(x: cell.midX, y: 300))
                    let edge = ZoomPlan(anchor: at, base: source, width: windowWidth, height: 600, count: 68)
                    for spec in edge.specs {
                        let weights = (0..<4).map { $0 == spec.level ? CGFloat(1) : 0 }
                        let state = ZoomLayerState(spec: spec, position: CGFloat(spec.level), width: windowWidth,
                            focusCenter: edge.focusCenter(width: windowWidth, height: 600, count: 68,
                                                          position: CGFloat(spec.level)), weights: weights)
                        let first = spec.frame(index: 0, width: windowWidth)
                        if -state.offset.y < first.maxY {
                            check(spec.leadingSlots == 0 && first.minX == ZoomGeometry.inset,
                                  "a visible library-start row is complete at every preset and window width")
                        }
                        check(spec.visualAnchorIndex == index, "boundary planning retains the pointer's original photo in every preset")
                        check(state.offset.x == 0, "boundary layouts finish without a lateral correction")
                    }
                }
            }
        }

        var alpha = ZoomAlphaPresentation(level: 0)
        alpha.update(position: 0.5)
        check(alpha.weights[0] == 0.5 && alpha.weights[1] == 0.5, "opacity is directly controlled by the current gesture progress")
        let beforeReverse = alpha.weights
        alpha.update(position: 0.25)
        check(alpha.weights[0] > beforeReverse[0], "opacity reverses immediately with the fingers")
        alpha.update(position: 0)
        check(alpha.weights[0] == 1, "opacity reaches the boundary without a delayed animation")

        var gesture = ZoomGesture(position: 0, width: width)
        gesture.update(magnification: 20, width: width)
        check(gesture.position == 3, "largest endpoint")
        check(gesture.elasticScale > 1 && gesture.elasticScale.isFinite, "three-column endpoint stretches with resistance")
        let maximumStretch = gesture.elasticScale
        gesture.update(magnification: -0.01, width: width)
        check(gesture.elasticScale < maximumStretch, "reversing immediately releases endpoint resistance")
        gesture.update(magnification: -22, width: width)
        check(gesture.position == 0, "smallest endpoint stops at nine columns")
        check(gesture.elasticScale < 1 && gesture.elasticScale > 0, "nine-column endpoint compresses with resistance")
        let minimumStretch = gesture.elasticScale
        gesture.update(magnification: 0.01, width: width)
        check(gesture.elasticScale > minimumStretch, "reversing immediately releases minimum resistance")
        check(gesture.destination(cancelled: true) == 0, "cancellation restores starting level")

        for (level, input) in [(3, CGFloat(0.08)), (0, CGFloat(-0.08))] {
            var elastic = ZoomGesture(position: CGFloat(level), width: width)
            var previous = elastic.elasticScale
            var previousStretch: CGFloat = 0
            var previousDelta = CGFloat.infinity
            for _ in 0..<400 {
                elastic.update(magnification: input, width: width)
                let stretch = level == 3 ? elastic.elasticScale - 1 : 1 - elastic.elasticScale
                let delta = stretch - previousStretch
                check(level == 3 ? elastic.elasticScale > previous : elastic.elasticScale <= previous,
                      "large-end input stays responsive; the native minimum input cannot collapse the small grid")
                check(level == 3 ? delta > 0 && delta < previousDelta : delta >= 0 && delta <= previousDelta,
                      "equal boundary input has progressively stronger resistance")
                previous = elastic.elasticScale; previousStretch = stretch; previousDelta = delta
            }
            check(level == 3 ? elastic.elasticScale > 2 : (elastic.elasticScale > ZoomGesture.minimumElasticScale && elastic.elasticScale < 0.92),
                  "large photos keep stretching while the small grid strongly resists collapse")
        }

        var smallPull = ZoomGesture(position: 0, width: width)
        var largePull = ZoomGesture(position: 3, width: width)
        smallPull.update(magnification: -0.6, width: width)
        largePull.update(magnification: 1.5, width: width)
        check(smallPull.elasticScale > 0.93 && largePull.elasticScale > 1.25,
              "the nine-column endpoint resists further shrinking much more strongly")
        check(largePull.elasticScale - 1 > 4 * (1 - smallPull.elasticScale),
              "small and large endpoint elasticity have deliberately different strength")
        for scale: CGFloat in [0.91, 0.94, 1.08, 1.5] {
            var resumed = ZoomGesture(position: scale < 1 ? 0 : 3, width: width, elasticScale: scale)
            resumed.update(magnification: 0, width: width)
            check(abs(resumed.elasticScale - scale) < 0.000001,
                  "grabbing an interrupted elastic return preserves the visible size")
        }

        for stretch: CGFloat in [0.95, 1.08] {
            let spring = ZoomElasticReturn(initialScale: stretch, start: 0)
            check(spring.scale(at: 0) == stretch, "elastic release preserves the first frame")
            check(abs(spring.scale(at: 0.3) - 1) < abs(stretch - 1), "elastic release moves toward the boundary")
            check(spring.isFinished(at: 1), "native-default critically damped return settles")
        }

        _ = NSApplication.shared
        let zoom = ZoomController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = zoom.scroll
        zoom.scroll.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        zoom.viewportChanged()
        let image = NSImage(size: NSSize(width: 80, height: 120), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        zoom.setAssets((0..<90).map { DemoAsset(url: URL(fileURLWithPath: "/demo/\($0).jpg"), image: image) })
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        zoom.beginGesture(at: CGPoint(x: 520, y: 350))
        check(!zoom.overlay.isHidden && zoom.collection.alphaValue == 0, "zoom displays prepared endpoint grids")
        let id = zoom.anchor!.index
        let path = IndexPath(item: id, section: 0)
        let item = zoom.collection.item(at: path)
        let nativeFrame = zoom.layout.layoutAttributesForItem(at: path)!.frame
        for _ in 0..<20 { zoom.changeGesture(magnification: 0.08) }
        zoom.advanceAnimation(at: CACurrentMediaTime() + 0.05)
        check(zoom.collection.item(at: path) === item, "pinch retains native item identity")
        check(zoom.layout.layoutAttributesForItem(at: path)!.frame == nativeFrame,
              "native cells never animate through new row/column positions")
        check((item?.view as? PhotoTile)?.bitmap === image && zoom.overlay.sharesBitmap(image, at: id),
              "all layouts reuse the same decoded images")
        check(zoom.overlay.states.filter { $0.weight > 0 }.count >= 2, "actual AppKit overlay has a visible dissolve")
        let destination = zoom.gesture!.destination()
        let prepared = zoom.plan!.specs[Int(destination)]
        zoom.endGesture()
        zoom.advanceAnimation(at: CACurrentMediaTime() + 1)
        check(zoom.position == destination && zoom.plan == nil, "release completes geometry and opacity")
        check(zoom.layout.spec == prepared, "prepared row offsets survive handoff unchanged")
        check(!zoom.overlay.isHidden && zoom.collection.alphaValue == 0,
              "handoff holds the completed overlay while native items finish layout")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        check(zoom.overlay.isHidden && zoom.collection.alphaValue == 1, "handoff restores the native collection view")
        for visible in zoom.collection.visibleItems() {
            let indexPath = zoom.collection.indexPath(for: visible)!
            let expected = zoom.layout.layoutAttributesForItem(at: indexPath)!.frame
            let actual = visible.view.frame
            // AppKit aligns item origins to device pixels.
            check(abs(actual.minX - expected.minX) <= 0.5 && abs(actual.minY - expected.minY) <= 0.5 &&
                  abs(actual.width - expected.width) <= 0.5 && abs(actual.height - expected.height) <= 0.5,
                  "real native item frames match prepared geometry before becoming visible")
        }
        let endpointFrame = zoom.layout.layoutAttributesForItem(at: path)!.frame
        let lastLayer = zoom.overlay.states[Int(destination)]
        check(abs(lastLayer.map(endpointFrame).minX - endpointFrame.minX) < 0.001,
              "last visible layer matches native x exactly without sliding")
        check(abs(lastLayer.map(endpointFrame).minY - endpointFrame.minY + zoom.scroll.contentView.bounds.minY) < 0.001,
              "last visible layer matches native scroll origin exactly")
        for newWidth: CGFloat in [780, 1080, 1512, 680, 1080] {
            window.setContentSize(NSSize(width: newWidth, height: 600))
            zoom.viewportChanged()
            check(zoom.position == destination && zoom.layout.spec == prepared,
                  "window resize preserves selected columns and row start")
            let columns = ZoomGeometry.columns[Int(destination)]
            let nextRow = zoom.layout.layoutAttributesForItem(at:
                IndexPath(item: columns - prepared.leadingSlots, section: 0))!.frame
            check(abs(nextRow.minX - ZoomGeometry.inset) < 0.001, "window resize retains complete interior rows")
        }
        zoom.zoom(to: 2)
        zoom.advanceAnimation(at: CACurrentMediaTime() + 1)
        let middleCell = zoom.layout.spec.frame(index: 60, width: zoom.layout.viewportSize.width)
        zoom.scroll.contentView.scroll(to: CGPoint(x: 0, y: middleCell.midY - 350))
        zoom.beginGesture(at: CGPoint(x: middleCell.midX, y: middleCell.midY))
        let focalPlan = zoom.plan!
        let sourceSpec = focalPlan.specs[2]
        let focusedRow = (focalPlan.anchor.index + sourceSpec.leadingSlots) / 5
        let focusedIndices = (0..<90).filter { ($0 + sourceSpec.leadingSlots) / 5 == focusedRow }
        zoom.changeGesture(magnification: 0.25)
        zoom.advanceAnimation(at: CACurrentMediaTime() + 0.04)
        check(Set(zoom.overlay.focalFrames.keys) == Set(focusedIndices), "five-column focal row remains a single opaque set while the surrounding grids dissolve")
        let focusedFrame = zoom.overlay.focalFrames[focalPlan.anchor.index]!
        let targetState = zoom.overlay.states[3]
        let targetFrame = targetState.cellFrame(index: focalPlan.anchor.index, width: zoom.layout.viewportSize.width)
        check(abs(focusedFrame.midX - targetFrame.midX) + abs(focusedFrame.midY - targetFrame.midY) < 0.001,
              "five-to-three focal photo has one shared position in both layouts")
        zoom.endGesture()
        zoom.advanceAnimation(at: CACurrentMediaTime() + 1)
        zoom.zoom(to: 3)
        zoom.advanceAnimation(at: CACurrentMediaTime() + 0.1)
        let oldPosition = zoom.position, oldStates = zoom.overlay.states
        zoom.beginGesture(at: CGPoint(x: 420, y: zoom.scroll.contentView.bounds.minY + 250))
        check(zoom.position == oldPosition && zip(oldStates, zoom.overlay.states).allSatisfy {
            $0.offset == $1.offset && $0.opacity == $1.opacity && $0.scale == $1.scale
        }, "interrupting preserves every visible transform and opacity")
        zoom.changeGesture(magnification: -0.08)
        check(zoom.position < oldPosition, "interrupted zoom responds immediately in reverse")
        zoom.endGesture(cancelled: true)
        zoom.advanceAnimation(at: CACurrentMediaTime() + 1)
        check(zoom.position == oldPosition.rounded(), "cancelled interruption settles cleanly")
        let rowOverlay = ZoomOverlay(frame: NSRect(x: 0, y: 0, width: width, height: 150))
        rowOverlay.setAssets(zoom.assets)
        for (source, target) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
            let spec = ZoomGridSpec(level: source)
            let cell = spec.frame(index: 60, width: width)
            let rowAnchor = ZoomAnchor(index: 60, frame: cell,
                documentPoint: CGPoint(x: cell.midX, y: cell.midY), viewportPoint: CGPoint(x: cell.midX, y: 75))
            let rowPlan = ZoomPlan(anchor: rowAnchor, base: spec, width: width, height: 150, count: 90)
            let columns = ZoomGeometry.columns[source]
            let start = 60 / columns * columns
            let retained = Set(start..<(start + columns))
            for incoming: CGFloat in [0, 0.0005, 0.002, 0.1, 0.5, 0.9, 1] {
                var weights: [CGFloat] = [0, 0, 0, 0]
                weights[source] = 1 - incoming
                weights[target] = incoming
                let p = ZoomGeometry.mix(CGFloat(source), CGFloat(target), incoming)
                rowOverlay.render(position: p, plan: rowPlan, weights: weights)
                check(Set(rowOverlay.focalFrames.keys) == retained,
                      "incoming photos never jump into the opaque foreground in either direction")
            }
        }
        rowOverlay.frame.size.height = 600
        for index in [0, 89] {
            for (source, target) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
                let spec = ZoomGridSpec(level: source)
                let cell = spec.frame(index: index, width: width)
                let origin = index == 0 ? 0 : max(0, spec.height(count: 90, width: width) - 600)
                let edgeAnchor = ZoomAnchor(index: index, frame: cell,
                    documentPoint: CGPoint(x: cell.midX, y: cell.midY),
                    viewportPoint: CGPoint(x: cell.midX, y: cell.midY - origin))
                let edgePlan = ZoomPlan(anchor: edgeAnchor, base: spec, width: width, height: 600, count: 90)
                for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
                    var weights: [CGFloat] = [0, 0, 0, 0]
                    weights[source] = 1 - fraction; weights[target] = fraction
                    let p = ZoomGeometry.mix(CGFloat(source), CGFloat(target), fraction)
                    rowOverlay.render(position: p, plan: edgePlan, weights: weights)
                    let a = rowOverlay.states[source].cellFrame(index: index, width: width)
                    let b = rowOverlay.states[target].cellFrame(index: index, width: width)
                    let aligned = abs(a.midX - b.midX) + abs(a.midY - b.midY) < 0.001
                    check(aligned && rowOverlay.focalOpacity(at: index) == 1,
                          "boundary focal alignment: index \(index), \(source)->\(target), fraction \(fraction), anchors \(edgePlan.specs[source].visualAnchorIndex)/\(edgePlan.specs[target].visualAnchorIndex)")
                }
                let endpoint = rowOverlay.states[target]
                let maxY = max(0, endpoint.spec.height(count: 90, width: width) - 600)
                check(endpoint.offset.y <= 0.001 && endpoint.offset.y >= -maxY - 0.001,
                      "library-edge final overlay uses a valid native scroll origin")
            }
        }

        // The reported 9->7 / 7->5 regression happened near the library start:
        // boundary planning exchanged the pointer's photo and then faded the
        // source foreground out. Check actual layer opacity as well as frames,
        // for every adjacent direction, including the first incoming frame.
        for index in [0, 4, 8, 16, 33, 60] {
            for (source, target) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
                let spec = ZoomGridSpec(level: source)
                let cell = spec.frame(index: index, width: width)
                let origin = min(max(0, spec.height(count: 90, width: width) - 600), max(0, cell.midY - 300))
                let focus = ZoomAnchor(index: index, frame: cell,
                    documentPoint: CGPoint(x: cell.midX, y: cell.midY),
                    viewportPoint: CGPoint(x: cell.midX, y: cell.midY - origin))
                let family = ZoomPlan(anchor: focus, base: spec, width: width, height: 600, count: 90)
                check(family.specs.allSatisfy { $0.visualAnchorIndex == index },
                      "all presets retain the focal identity near the library start and in the body")
                let columns = ZoomGeometry.columns[source], start = index / columns * columns
                let retained = Set(start..<min(90, start + columns))
                for fraction: CGFloat in [0, 0.0005, 0.002, 0.1, 0.5, 0.9, 0.998, 1] {
                    var alpha = ZoomAlphaPresentation(level: source)
                    let p = ZoomGeometry.mix(CGFloat(source), CGFloat(target), fraction)
                    alpha.update(position: p)
                    rowOverlay.render(position: p, plan: family, weights: alpha.weights)
                    check(Set(rowOverlay.focalFrames.keys) == retained,
                          "every adjacent direction keeps exactly the original focal row throughout the gesture")
                    check(retained.allSatisfy { rowOverlay.focalOpacity(at: $0) == 1 },
                          "focal photos never participate in the surrounding alpha transition")
                    let a = rowOverlay.focalFrames[index]!
                    let b = rowOverlay.states[target].cellFrame(index: index, width: width)
                    check(abs(a.midX - b.midX) + abs(a.midY - b.midY) + abs(a.width - b.width) < 0.001,
                          "the pointer's photo has one geometry even when the first row cannot be shifted")
                    if fraction == 1 {
                        let clip = rowOverlay.bounds.insetBy(dx: ZoomGeometry.inset, dy: 0)
                        for (photo, frame) in rowOverlay.focalFrames where frame.intersects(clip) {
                            let native = rowOverlay.states[target].cellFrame(index: photo, width: width)
                            check(abs(frame.midX - native.midX) + abs(frame.midY - native.midY) < 0.001,
                                  "the opaque focal row hands off at the native target positions without a flash")
                        }
                    }
                }
            }
        }
        zoom.zoom(to: 2)
        zoom.advanceAnimation(at: CACurrentMediaTime() + 1)
        zoom.beginGesture(at: CGPoint(x: 520, y: zoom.scroll.contentView.bounds.minY + 250))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        check(zoom.plan != nil && !zoom.overlay.isHidden && zoom.collection.alphaValue == 0,
              "a new gesture cancels the previous pending native handoff")
        zoom.endGesture()
        zoom.advanceAnimation(at: CACurrentMediaTime() + 1)
        for (level, input) in [(3, CGFloat(1)), (0, CGFloat(-0.7))] {
            zoom.zoom(to: level)
            zoom.advanceAnimation(at: CACurrentMediaTime() + 1)
            zoom.beginGesture(at: CGPoint(x: 520, y: zoom.scroll.contentView.bounds.minY + 300))
            zoom.changeGesture(magnification: input)
            check(zoom.position == CGFloat(level) && zoom.elasticScale != 1, "AppKit endpoint stretches without adding a column level")
            check(zoom.overlay.states.filter { $0.weight > 0 }.count == 1, "endpoint elasticity does not crossfade the focal grid")
            zoom.endGesture()
            zoom.advanceAnimation(at: CACurrentMediaTime() + 1)
            check(zoom.elasticScale == 1 && zoom.plan == nil, "AppKit endpoint spring hands off without a size jump")
        }
        zoom.beginGesture(at: CGPoint(x: 520, y: zoom.scroll.contentView.bounds.minY + 300))
        var frameTimes: [Double] = []
        for frame in 0..<120 {
            let start = CACurrentMediaTime()
            zoom.changeGesture(magnification: frame < 60 ? 0.004 : -0.004)
            zoom.advanceAnimation(at: start + 1.0 / 120)
            frameTimes.append((CACurrentMediaTime() - start) * 1000)
        }
        zoom.finishForInteraction()

        // Reproduce the reported screenshot: a shift created far down the
        // library used to remain visible as empty slots after scrolling home.
        zoom.setAssets((0..<900).map { DemoAsset(url: URL(fileURLWithPath: "/demo/\($0).jpg"), image: image) })
        // Start this new-data fixture at its canonical beginning instead of
        // inheriting the earlier pointer-dependent gesture's row offset.
        zoom.viewportChanged()
        zoom.zoom(to: 0)
        zoom.advanceAnimation(at: CACurrentMediaTime() + 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let deepCell = zoom.layout.spec.frame(index: 333, width: width)
        zoom.scroll.contentView.scroll(to: CGPoint(x: 0, y: deepCell.midY - 300))
        zoom.beginGesture(at: CGPoint(x: deepCell.midX, y: deepCell.midY))
        let ratio = ZoomGeometry.side(width: width, columns: 7) / ZoomGeometry.side(width: width, columns: 9)
        zoom.changeGesture(magnification: 2 * (ratio - 1))
        zoom.endGesture()
        zoom.advanceAnimation(at: CACurrentMediaTime() + 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        check(zoom.layout.spec.leadingSlots != 0, "deep-library focal alignment remains in use")
        zoom.scroll.contentView.scroll(to: .zero)
        zoom.viewportChanged()
        check(zoom.layout.spec.leadingSlots == 0 && zoom.position == 1,
              "scrolling a shifted grid home removes blank slots without changing its preset")
        for index in 0..<7 {
            let frame = zoom.layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!.frame
            check(abs(frame.minY - ZoomGeometry.inset) < 0.001 &&
                  abs(frame.minX - ZoomGeometry.inset - CGFloat(index) *
                      (ZoomGeometry.side(width: width, columns: 7) + ZoomGeometry.gap)) < 0.001,
                  "the repaired first row contains the first seven real assets in order")
        }
        check(zoom.assets.count == 900 && zoom.assets.enumerated().allSatisfy { index, asset in
            asset.url.lastPathComponent == "\(index).jpg"
        }, "repairing the first row never hides, rotates or duplicates assets")

        let sorted = frameTimes.sorted()
        print("PASS: \(checks) layout, opacity, no-recenter, handoff, reversal and AppKit checks")
        print(String(format: "AppKit update work: median %.2f ms, p95 %.2f ms (not a hardware gesture/FPS measurement)",
                     sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)]))
    }
}
