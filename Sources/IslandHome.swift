// The island's Home page.

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
    // MARK: home: Cocaine and what the AIs are doing

    private var statusText: String {
        guard m.on else { return L("Your Mac sleeps as usual") }
        if let u = m.onUntil, u > Date() { return L("Your Mac stays awake") + " · " + String(format: L("until %@"), PanelView.timeString(u)) }
        return L("Your Mac stays awake")
    }

    var homeTab: some View {
        HStack(alignment: .top, spacing: Space.gutter) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Cocaine").font(UI.pageTitle)
                        Text(statusText).font(UI.detail).foregroundStyle(UI.secondary).lineLimit(2)
                    }
                    Spacer(minLength: Space.s)
                    PowderSwitch(bag: m.bag, on: m.on) { m.toggleCocaine() }.accessibilityLabel(L("Cocaine, keeps the Mac awake"))
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(L("Stay on for")).font(UI.section).foregroundStyle(UI.secondary)
                    Segments(selection: $m.timerMinutes, values: Settings.timerChoices, name: L("Stay on for"), label: { Dur.short(minutes: $0) },
                             spoken: { $0 == 0 ? L("No limit") : nil }, compact: { Dur.compact(minutes: $0) })
                        .onScrollSteps(every: 24) { n in
                            let c = Settings.timerChoices
                            let i = c.firstIndex(of: m.timerMinutes) ?? c.firstIndex { $0 >= m.timerMinutes } ?? 0
                            m.timerMinutes = c[min(c.count - 1, max(0, i + n))]
                        }
                }
                HStack(spacing: Space.m) {
                    Image(systemName: "person.crop.circle.badge.checkmark").font(UI.icon).foregroundStyle(m.presenceActive ? Island.accent : UI.hint)
                        .frame(width: UI.iconColumn)
                    Text(L("Stay active")).font(UI.value).foregroundStyle(UI.primary).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    CocaineSwitch($m.stayActive).accessibilityLabel(L("Stay active"))
                }
                .help(L("While you're idle it sends an invisible mouse event so Teams and the like don't show you as away."))
            }
            .frame(width: 250)
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    Text(L("Agents")).font(UI.section).foregroundStyle(UI.secondary)
                    if m.board.count + m.approvals.count > 3 {
                        Text("\(m.board.count + m.approvals.count)").font(UI.section.monospacedDigit()).foregroundStyle(UI.hint)
                    }
                }
                .padding(.top, 3)                               // on the cap line of "Cocaine" beside it
                if m.board.isEmpty && m.approvals.isEmpty && m.agentNotice == nil {
                    Text(m.ai.available ? L("No AI at work") : L("No AI tool found")).font(UI.value).foregroundStyle(UI.hint)
                } else {                                    // all of them, scrolling; those that need you first
                    AgentListView(entries: m.board, approvals: m.approvals, notice: m.agentNotice, island: true, accent: Island.accent,
                                  warning: warningColor, maxHeight: .infinity, focus: m.focusAgent, answer: m.answerApproval, release: m.releaseApproval)
                        .padding(.horizontal, -AgentListView.inset)   // icons on the column's edge
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
