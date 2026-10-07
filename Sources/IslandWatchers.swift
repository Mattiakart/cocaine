// The island's live data: the microphone. (The focus timer is in IslandFocus.swift, the batteries in IslandStatus.swift, the AI
// tools' usage in Usage.swift.)

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

// MARK: Island data

/// Is something using a microphone right now? CoreAudio's own "running somewhere" flag of every input device, watched with
/// property listeners (no polling); the list of devices is watched too (a headset plugged in).
final class MicWatch: ObservableObject {
    @Published var active = false
    private var started = false
    private var devices: [AudioDeviceID] = []
    private lazy var devicesChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
    private lazy var runningChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.update() }
    private static var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                                    mElement: kAudioObjectPropertyElementMain)
    private static var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard !started else { return }
        started = true
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.devicesAddress, .main, devicesChanged)
        rescan()
    }

    func stop() {
        guard started else { return }
        started = false
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.devicesAddress, .main, devicesChanged)
        for d in devices { AudioObjectRemovePropertyListenerBlock(d, &Self.runningAddress, .main, runningChanged) }
        devices = []
        if active { active = false }
    }

    private func rescan() {
        for d in devices { AudioObjectRemovePropertyListenerBlock(d, &Self.runningAddress, .main, runningChanged) }
        devices = Self.inputDevices()
        for d in devices { AudioObjectAddPropertyListenerBlock(d, &Self.runningAddress, .main, runningChanged) }
        update()
    }

    private func update() {
        let now = devices.contains { Self.isRunning($0) }
        if now != active { active = now }
    }

    /// Every device with an input stream (microphones, headsets, audio interfaces).
    static func inputDevices() -> [AudioDeviceID] {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr && s > 0
        }
    }

    static func isRunning(_ id: AudioDeviceID) -> Bool {
        var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &size, &running) == noErr && running != 0
    }
}
