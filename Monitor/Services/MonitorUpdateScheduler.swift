import Foundation

enum MonitorRefreshMode {
    case foreground
    case background

    nonisolated(unsafe) static var current: MonitorRefreshMode = .background

    nonisolated var interval: TimeInterval {
        switch self {
        case .foreground: 2
        case .background: 60
        }
    }
}

final class MonitorUpdateScheduler {
    private var fastTimer: DispatchSourceTimer?
    private var mediumTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.hyco.monitor.scheduler", qos: .utility)
    private var mode: MonitorRefreshMode = .background

    var onFastTick: (() -> Void)?
    var onMediumTick: (() -> Void)?

    func start(mode: MonitorRefreshMode = .background, fireImmediately: Bool = true) {
        stop()
        self.mode = mode
        MonitorRefreshMode.current = mode
        fastTimer = makeTimer(interval: mode.interval, handler: { [weak self] in self?.onFastTick?() })
        mediumTimer = makeTimer(interval: mode.interval, handler: { [weak self] in self?.onMediumTick?() })

        if fireImmediately {
            onFastTick?()
            onMediumTick?()
        }
    }

    func setMode(_ nextMode: MonitorRefreshMode, fireImmediately: Bool) {
        guard nextMode != mode else {
            if fireImmediately {
                onFastTick?()
                onMediumTick?()
            }
            return
        }
        start(mode: nextMode, fireImmediately: fireImmediately)
    }

    func stop() {
        fastTimer?.cancel()
        mediumTimer?.cancel()
        fastTimer = nil
        mediumTimer = nil
    }

    private func makeTimer(interval: TimeInterval, handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    deinit {
        stop()
    }
}
