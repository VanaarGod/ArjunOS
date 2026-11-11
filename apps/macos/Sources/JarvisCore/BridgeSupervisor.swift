import Foundation
import Security

public enum BridgeState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: Int)
    case failed(String)
}

public struct BridgeLaunchConfig: Sendable {
    public var pythonExecutable: String       // e.g. <venv>/bin/python3 (created by scripts/setup.sh)
    public var stateDirectory: URL
    public var offline: Bool
    /// When running from a packaged .app, the bridge sources are bundled here and take precedence on PYTHONPATH.
    public var bundledBridgePath: String?
    public init(pythonExecutable: String, stateDirectory: URL, offline: Bool, bundledBridgePath: String? = nil) {
        self.pythonExecutable = pythonExecutable; self.stateDirectory = stateDirectory; self.offline = offline
        self.bundledBridgePath = bundledBridgePath
    }
}

/// Owns exactly one bridge child process. It only terminates a process it launched itself.
/// The main app stays usable if this fails: callers render `state` and offer Retry.
public actor BridgeSupervisor {
    public private(set) var state: BridgeState = .stopped
    public private(set) var client: BridgeClient?
    private var process: Process?
    private var stderrTail: [String] = []

    public init() {}

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "secure random unavailable")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func start(_ cfg: BridgeLaunchConfig) async {
        if case .running = state { return }
        state = .starting
        guard FileManager.default.isExecutableFile(atPath: cfg.pythonExecutable) else {
            state = .failed("Python not found at \(cfg.pythonExecutable). Run scripts/setup.sh, or set the path in Settings → Diagnostics.")
            return
        }
        for attempt in 1...3 {
            guard let port = PortFinder.freeLoopbackPort() else { state = .failed("Could not reserve a loopback port."); return }
            let token = Self.generateToken()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cfg.pythonExecutable)
            var args = ["-m", "jarvis_bridge.api.server", "--state-dir", cfg.stateDirectory.path, "--port", String(port),
                        "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]   // bridge exits if we die
            if cfg.offline { args.append("--offline") }
            p.arguments = args
            // Minimal environment: the child does NOT inherit the user's shell secrets.
            var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                       "HOME": NSHomeDirectory(), "JARVIS_BRIDGE_TOKEN": token, "PYTHONUNBUFFERED": "1"]
            if let b = cfg.bundledBridgePath, FileManager.default.fileExists(atPath: b) { env["PYTHONPATH"] = b }
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe(); p.standardError = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let s = String(decoding: h.availableData, as: UTF8.self)
                if !s.isEmpty { Task { await self?.appendStderr(s) } }
            }
            do { try p.run() } catch { state = .failed("Failed to launch bridge: \(error.localizedDescription)"); return }
            process = p
            let c = BridgeClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token)
            if await waitUntilHealthy(c, process: p, timeout: 15) {
                client = c; state = .running(port: port); return
            }
            p.terminate(); process = nil
            if attempt == 3 { state = .failed("Bridge did not become healthy.\n" + stderrTail.suffix(8).joined(separator: "\n")) }
        }
    }

    private func appendStderr(_ s: String) { stderrTail.append(contentsOf: s.split(separator: "\n").map(String.init)); stderrTail = Array(stderrTail.suffix(200)) }
    public func diagnosticsTail() -> [String] { stderrTail }

    private func waitUntilHealthy(_ c: BridgeClient, process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return false }
            if (try? await c.health())?.ok == true { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    public func stop() async {
        guard let p = process else { state = .stopped; client = nil; return }
        if p.isRunning {
            p.terminate()
            for _ in 0..<30 where p.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        process = nil; client = nil; state = .stopped
    }

    public func restart(_ cfg: BridgeLaunchConfig) async { await stop(); await start(cfg) }
}
