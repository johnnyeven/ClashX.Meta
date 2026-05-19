//
//  ProxyConfigHelper.swift
//  com.metacubex.ClashX.ProxyConfigHelper
//
//  Copyright © 2024 west2online. All rights reserved.
//

import Cocoa
import os.log

class ProxyConfigHelper: NSObject, NSXPCListenerDelegate {
	
	private var listener: NSXPCListener
	private var connections = [NSXPCConnection]()
	private var shouldQuitCheckInterval = 2.0
	var shouldQuit = false
	var clientMonitors = [pid_t: DispatchSourceProcess]()
	
	let metaTask = MetaTask()
	private let metaDNS = MetaDNS()
	
	override init() {
		shouldQuit = false
		listener = NSXPCListener(machServiceName: "com.metacubex.ClashX.ProxyConfigHelper")
		super.init()
		listener.delegate = self
	}
	
	func run() {
		listener.resume()
		os_log("ProxyConfigHelper running")
		while !shouldQuit {
			RunLoop.current.run(until: Date(timeIntervalSinceNow: shouldQuitCheckInterval))
		 }
	}
	
	
	// MARK: - NSXPCListenerDelegate
	
	func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
		
		guard isValid(connection: newConnection) else {
			return false
		}
		
		newConnection.exportedInterface = NSXPCInterface(with: ProxyConfigRemoteProcessProtocol.self)
		newConnection.exportedObject = self
		let clientPID = newConnection.processIdentifier
		monitorClientProcess(pid: clientPID)

		newConnection.invalidationHandler = { [weak self] in
			guard let self = self else { return }
			guard let index = self.connections.firstIndex(of: newConnection) else { return }
			self.connections.remove(at: index)

			if self.connections.isEmpty {
				self.requestQuit()
			}
		}
		
		connections.append(newConnection)
		newConnection.resume()
		
		return true
	}
	
	func removeConnections(forClientPID pid: pid_t) {
		connections.removeAll { $0.processIdentifier == pid }
	}

	var hasActiveConnections: Bool {
		!connections.isEmpty
	}

	private func isValid(connection: NSXPCConnection) -> Bool {
		guard let app = NSRunningApplication(processIdentifier: connection.processIdentifier),
			  let bundleIdentifier = app.bundleIdentifier,
			  bundleIdentifier == "com.metacubex.ClashX.meta"
		else {
			return false
		}
		return true
	}
	
}

extension ProxyConfigHelper: ProxyConfigRemoteProcessProtocol {
	func getVersion(reply: @escaping (String) -> Void) {
		let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
		reply(version)
	}

	
	func enableProxy(port: Int, socksPort: Int, pac: String?, filterInterface: Bool, ignoreList: [String], reply: @escaping (String?) -> Void) {
		DispatchQueue.main.async {
			let tool = ProxySettingTool()
			tool.enableProxyWithport(Int32(port), socksPort: Int32(socksPort), pacUrl: pac ?? "", filterInterface: filterInterface, ignoreList: ignoreList)
			reply(nil)
		}
	}
	
	func disableProxy(filterInterface: Bool, reply: @escaping (String?) -> Void) {
		DispatchQueue.main.async {
			let tool = ProxySettingTool()
			tool.disableProxyWithfilterInterface(filterInterface)
			reply(nil)
		}
	}
	
	func restoreProxy(currentPort: Int, socksPort: Int, info: [String : Any], filterInterface: Bool, reply: @escaping (String?) -> Void) {
		DispatchQueue.main.async {
			let tool = ProxySettingTool()
			tool.restoreProxySetting(info, currentPort: Int32(currentPort), currentSocksPort: Int32(socksPort), filterInterface: filterInterface)
			reply(nil)
		}
	}
	
	func getCurrentProxySetting(reply: @escaping ([String : Any]) -> Void) {
		DispatchQueue.main.async {
			let info = ProxySettingTool.currentProxySettings()
			reply(info as? [String: Any] ?? [:])
		}
	}
	
	func startMeta(path: String, 
				   confPath: String,
				   confFilePath: String,
				   confJSON: String,
				   reply: @escaping (String?) -> Void) {
		DispatchQueue.main.async {
			self.metaTask.start(path, confPath: confPath, confFilePath: confFilePath, confJSON: confJSON, result: reply)
		}
	}
	
	func stopMeta() {
		DispatchQueue.main.async {
			self.metaTask.stop()
		}
	}
	
	func getUsedPorts(reply: @escaping (String?) -> Void) {
		DispatchQueue.main.async {
			self.metaTask.getUsedPorts(reply)
		}
	}
	
	func updateTun(state: Bool, dns: String) {
		DispatchQueue.main.async {
			self.metaDNS.setCustomDNS(dns)
			if state {
				self.metaDNS.hijackDNS()
			} else {
				self.metaDNS.revertDNS()
			}
			self.metaDNS.flushDnsCache()
		}
	}
    
    func flushDnsCache() {
        DispatchQueue.main.async {
            self.metaDNS.flushDnsCache()
        }
    }

	func shutdown(reply: @escaping () -> Void) {
		DispatchQueue.main.async {
			self.metaTask.stop()
			self.requestQuit()
			reply()
		}
	}
    
}
