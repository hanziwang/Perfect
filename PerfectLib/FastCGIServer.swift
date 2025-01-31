//
//  FastCGIServer.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 7/6/15.
//	Copyright (C) 2015 PerfectlySoft, Inc.
//
//	This program is free software: you can redistribute it and/or modify
//	it under the terms of the GNU Affero General Public License as
//	published by the Free Software Foundation, either version 3 of the
//	License, or (at your option) any later version, as supplemented by the
//	Perfect Additional Terms.
//
//	This program is distributed in the hope that it will be useful,
//	but WITHOUT ANY WARRANTY; without even the implied warranty of
//	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//	GNU Affero General Public License, as supplemented by the
//	Perfect Additional Terms, for more details.
//
//	You should have received a copy of the GNU Affero General Public License
//	and the Perfect Additional Terms that immediately follow the terms and
//	conditions of the GNU Affero General Public License along with this
//	program. If not, see <http://www.perfect.org/AGPL_3_0_With_Perfect_Additional_Terms.txt>.
//


import Darwin

/// A server for the FastCGI protocol.
/// Listens for requests on either a named pipe or a TCP socket. Once started, it does not stop or return outside of a catastrophic error.
/// When a request is received, the server will instantiate a `WebRequest`/`WebResponse` pair and they will handle the remainder of the request.
public class FastCGIServer {
	
	private var net: NetTCP?
	
	/// Empty public initializer
	public init() {
		
	}
	
	/// Start the server on the indicated named pipe
	public func start(namedPipe: String) throws {
		if access(namedPipe, F_OK) != -1 {
			// exists. remove it
			unlink(namedPipe)
		}
		let pipe = NetNamedPipe()
		pipe.initSocket()
		try pipe.bind(namedPipe)
		pipe.listen()
		chmod(namedPipe, mode_t(S_IRWXU|S_IRWXO|S_IRWXG))
		
		self.net = pipe
		
		defer { pipe.close() }
		
		print("Starting FastCGI server on named pipe "+namedPipe)
		
		self.start()
	}
	
	/// Start the server on the indicated TCP port and optional address
	public func start(port: UInt16, bindAddress: String = "0.0.0.0") throws {
		let socket = NetTCP()
		socket.initSocket()
		try socket.bind(port, address: bindAddress)
		socket.listen()
		
		defer { socket.close() }
		
		print("Starting FastCGi server on \(bindAddress):\(port)")
		
		self.start()
	}
	
	func start() {
		
		if let n = self.net {
			
			n.forEachAccept {
				(net: NetTCP?) -> () in
				
				if let n = net {
					split_thread {
						self.handleConnection(n)
					}
				}
			}
		}
	}
	
	func handleConnection(net: NetTCP) {
		let fcgiReq = FastCGIRequest(net: net)
		readRecord(fcgiReq)
	}
	
	func readRecord(fcgiReq: FastCGIRequest) {
		
		fcgiReq.readRecord {
			(r:FastCGIRecord?) -> () in
			
			guard let record = r else {
				fcgiReq.connection.close()
				return // died. timed out. errorered
			}
			
			self.handleRecord(fcgiReq, fcgiRecord: record)
		}
		
	}
	
	func handleRecord(fcgiReq: FastCGIRequest, fcgiRecord: FastCGIRecord) {
		switch fcgiRecord.recType {
		
		case FCGI_BEGIN_REQUEST:
			// FastCGIBeginRequestBody UInt16 role, UInt8 flags
			let role: UInt16 = ntohs((UInt16(fcgiRecord.content![1]) << 8) | UInt16(fcgiRecord.content![0]))
			let flags: UInt8 = fcgiRecord.content![2]
			fcgiReq.requestParams["L_FCGI_ROLE"] = String(role)
			fcgiReq.requestParams["L_FCGI_FLAGS"] = String(flags)
			fcgiReq.requestId = fcgiRecord.requestId
		case FCGI_PARAMS:
			if fcgiRecord.contentLength > 0 {
				
				let bytes = fcgiRecord.content!
				var idx = 0
				
				repeat {
					// sizes are either one byte or 4
					var sz = Int32(bytes[idx++])
					if (sz & 0x80) != 0 { // name length
						sz = (sz & 0x7f) << 24
						sz += (Int32(bytes[idx++]) << 16)
						sz += (Int32(bytes[idx++]) << 8)
						sz += Int32(bytes[idx++])
					}
					var vsz = Int32(bytes[idx++])
					if (vsz & 0x80) != 0 { // value length
						vsz = (vsz & 0x7f) << 24
						vsz += (Int32(bytes[idx++]) << 16)
						vsz += (Int32(bytes[idx++]) << 8)
						vsz += Int32(bytes[idx++])
					}
					if sz > 0 {
						let idx2 = Int(idx + sz)
						let name = UTF8Encoding.encode(bytes[idx..<idx2])
						let idx3 = idx2 + Int(vsz)
						let value = UTF8Encoding.encode(bytes[idx2..<idx3])
						
						fcgiReq.requestParams[name] = value
					
						idx = idx3
					}
				} while idx < bytes.count
				
			}
		case FCGI_STDIN:
			if fcgiRecord.contentLength > 0 {
				fcgiReq.putStdinData(fcgiRecord.content!)
			} else { // done initiating the request. run with it
				runRequest(fcgiReq)
				return
			}
			
		case FCGI_DATA:
			if fcgiRecord.contentLength > 0 {
				fcgiReq.requestParams["L_FCGI_DATA"] = UTF8Encoding.encode(fcgiRecord.content!)
			}
			
		case FCGI_X_STDIN:
			
			if Int(fcgiRecord.contentLength) == sizeof(UInt32) {
				
				let one = UInt32(fcgiRecord.content![0])
				let two = UInt32(fcgiRecord.content![1])
				let three = UInt32(fcgiRecord.content![2])
				let four = UInt32(fcgiRecord.content![3])
				
				let size = ntohl((four << 24) + (three << 16) + (two << 8) + one)
				
				readXStdin(fcgiReq, size: Int(size))
				return
			}
			
		default:
			print("Unhandled FastCGI record type \(fcgiRecord.recType)")
			
		}
		fcgiReq.lastRecordType = fcgiRecord.recType
		readRecord(fcgiReq)
	}
	
	func readXStdin(fcgiReq: FastCGIRequest, size: Int) {
		
		fcgiReq.connection.readSomeBytes(size) {
			(b:[UInt8]?) -> () in
			
			guard let bytes = b else {
				fcgiReq.connection.close()
				return // died. timed out. errorered
			}
			
			fcgiReq.putStdinData(bytes)
			
			let remaining = size - bytes.count
			if  remaining == 0 {
				fcgiReq.lastRecordType = FCGI_STDIN
				self.readRecord(fcgiReq)
			} else {
				self.readXStdin(fcgiReq, size: remaining)
			}
		}
	}
	
	func runRequest(fcgiReq: FastCGIRequest) {
		
		let request = WebRequest(fcgiReq)
		let response = WebResponse(fcgiReq, request: request)
		
		response.respond()
		
		let status = response.appStatus
		
		let finalBytes = fcgiReq.makeEndRequestBody(Int(fcgiReq.requestId), appStatus: status, protocolStatus: FCGI_REQUEST_COMPLETE)
		fcgiReq.writeBytes(finalBytes)
		fcgiReq.connection.close()
	}
}




















