// The island's Focus page and its minute ruler.

import AppKit
import AVFoundation
import Combine
import CoreAudio
import EventKit
import Carbon.HIToolbox
import Darwin
import ImageIO
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import os

extension IslandView {
    // MARK: focus

    var focusTab: some View {
        HStack(alignment: .top, spacing: Space.gutter) {
            VStack(alignment: .leading, spacing: Space.l) {
                Segments(selection: Binding(get: { focus.isBreak }, set: { focus.setBreak($0) }), values: [false, true], name: L("Focus")) {
                    $0 ? L("Break") : L("Focus")
                }
                .frame(width: 180)
                Text(focus.text).font(UI.hero)
                    .contentTransition(.numericText())
                HStack(spacing: Space.m) {
                    Button { focus.running ? focus.pause() : focus.start() } label: {
                        Label(focus.running ? L("Pause") : L("Start"), systemImage: focus.running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                    if focus.active {
                        Button(L("Reset")) { focus.reset() }.buttonStyle(CocaineButtonStyle(height: CTL.hDialog))
                    }

                }
            }
            .frame(width: 250, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.m) {
                Text(L("Minutes")).font(UI.section).foregroundStyle(UI.secondary)
                MinuteRuler(minutes: Binding(get: { focus.minutes }, set: { if !focus.active { focus.minutes = $0 } }))
                    .opacity(focus.active ? 0.4 : 1)
                Text(L("Drag the ruler to set the length. Cocaine keeps the Mac awake while a focus runs."))
                    .font(UI.detail).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

private final class RulerDrag: ObservableObject { var start: Int? }

/// A horizontal ruler of minutes: drag it to set a length from 5 to 120 minutes.
private struct MinuteRuler: View {
    @Binding var minutes: Int
    @StateObject private var drag = RulerDrag()
    private let step: CGFloat = 5          // points per minute

    var body: some View {
        GeometryReader { r in
            let mid = r.size.width / 2
            Canvas { g, size in
                for v in max(0, minutes - 60)...(minutes + 60) where v >= 5 && v <= 120 {
                    let x = mid + CGFloat(v - minutes) * step
                    guard x > 0, x < size.width else { continue }
                    let big = v % 10 == 0, mid5 = v % 5 == 0
                    let h: CGFloat = big ? 20 : mid5 ? 14 : 8
                    g.fill(Path(CGRect(x: x - 0.5, y: size.height - h - 14, width: 1, height: h)), with: .color(.white.opacity(big ? 0.7 : 0.3)))
                    if big { g.draw(Text("\(v)").font(.system(size: 9)).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: x, y: size.height - 5)) }
                }
            }
            .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))   // the ticks fade at the ends
            RoundedRectangle(cornerRadius: 1.5).fill(Island.accent).frame(width: 3, height: 26).position(x: mid, y: 27)
            // The length, inside the frame and outside the fade (it used to sit above the frame and was masked away).
            Text("\(minutes)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Island.accent).position(x: mid, y: 6)
        }
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            if drag.start == nil { drag.start = minutes }
            let new = min(120, max(5, (drag.start ?? minutes) - Int((v.translation.width / step).rounded())))
            if new != minutes { Haptic.tap(new % 5 == 0 ? .levelChange : .alignment) }              // a firmer tick on every fifth minute
            minutes = new
        }.onEnded { _ in drag.start = nil })
        .onScrollSteps(every: 5) { minutes = min(120, max(5, minutes + $0)) }       // (the tap comes from the scroll itself)
    }
}
