import Foundation

protocol PerlHelperDelegate: AnyObject {
    func perlHelper(_ helper: PerlHelper, didReceivePayload payload: AdapterPayload)
    func perlHelper(_ helper: PerlHelper, didReceiveError error: String)
    func perlHelper(_ helper: PerlHelper, didChangeState state: PerlHelper.State)
}

final class PerlHelper: @unchecked Sendable {
    enum State: Sendable {
        case starting
        case ready
        case stopped
        case reconnecting(attempt: Int)
        case unavailable(UnavailableReason)
    }

    /// Structured failure reasons for the `.unavailable` state. Replaces the
    /// previous free-form `reason: String` so consumers can pattern match
    /// instead of parsing substrings.
    enum UnavailableReason: Sendable {
        case launchFailed(String)
        case fatalExit(code: Int32)
        case transientRetriesExhausted
        case startupTimeout
    }

    weak var delegate: PerlHelperDelegate?

    // All mutable state below is only ever read or written on `ioQueue`.
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let framer = JSONLFramer()
    private let ioQueue = DispatchQueue(label: "MenuBarLyrics.perlHelper.io")
    private var reconnectAttempts = 0
    private var lastStableTime: Date?
    private var isManuallyStopped = false
    private var hasReceivedFirstPayload = false
    private var startupTimer: DispatchSourceTimer?

    private let perlPath = "/usr/bin/perl"
    private var scriptPath: String = ""
    private var frameworkPath: String = ""

    func configure(scriptPath: String, frameworkPath: String) {
        self.scriptPath = scriptPath
        self.frameworkPath = frameworkPath
    }

    func start() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard !self.scriptPath.isEmpty, !self.frameworkPath.isEmpty else {
                self.notify(.state(.unavailable(.launchFailed("Paths not configured"))))
                return
            }
            self.isManuallyStopped = false
            self.hasReceivedFirstPayload = false
            self.launchProcess()
        }
    }

    func stop() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.isManuallyStopped = true
            self.startupTimer?.cancel()
            self.startupTimer = nil
            self.terminateProcess()
            self.notify(.state(.stopped))
        }
    }

    /// Must be called on `ioQueue`. Spawns the perl adapter process and wires up
    /// the stdout/stderr readability handlers (which themselves hop back to
    /// `ioQueue` for all state access).
    private func launchProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: perlPath)
        process.arguments = [
            scriptPath,
            frameworkPath,
            "stream",
            "--no-diff",
            "--no-artwork",
            "--micros",
            "--debounce=50",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        process.terminationHandler = { [weak self] proc in
            // The termination handler runs on an unspecified queue; hop to the
            // ioQueue so all state mutations are serialized.
            self?.ioQueue.async {
                self?.handleTermination(exitCode: proc.terminationStatus)
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Route stdout processing (which touches framer/state) to ioQueue.
            self?.ioQueue.async {
                self?.processStdout(data: data)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            let truncated = String(line.prefix(500))
            self?.notify(.didReceiveError(truncated))
        }

        do {
            try process.run()
            self.notify(.state(.starting))
            armStartupWatchdog()
        } catch {
            self.notify(.state(.unavailable(.launchFailed("Failed to launch: \(error.localizedDescription)"))))
        }
    }

    /// Must be called on `ioQueue`. Arms a 5-second startup watchdog. If the
    /// helper has not produced its first payload by the deadline, it emits a
    /// `.unavailable(.startupTimeout)` state. The process is *not* killed: it
    /// may still emit data later (in which case the ready transition still
    /// fires and the watchdog has already been cancelled).
    private func armStartupWatchdog() {
        startupTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + 5.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.hasReceivedFirstPayload else { return }
            self.startupTimer = nil
            self.notify(.state(.unavailable(.startupTimeout)))
        }
        timer.resume()
        startupTimer = timer
    }

    /// Must be called on `ioQueue`. Feeds incoming bytes to the framer, decodes
    /// each complete line, and (on the first payload) marks the helper ready.
    private func processStdout(data: Data) {
        // framer is only ever touched here, on ioQueue.
        let lines = framer.feed(data)
        for line in lines {
            do {
                let envelope = try AdapterDecoder.decodeStreamLine(line)
                if !hasReceivedFirstPayload {
                    hasReceivedFirstPayload = true
                    lastStableTime = Date()
                    reconnectAttempts = 0
                    // First payload arrived: cancel the startup watchdog.
                    startupTimer?.cancel()
                    startupTimer = nil
                    notify(.state(.ready))
                }
                let payload = envelope.payload
                notify(.payload(payload))
            } catch {
                // Skip unparseable lines
            }
        }
    }

    /// Must be called on `ioQueue`. Handles a terminated process, either
    /// surfacing a terminal failure or scheduling a reconnect (also on ioQueue).
    private func handleTermination(exitCode: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        // The process is gone; the startup watchdog is no longer relevant.
        startupTimer?.cancel()
        startupTimer = nil
        process = nil

        guard !isManuallyStopped else {
            notify(.state(.stopped))
            return
        }

        if exitCode != 0 {
            notify(.state(.unavailable(.fatalExit(code: exitCode))))
            return
        }

        reconnectAttempts += 1
        if reconnectAttempts > 3 {
            notify(.state(.unavailable(.transientRetriesExhausted)))
            return
        }

        if let stable = lastStableTime, Date().timeIntervalSince(stable) > 60 {
            reconnectAttempts = 1
        }

        let attempt = reconnectAttempts
        notify(.state(.reconnecting(attempt: attempt)))

        let delay: TimeInterval
        switch reconnectAttempts {
        case 1: delay = 1
        case 2: delay = 2
        default: delay = 5
        }

        ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isManuallyStopped else { return }
            self.launchProcess()
        }
    }

    /// Must be called on `ioQueue`. Tears down the current process without
    /// scheduling a reconnect.
    private func terminateProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    // MARK: - Delegate dispatch

    /// All delegate callbacks are delivered on the main queue. State reads used
    /// to build these callbacks must already have been captured on `ioQueue`.
    private enum Notify {
        case state(PerlHelper.State)
        case payload(AdapterPayload)
        case didReceiveError(String)
    }

    private func notify(_ kind: Notify) {
        let captured = kind
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch captured {
            case .state(let state):
                self.delegate?.perlHelper(self, didChangeState: state)
            case .payload(let payload):
                self.delegate?.perlHelper(self, didReceivePayload: payload)
            case .didReceiveError(let error):
                self.delegate?.perlHelper(self, didReceiveError: error)
            }
        }
    }
}
