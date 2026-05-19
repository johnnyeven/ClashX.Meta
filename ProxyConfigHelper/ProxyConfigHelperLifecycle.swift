//
//  ProxyConfigHelperLifecycle.swift
//  com.metacubex.ClashX.ProxyConfigHelper
//
//  Copyright © 2026 west2online. All rights reserved.
//

import Cocoa
import os.log

extension ProxyConfigHelper {
    func monitorClientProcess(pid: pid_t) {
        guard clientMonitors[pid] == nil else { return }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.handleClientExit(pid: pid)
        }
        source.setCancelHandler { [weak self] in
            self?.clientMonitors.removeValue(forKey: pid)
        }
        clientMonitors[pid] = source
        source.resume()
    }

    func handleClientExit(pid: pid_t) {
        os_log("ProxyConfigHelper client exited pid %{public}d", pid)
        clientMonitors[pid]?.cancel()
        clientMonitors.removeValue(forKey: pid)

        metaTask.stop()
        removeConnections(forClientPID: pid)

        if !hasActiveConnections {
            requestQuit()
        }
    }

    func requestQuit() {
        guard !shouldQuit else { return }
        shouldQuit = true
        os_log("ProxyConfigHelper shouldQuit")
    }
}
