import Foundation
import WiiBalanceCore

/// A reading that stayed stable for the whole filter history (five stars).
struct StableReading: Equatable, Identifiable {
    let id = UUID()
    let kilograms: Double
}

/// Connects to the board, zeroes it and samples it at 20 Hz through the weight filter,
/// like the original application's 50 ms timer.
final class ScaleModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case bluetoothUnavailable(String)
        case searching
        case connecting(String)
        /// Measuring the empty board. `waitingForEmptyBoard` is set while someone is standing on it.
        case zeroing(waitingForEmptyBoard: Bool)
        case measuring
    }

    /// Below this the board counts as empty.
    static let onBoardThresholdKilograms = 10.0
    static let sampleInterval = 0.05
    static let zeroSampleCount = 40
    /// Give up on a connection that does not start streaming within this many seconds.
    static let handshakeTimeout = 10.0

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var measurement: ScaleMeasurement?
    /// Set once per step-on when the reading becomes fully stable.
    @Published private(set) var stableReading: StableReading?
    /// Whether a weigh-in has been saved since the person stepped on the board.
    @Published private(set) var recordedThisStepOn = false
    /// Explains the last failed connection attempt, if any.
    @Published private(set) var lastProblem: String?

    private let transport = BluetoothTransport()
    private var session: BalanceBoardSession!
    private var filter = WeightFilter()
    private var zeroSamples: [Double] = []
    private var timer: Timer?
    private var connectedAt: Date?
    private var stableReported = false

    init() {
        session = BalanceBoardSession { [weak self] report in
            self?.transport.send(report)
        }
        session.onStateChange = { [weak self] state in
            self?.sessionStateChanged(state)
        }
        transport.delegate = self
    }

    var isOnBoard: Bool {
        guard phase == .measuring, let measurement else { return false }
        return measurement.kilograms >= Self.onBoardThresholdKilograms
    }

    var isConnected: Bool {
        switch phase {
        case .zeroing, .measuring: return true
        default: return false
        }
    }

    func start() {
        guard timer == nil else { return }
        transport.start()
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        transport.stop()
    }

    /// The "Zero" button.
    func zero() {
        guard phase == .measuring else { return }
        filter.zero()
    }

    /// Marks the current step-on as recorded (or not, after an undo) so it is saved only once.
    func markSaved(_ saved: Bool = true) {
        recordedThisStepOn = saved
    }

    // MARK: Sampling

    private func tick() {
        guard session.state == .streaming, let raw = session.latestKilograms else {
            if let connectedAt, Date().timeIntervalSince(connectedAt) > Self.handshakeTimeout {
                lastProblem = "The Balance Board did not respond. Press SYNC again."
                transport.reconnect()
            }
            return
        }

        if case .zeroing = phase {
            collectZeroSample(raw)
            return
        }

        let measurement = filter.add(raw)
        self.measurement = measurement
        if measurement.kilograms < Self.onBoardThresholdKilograms {
            stableReported = false
            stableReading = nil
            if recordedThisStepOn { recordedThisStepOn = false }
        } else if measurement.stars == WeightFilter.maxStars, !stableReported {
            stableReported = true
            stableReading = StableReading(kilograms: measurement.kilograms)
        }
    }

    /// Averages a couple of seconds of readings from the empty board to find zero. Unlike the
    /// original, it waits if someone is standing on the board, so the journal never gets a
    /// reading that was zeroed with a person on it.
    private func collectZeroSample(_ raw: Double) {
        zeroSamples.append(raw)
        if zeroSamples.count > Self.zeroSampleCount { zeroSamples.removeFirst() }
        guard zeroSamples.count == Self.zeroSampleCount,
              let low = zeroSamples.min(), let high = zeroSamples.max() else { return }
        let mean = zeroSamples.reduce(0, +) / Double(zeroSamples.count)
        let occupied = abs(mean) > 5
        phase = .zeroing(waitingForEmptyBoard: occupied)
        guard !occupied, high - low < 1 else { return }
        filter.reset(zeroKilograms: mean)
        measurement = nil
        stableReported = false
        recordedThisStepOn = false
        phase = .measuring
    }

    private func sessionStateChanged(_ state: BalanceBoardSession.State) {
        switch state {
        case .streaming:
            connectedAt = nil
            lastProblem = nil
            zeroSamples = []
            phase = .zeroing(waitingForEmptyBoard: false)
        case .failed(let message):
            connectedAt = nil
            lastProblem = message
            transport.reconnect(ignoringCurrentDevice: true)
        case .idle, .initializing:
            break
        }
    }
}

extension ScaleModel: BluetoothTransportDelegate {
    func transport(_ transport: BluetoothTransport, didChangeStatus status: BluetoothTransport.Status) {
        switch status {
        case .idle:
            phase = .idle
        case .unavailable(let message):
            phase = .bluetoothUnavailable(message)
        case .searching:
            phase = .searching
        case .connecting(let name), .connected(let name):
            if !isConnected { phase = .connecting(name) }
        }
    }

    func transportDidConnect(_ transport: BluetoothTransport) {
        connectedAt = Date()
        session.start()
    }

    func transport(_ transport: BluetoothTransport, didReceive report: [UInt8]) {
        session.handle(report: report)
    }

    func transportDidDisconnect(_ transport: BluetoothTransport) {
        session.stop()
        connectedAt = nil
        measurement = nil
        stableReading = nil
        if isConnected { phase = .searching }
    }
}
