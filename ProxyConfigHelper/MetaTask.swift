//
//  MetaTask.swift
//  com.metacubex.ClashX.ProxyConfigHelper


import Cocoa

class MetaTask: NSObject {
    
    struct MetaCurl: Decodable {
        let hello: String
    }
    
    let proc = Process()
    
    var timer: DispatchSourceTimer?
    let timerQueue = DispatchQueue(label: Bundle.main.bundleIdentifier! + ".timer")
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
	@objc func start(_ path: String,
					 confPath: String,
					 confFilePath: String,
					 confJSON: String,
					 result: @escaping (String?) -> Void) {
        
        var resultReturned = false
        
        func returnResult(_ re: String) {
            guard !resultReturned else { return }
            timer?.cancel()
            timer = nil
            resultReturned = true
			result(re)
        }
		
		proc.executableURL = .init(fileURLWithPath: path)
        proc.currentDirectoryURL = .init(fileURLWithPath: confPath)
        
        var args = [
            "-d",
            confPath
        ]
        
        if confFilePath != "" {
            args.append(contentsOf: [
                "-f",
                confFilePath
            ])
        }
        
        killOldProc()
        
		do {
			guard let confData = confJSON.data(using: .utf8), 
					var serverResult = try? JSONDecoder().decode(MetaServer.self, from: confData) else {
				returnResult("Can't decode config file.")
				return
			}
            
            var environment = ProcessInfo.processInfo.environment
            environment["SAFE_PATHS"] = serverResult.safePaths

            self.proc.environment = environment
			
			self.proc.arguments = args
			self.proc.qualityOfService = .userInitiated
			
			let pipe = Pipe()
			self.outputPipe = pipe
			var logs = [String]()
			
			let errPipe = Pipe()
			self.errorPipe = errPipe
			var errorLogs = [String]()
			
			pipe.fileHandleForReading.readabilityHandler = { pipe in
				guard let output = String(data: pipe.availableData, encoding: .utf8),
					  !resultReturned else {
					return
				}
				
				output.split(separator: "\n").map {
					self.formatMsg(String($0))
				}.forEach {
					logs.append($0)
					if $0.contains("External controller listen error:") || $0.contains("External controller serve error:") {
						returnResult($0)
					}
					
					/*
					 if let range = $0.range(of: "RESTful API listening at: ") {
					 let addr = String($0[range.upperBound..<$0.endIndex])
					 guard addr.split(separator: ":").count == 2,
					 let port = Int(addr.split(separator: ":")[1]) else {
					 returnResult("Not found RESTful API port.")
					 return
					 }
					 let testLP = self.testListenPort(port)
					 if testLP.pid != 0,
					 testLP.pid == self.proc.processIdentifier,
					 testLP.addr == addr {
					 serverResult.log = logs.joined(separator: "\n")
					 returnResult(serverResult.jsonString())
					 } else {
					 returnResult("Check RESTful API pid failed.")
					 }
					 }
					 */
					
					if $0.contains("RESTful API listening at:") {
						if self.testExternalController(serverResult) {
							serverResult.log = logs.joined(separator: "\n")
							returnResult(serverResult.jsonString())
						} else {
							returnResult("Check RESTful API failed.")
						}
					}
				}
			}
			
			
			errPipe.fileHandleForReading.readabilityHandler = { pipe in
				guard let output = String(data: pipe.availableData, encoding: .utf8) else {
					return
				}
				output.split(separator: "\n").forEach {
					errorLogs.append(String($0))
				}
			}
			
			
			self.proc.standardError = errPipe
			self.proc.standardOutput = pipe
			
			self.proc.terminationHandler = { proc in
				
				guard !resultReturned else {
					guard errorLogs.count > 0 else { return }
					
					errorLogs.append("terminationStatus: \(proc.terminationStatus)")
					errorLogs.append("terminationReason: \(proc.terminationReason)")
					
					let data = errorLogs.joined(separator: "\n").data(using: .utf8)
					
					let url = URL(fileURLWithPath: confPath)
						.appendingPathComponent("logs")
					
					let fm = FileManager.default
					try? fm.createDirectory(atPath: url.path, withIntermediateDirectories: true)
					
					let fileName = {
						let dateformat = DateFormatter()
						dateformat.dateFormat = "yyyy-MM-dd_HH-mm-ss"
						let s = dateformat.string(from: Date())
						return "meta_core_crash_\(s).log"
					}()
					
					fm.createFile(atPath: url.appendingPathComponent(fileName).path, contents: data)
					return
				}
				
				
				let data = pipe.fileHandleForReading.readDataToEndOfFile()
				guard let string = String(data: data, encoding: String.Encoding.utf8) else {
					
					returnResult("Meta process terminated, no found output.")
					return
				}
				
				var results = string.split(separator: "\n").map(String.init).map(self.formatMsg(_:))
				
                if results.count == 0 {
                    results = logs.map(self.formatMsg(_:))
                }
                
				returnResult(results.joined(separator: "\n"))
			}
			
			self.timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
			self.timer?.schedule(deadline: .now(), repeating: .milliseconds(500))
			self.timer?.setEventHandler {
				guard self.testExternalController(serverResult) else {
					return
				}
				serverResult.log = logs.joined(separator: "\n")
				returnResult(serverResult.jsonString())
			}
			
			DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
				serverResult.log = logs.joined(separator: "\n")
				returnResult(serverResult.jsonString())
			}
			
			try self.proc.run()
			self.timer?.resume()
		} catch let error {
			returnResult("Start meta error, \(error.localizedDescription).")
		}
	
    }

    @objc func stop() {
        timer?.cancel()
        timer = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil

        DispatchQueue.main.async {
            guard self.proc.isRunning else { return }
            let killer = Process()
            killer.executableURL = .init(fileURLWithPath: "/bin/kill")
            killer.arguments = ["-9", "\(self.proc.processIdentifier)"]
            try? killer.run()
            killer.waitUntilExit()
        }
    }
    

    
    func killOldProc() {
        let proc = Process()
        proc.executableURL = .init(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["com.metacubex.ClashX.ProxyConfigHelper.meta"]
        try? proc.run()
        proc.waitUntilExit()
    }
    
    @objc func getUsedPorts(_ result: @escaping (String?) -> Void) {
        let proc = Process()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.executableURL = .init(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "lsof -nP -iTCP -sTCP:LISTEN | grep LISTEN"]
        try? proc.run()
        proc.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else {
            result("")
            return
        }
        
        let usedPorts = str.split(separator: "\n").compactMap { str -> Int? in
            let line = str.split(separator: " ").map(String.init)
            guard line.count == 10,
            let port = line[8].components(separatedBy: ":").last else { return nil }
            return Int(port)
        }.map(String.init).joined(separator: ",")
        
        result(usedPorts)
    }
    
    func testListenPort(_ port: Int) -> (pid: Int32, addr: String) {
        let proc = Process()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.executableURL = .init(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "lsof -nP -iTCP:\(port) -sTCP:LISTEN | grep LISTEN"]
        try? proc.run()
        proc.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8),
              str.split(separator: " ").map(String.init).count == 10 else {
            return (0, "")
        }
        
        let re = str.split(separator: " ").map(String.init)
        let pid = re[1]
        let addr = re[8]
        
        return (Int32(pid) ?? 0, addr)
    }
    
    func testExternalController(_ server: MetaServer) -> Bool {
        let proc = Process()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.executableURL = .init(fileURLWithPath: "/usr/bin/curl")
        var args = [server.externalController]
        if server.secret != "" {
            args.append(contentsOf: [
                "--header",
                "Authorization: Bearer \(server.secret)"
            ])
        }
        
        proc.arguments = args
        try? proc.run()
        proc.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        
        guard let str = try? JSONDecoder().decode(MetaCurl.self, from: data),
			  (str.hello == "clash.meta" || str.hello == "mihomo") else {
            return false
        }
        return true
    }
    
    func formatMsg(_ msg: String) -> String {
        let msgs = msg.split(separator: " ", maxSplits: 2).map(String.init)
        
        guard msgs.count == 3,
              msgs[1].starts(with: "level"),
              msgs[2].starts(with: "msg") else {
            return msg
        }
        
        let level = msgs[1].replacingOccurrences(of: "level=", with: "")
        var re = msgs[2].replacingOccurrences(of: "msg=\"", with: "")
        
        while re.last == "\"" || re.last == "\n" {
            re.removeLast()
        }
        
        if re.contains("time=") {
            print(re)
        }
        
        return "[\(level)] \(re)"
    }
    
    func parseConfFile(_ confPath: String, confFilePath: String) -> MetaServer? {
        let fileURL = confFilePath == "" ? URL(fileURLWithPath: confPath).appendingPathComponent("config.yaml", isDirectory: false) : URL(fileURLWithPath: confFilePath)
        
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = content.split(separator: "\n").map(String.init)
        
        func find(_ key: String) -> String {
            var re = lines.first(where: { $0.starts(with: "\(key): ") })?.dropFirst("\(key): ".count) ?? ""
            
            if re.hasPrefix("\"") && re.hasSuffix("\"")
                || re.hasPrefix("'") && re.hasSuffix("'") {
                re.removeLast()
                re.removeFirst()
            }
            return String(re)
        }
        
        return MetaServer(externalController: find("external-controller"),
                          secret: find("secret"))
    }
}
