import CoreAudio
import Foundation
import IOKit

/// Pauses playback when the lid closes and resumes it when the lid opens again, so the
/// short wake that precedes hibernation does not play a fraction of a second of audio.
///
/// Runs in the app (the user's session), not in the root daemon: media playback belongs to the
/// user. Whether audio is playing comes from public CoreAudio ("output device running
/// somewhere"). Pause and play go through the private MediaRemote framework: on macOS 27.2,
/// reading the now-playing state is blocked for third-party apps but sending commands works
/// (verified 2026-11-26, `spike/mediaremote.swift`). If the symbol disappears, this does nothing.
@MainActor
final class AudioPauser {
    /// Decides at lid close whether pausing applies (setting on, ClamStop on, hibernation not "never").
    var shouldPause: () -> Bool = { false }

    private var pausedByUs = false
    private var lastLidClosed = false
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let sendCommand: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()
    private static let commandPlay: UInt32 = 0   // kMRPlay
    private static let commandPause: UInt32 = 1  // kMRPause

    func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        lastLidClosed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
        let context = Unmanaged.passUnretained(self).toOpaque()
        // kIOPMMessageClamshellStateChange, bit 0 = closed (see the daemon's SystemPower.swift).
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, message, argument in
            guard message == 0xE003_4100, let context else { return }
            let closed = UInt(bitPattern: argument) & 1 != 0
            let pauser = Unmanaged<AudioPauser>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { pauser.lidChanged(closed: closed) }
        }, context, &notifier)
    }

    private func lidChanged(closed: Bool) {
        defer { lastLidClosed = closed }
        guard closed != lastLidClosed else { return }  // repeated messages during wakes
        if closed {
            guard shouldPause(), Self.outputRunning(), let send = Self.sendCommand else { return }
            pausedByUs = send(Self.commandPause, nil)
        } else if pausedByUs {
            pausedByUs = false
            // The lid-open message arrives early in the wake; give audio devices a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                _ = Self.sendCommand?(Self.commandPlay, nil)
            }
        }
    }

    /// Some process is outputting audio on the default output device.
    private static func outputRunning() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
