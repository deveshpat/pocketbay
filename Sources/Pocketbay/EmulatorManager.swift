import Foundation

/// Starts/attaches to the Pocketbay AVD and wraps the adb calls the app needs.
final class EmulatorManager {
    static let avdName = "Pocketbay"
    static let grpcPort = 8554
    static let consolePort = 5556

    let sdk = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Android/sdk")
    var serial: String { "emulator-\(Self.consolePort)" }
    private var adb: String { sdk.appendingPathComponent("platform-tools/adb").path }
    private(set) var pid: Int32?
    /// True when this app launched the emulator (and should shut it down on quit).
    private(set) var ownsEmulator = false

    struct Endpoint { let port: Int; let token: String }

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Pocketbay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("emulator.log")
    }

    // MARK: Discovery

    private var discoveryDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    }

    /// Finds a live emulator running our AVD via its discovery file (pid_<pid>.ini).
    func findRunning() -> (pid: Int32, endpoint: Endpoint)? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: discoveryDir, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.lastPathComponent.hasPrefix("pid_") && file.pathExtension == "ini" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var kv: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                kv[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
            let pidString = file.deletingPathExtension().lastPathComponent.dropFirst("pid_".count)
            guard kv["avd.name"] == Self.avdName, let pid = Int32(pidString), kill(pid, 0) == 0,
                  let portString = kv["grpc.port"], let port = Int(portString), let token = kv["grpc.token"] else { continue }
            return (pid, Endpoint(port: port, token: token))
        }
        return nil
    }

    // MARK: Lifecycle

    /// Attaches to a running emulator or launches one, then waits for its gRPC endpoint.
    func start() async throws -> Endpoint {
        if let running = findRunning() {
            pid = running.pid
            return running.endpoint
        }
        clearStaleLocks()
        let proc = Process()
        proc.executableURL = sdk.appendingPathComponent("emulator/emulator")
        proc.arguments = ["-avd", Self.avdName, "-no-window", "-gpu", "host", "-no-boot-anim",
                          "-grpc", "\(Self.grpcPort)", "-grpc-use-token", "-port", "\(Self.consolePort)",
                          // Wi-Fi via netsim packet streaming ran ~15x slower than the Mac's own
                          // connection; the emulator's built-in network path is much faster.
                          "-feature", "-WiFiPacketStream",
                          // Guest ANGLE on Vulkan. The default guest GLES driver's native sync
                          // fences fail on macOS hosts: Unreal Engine games (BGMI) segfault in
                          // createNativeSync, or render black if async swap is off. GrallocSync
                          // "fixes" that but deadlocks SystemUI.
                          "-feature", "Vulkan", "-feature", "GuestAngle",
                          // Pocketbay plays Android's sound itself (AudioPlayer, via the gRPC audio
                          // stream) so it follows the Mac's output device; the emulator's own
                          // CoreAudio output binds once at launch and would also double the sound.
                          "-audio", "none", "-no-metrics"]
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: Self.logURL)
        proc.standardOutput = log
        proc.standardError = log
        try proc.run()
        ownsEmulator = true

        for _ in 0..<120 {
            if let running = findRunning() {
                pid = running.pid
                return running.endpoint
            }
            if !proc.isRunning {
                throw NSError(domain: "Pocketbay", code: 10, userInfo: [NSLocalizedDescriptionKey:
                    "Android didn't start. Details are in \(Self.logURL.path)"])
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw NSError(domain: "Pocketbay", code: 11, userInfo: [NSLocalizedDescriptionKey: "Timed out starting Android."])
    }

    /// A crash or power loss leaves *.lock files in the AVD folder, and the emulator then
    /// refuses to start ("multiple emulators with the same AVD"). Only called when no
    /// emulator for this AVD is running, so any lock left is stale.
    private func clearStaleLocks() {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "qemu-system.*-avd \(Self.avdName)( |$)"]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        guard pgrep.terminationStatus != 0 else { return }   // an emulator is running: locks are live
        let avdDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".android/avd/\(Self.avdName).avd")
        let files = (try? FileManager.default.contentsOfDirectory(at: avdDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "lock" { try? FileManager.default.removeItem(at: f) }
    }

    var isRunning: Bool { pid.map { kill($0, 0) == 0 } ?? false }

    /// Saves a quick-boot snapshot and stops the emulator.
    func shutdown() async {
        guard let pid else { return }
        _ = await run(adb, ["-s", serial, "emu", "kill"])
        for _ in 0..<120 where kill(pid, 0) == 0 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if kill(pid, 0) == 0 { kill(pid, SIGTERM) }
        self.pid = nil
    }

    // MARK: adb helpers

    /// Android settings Pocketbay enforces on every boot.
    func applyDeviceDefaults() async {
        // Never pop up the on-screen keyboard: the Mac keyboard is always attached.
        _ = await run(adb, ["-s", serial, "shell", "settings put secure show_ime_with_hard_keyboard 0"])
    }

    func install(apk: URL) async -> (ok: Bool, message: String) {
        let out = await run(adb, ["-s", serial, "install", "-r", apk.path])
        let ok = out.status == 0 && out.output.contains("Success")
        let failure = out.output.split(separator: "\n").last { $0.contains("Failure") || $0.contains("error") }
        return (ok, ok ? "Installed \(apk.deletingPathExtension().lastPathComponent)"
                       : String(failure ?? "Install failed"))
    }

    /// Package name of the app currently in front, e.g. "com.pubg.imobile".
    func foregroundPackage() async -> String? {
        let out = await run(adb, ["-s", serial, "shell", "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'"])
        for line in out.output.split(separator: "\n") where line.contains("mCurrentFocus") || line.contains("mFocusedApp") {
            if let r = line.range(of: #"u0 ([A-Za-z0-9_.]+)/"#, options: .regularExpression) {
                return String(line[r].dropFirst(3).dropLast())
            }
        }
        return nil
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            // Drain the pipe before waiting so large outputs can't fill it and stall the child.
            DispatchQueue.global(qos: .utility).async {
                do { try p.run() } catch { cont.resume(returning: (-1, "\(error)")); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
