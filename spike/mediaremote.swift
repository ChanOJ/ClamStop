// Probe: can a normal user process read the playback state and pause / resume it through the
// private MediaRemote framework on this macOS version? Run as the logged-in user while music plays:
//   swift spike/mediaremote.swift            (state, pause, state, play, state)
//   swift spike/mediaremote.swift --watch    (log state on lid changes and wakes until Ctrl-C)

import AppKit
import CoreAudio
import IOKit

func log(_ s: String) { print("\(Date()) \(s)"); fflush(stdout) }

let mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(mr, name).map { unsafeBitCast($0, to: T.self) } }

typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
typealias InfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool
let isPlayingFn = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying", IsPlayingFn.self)
let infoFn = sym("MRMediaRemoteGetNowPlayingInfo", InfoFn.self)
let sendFn = sym("MRMediaRemoteSendCommand", SendFn.self)
log("symbols: isPlaying=\(isPlayingFn != nil) info=\(infoFn != nil) send=\(sendFn != nil)")

/// Any process outputting audio on the default output device (public CoreAudio API).
func audioRunning() -> Bool {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
    var running = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
    return running != 0
}

func state(_ label: String, then next: @escaping () -> Void = {}) {
    let group = DispatchGroup()
    var playing: Bool?
    var title = "?"
    group.enter()
    isPlayingFn?(.main) { playing = $0; group.leave() } ?? group.leave()
    group.enter()
    infoFn?(.main) { info in
        let d = info as? [String: Any] ?? [:]
        title = (d["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? "(no info: \(d.count) keys)"
        group.leave()
    } ?? group.leave()
    group.notify(queue: .main) {
        log("\(label): MediaRemote isPlaying=\(playing.map(String.init) ?? "nil") title=\(title) | CoreAudio output running=\(audioRunning())")
        next()
    }
}

func send(_ command: UInt32, _ name: String) {
    log("send \(name): \(sendFn.map { String($0(command, nil)) } ?? "no symbol")")
}

if CommandLine.arguments.contains("--watch") {
    let port = IONotificationPortCreate(kIOMainPortDefault)!
    IONotificationPortSetDispatchQueue(port, .main)
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    var notifier: io_object_t = 0
    IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { _, _, msg, arg in
        guard msg == 0xE0034100 else { return }
        state("lid \(UInt(bitPattern: arg) & 1 != 0 ? "closed" : "open")")
    }, nil, &notifier)
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        state("didWake")
    }
    state("start (watching)")
} else {
    state("before") {
        send(1, "pause")  // kMRPause
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            state("after pause") {
                send(0, "play")  // kMRPlay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    state("after play") { exit(0) }
                }
            }
        }
    }
}
NSApplication.shared.run()
