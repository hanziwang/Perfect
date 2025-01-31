//
//  HTTPServer.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 2015-10-23.
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

internal let READ_SIZE = 1024
internal let READ_TIMEOUT = 5.0
internal let HTTP_LF = UInt8(10)
internal let HTTP_CR = UInt8(13)
internal let HTTP_COLON = UInt8(58)
internal let HTTP_SPACE = UnicodeScalar(32)
internal let HTTP_QUESTION = UnicodeScalar(63)

/// Stand-alone HTTP server. Provides the same WebConnection based interface as the FastCGI server.
public class HTTPServer {
	
	private var net: NetTCP?
	
	/// The directory in which web documents are sought.
	public let documentRoot: String
	/// The port on which the server is listening.
	public var serverPort: UInt16 = 0
	/// The local address on which the server is listening. The default of 0.0.0.0 indicates any local address.
	public var serverAddress = "0.0.0.0"
	
	/// Initialize the server with a document root.
	/// - parameter documentRoot: The document root for the server.
	public init(documentRoot: String) {
		self.documentRoot = documentRoot
	}
	
	/// Start the server on the indicated TCP port and optional address.
	/// - parameter port: The port on which to bind.
	/// - parameter bindAddress: The local address on which to bind.
	public func start(port: UInt16, bindAddress: String = "0.0.0.0") throws {
		
		self.serverPort = port
		self.serverAddress = bindAddress
		
		let socket = NetTCP()
		socket.initSocket()
		try socket.bind(port, address: bindAddress)
		socket.listen()
		
		self.net = socket
		
		defer { socket.close() }
		
		print("Starting HTTP server on \(bindAddress):\(port)")
		
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
	
	/// Stop the server by closing the accepting TCP socket. Calling this will cause the server to break out of the otherwise blocking `start` function.
	public func stop() {
		if let n = self.net {
			self.net = nil
			n.close()
		}
	}
	
	func handleConnection(net: NetTCP) {
		let req = HTTPWebConnection(net: net)
		req.readRequest { requestOk in
			if requestOk {
				self.runRequest(req)
			} else {
				req.connection.close()
			}
		}
	}
	
	func sendFile(req: HTTPWebConnection, file: File) {
		
		defer {
			file.close()
		}
		
		var size = file.size()
		let readSize = READ_SIZE * 16
		req.setStatus(200, msg: "OK")
		req.writeHeaderLine("Content-length: \(size)")
		req.writeHeaderLine("Content-type: \(MimeType.forExtension(file.path().pathExtension))")
		req.pushHeaderBytes()
		
		do {
			while size > 0 {
				
				let bytes = try file.readSomeBytes(min(size, readSize))
				req.writeBodyBytes(bytes)
				size -= bytes.count
			}
		} catch {
			req.connection.close()
		}
	}
	
	// returns true if the request pointed to a file which existed
	// and the request was properly handled
	func runRequest(req: HTTPWebConnection, withPathInfo: String) -> Bool {
		let filePath = self.documentRoot + withPathInfo
		let ext = withPathInfo.pathExtension.lowercaseString
		if ext == MOUSTACHE_EXTENSION {
			
			if !File(filePath).exists() {
				return false
			}
			
			// PATH_INFO may have been altered. set it to this version
			req.requestParams["PATH_INFO"] = withPathInfo
			
			let request = WebRequest(req)
			let response = WebResponse(req, request: request)
			response.respond()
			return true
			
		} else if ext.isEmpty {
			
			if !withPathInfo.hasSuffix(".") && self.runRequest(req, withPathInfo: withPathInfo + ".\(MOUSTACHE_EXTENSION)") {
				return true
			}
			
			let pathDir = Dir(filePath)
			if pathDir.exists() {
				
				if self.runRequest(req, withPathInfo: withPathInfo + "/index.\(MOUSTACHE_EXTENSION)") {
					return true
				}
				
				if self.runRequest(req, withPathInfo: withPathInfo + "/index.html") {
					return true
				}
			}
			
		} else {
			
			let file = File(filePath)
			
			if file.exists() {
				self.sendFile(req, file: file)
				return true
			}
		}
		return false
	}
	
	func runRequest(req: HTTPWebConnection) {
		guard let pathInfo = req.requestParams["PATH_INFO"] else {
			
			req.setStatus(500, msg: "INVALID")
			req.pushHeaderBytes()
			req.connection.close()
			return
		}
		
		req.requestParams["PERFECTSERVER_DOCUMENT_ROOT"] = self.documentRoot
		
		if !self.runRequest(req, withPathInfo: pathInfo) {
			req.setStatus(404, msg: "NOT FOUND")
			let msg = "The file \"\(pathInfo)\" was not found.".utf8
			req.writeHeaderLine("Content-length: \(msg.count)")
			req.writeBodyBytes([UInt8](msg))
		}
		
		if req.httpOneOne {
			self.handleConnection(req.connection)
		} else {
			req.connection.close()
		}
	}
	
	class HTTPWebConnection : WebConnection {
		
		typealias OkCallback = (Bool) -> ()
		
		var connection: NetTCP
		var requestParams: Dictionary<String, String> = Dictionary<String, String>()
		var stdin: [UInt8]? = nil
		var mimes: MimeReader? = nil
		
		var statusCode: Int
		var statusMsg: String
		
		var header: String = ""
		var wroteHeader: Bool = false
		
		var workingBuffer = [UInt8]()
		var workingBufferOffset = 0
		var lastHeaderKey = "" // for handling continuations
		
		var contentType: String? {
			return self.requestParams["CONTENT_TYPE"]
		}
		
		var httpOneOne: Bool {
			return (self.requestParams["SERVER_PROTOCOL"] ?? "").containsString("1.1")
		}
		
		var httpVersion: String {
			return self.requestParams["SERVER_PROTOCOL"] ?? "HTTP/1.0"
		}
		
		init(net: NetTCP) {
			self.connection = net
			self.statusCode = 200
			self.statusMsg = "OK"
		}
		
		func setStatus(code: Int, msg: String) {
			self.statusCode = code
			self.statusMsg = msg
		}
		
		func getStatus() -> (Int, String) {
			return (self.statusCode, self.statusMsg)
		}
		
		func transformHeaderName(name: String) -> String {
			switch name {
			case "Host":
				return "HTTP_HOST"
			case "Connection":
				return "HTTP_CONNECTION"
			case "Keep-Alive":
				return "HTTP_KEEP_ALIVE"
			case "User-Agent":
				return "HTTP_USER_AGENT"
			case "Referer", "Referrer":
				return "HTTP_REFERER"
			case "Accept":
				return "HTTP_ACCEPT"
			case "Content-Length":
				return "CONTENT_LENGTH"
			case "Content-Type":
				return "CONTENT_TYPE"
			case "Cookie":
				return "HTTP_COOKIE"
			case "Accept-Language":
				return "HTTP_ACCEPT_LANGUAGE"
			case "Accept-Encoding":
				return "HTTP_ACCEPT_ENCODING"
			case "Accept-Charset":
				return "HTTP_ACCEPT_CHARSET"
			case "Authorization":
				return "HTTP_AUTHORIZATION"
			default:
				return "HTTP_" + name.uppercaseString.stringByReplacingOccurrencesOfString("-", withString: "_")
			}
		}
		
		func readRequest(callback: OkCallback) {
			
			self.readHeaders { requestOk in
				if requestOk {
					
					self.readBody(callback)
					
				} else {
					callback(false)
				}
			}
		}
		
		func readHeaders(callback: OkCallback) {
			self.connection.readSomeBytes(READ_SIZE) {
				(b:[UInt8]?) in
				self.didReadHeaderData(b, callback: callback)
			}
		}
		
		func readBody(callback: OkCallback) {
			guard let cl = self.requestParams["CONTENT_LENGTH"] where Int(cl) > 0 else {
				callback(true)
				return
			}
			
			let workingDiff = self.workingBuffer.count - self.workingBufferOffset
			if workingDiff > 0 {
				// data remaining in working buffer
				self.putStdinData(Array(self.workingBuffer.suffix(workingDiff)))
			}
			self.workingBuffer.removeAll()
			self.workingBufferOffset = 0
			self.readBody((Int(cl) ?? 0) - workingDiff, callback: callback)
		}
		
		func readBody(size: Int, callback: OkCallback) {
			guard size > 0 else {
				callback(true)
				return
			}
			self.connection.readSomeBytes(size) {
				(b:[UInt8]?) in
				
				if b == nil {
					self.connection.readBytesFully(1, timeoutSeconds: READ_TIMEOUT) {
						(b:[UInt8]?) in
						
						guard b != nil else {
							callback(false)
							return
						}
						
						self.putStdinData(b!)
						self.readBody(size - 1, callback: callback)
					}
				} else {
					self.putStdinData(b!)
					self.readBody(size - b!.count, callback: callback)
				}
			}
		}
		
		func processRequestLine(h: ArraySlice<UInt8>) -> Bool {
			let lineStr = UTF8Encoding.encode(h)
			var method = "", uri = "", pathInfo = "", queryString = "", hvers = ""
			
			var gen = lineStr.unicodeScalars.generate()
			
			// METHOD PATH_INFO[?QUERY] HVERS
			while let c = gen.next() {
				if HTTP_SPACE == c {
					break
				}
				method.append(c)
			}
			var gotQuest = false
			while let c = gen.next() {
				if HTTP_SPACE == c {
					break
				}
				if gotQuest {
					queryString.append(c)
				} else if HTTP_QUESTION == c {
					gotQuest = true
				} else {
					pathInfo.append(c)
				}
				uri.append(c)
			}
			while let c = gen.next() {
				hvers.append(c)
			}
			
			self.requestParams["REQUEST_METHOD"] = method
			self.requestParams["REQUEST_URI"] = uri
			self.requestParams["PATH_INFO"] = pathInfo
			self.requestParams["QUERY_STRING"] = queryString
			self.requestParams["SERVER_PROTOCOL"] = hvers
			self.requestParams["GATEWAY_INTERFACE"] = "PerfectHTTPD"
			// !FIX! 
			// REMOTE_ADDR, REMOTE_PORT, SERVER_ADDR, SERVER_PORT
			return true
		}
		
		func processHeaderLine(h: ArraySlice<UInt8>) -> Bool {
			for i in h.startIndex..<h.endIndex {
				if HTTP_COLON == h[i] {
					let headerKey = transformHeaderName(UTF8Encoding.encode(h[h.startIndex..<i]))
					var i2 = i + 1
					while i2 < h.endIndex {
						if !ICU.isWhiteSpace(UnicodeScalar(h[i2])) {
							break
						}
						i2 += 1
					}
					let headerValue = UTF8Encoding.encode(h[i2..<h.endIndex])
					self.requestParams[headerKey] = headerValue
					self.lastHeaderKey = headerKey
					return true
				}
			}
			return false
		}
		
		func processHeaderContinuation(h: ArraySlice<UInt8>) -> Bool {
			guard !self.lastHeaderKey.isEmpty else {
				return false
			}
			guard let found = self.requestParams[self.lastHeaderKey] else {
				return false
			}
			for i in 0..<h.count {
				if !ICU.isWhiteSpace(UnicodeScalar(h[i])) {
					let extens = UTF8Encoding.encode(h[i..<h.count])
					self.requestParams[self.lastHeaderKey] = found + " " + extens
					return true
				}
			}
			return false
		}
		
		func scanWorkingBuffer(callback: OkCallback) {
			// data was just added to workingBuffer
			// look for header end or possible end of headers
			// handle case of buffer break in between CR-LF pair. first new byte will be LF. skip it
			if self.workingBuffer[self.workingBufferOffset] == HTTP_LF {
				self.workingBufferOffset += 1
			}
			var lastWasCr = false
			var startingOffset = self.workingBufferOffset
			for i in startingOffset..<self.workingBuffer.count {
				
				let c = self.workingBuffer[i]
				
				guard false == lastWasCr || HTTP_LF == c else { // malformed header
					callback(false)
					return
				}
				
				if lastWasCr { // and c is LF
					lastWasCr = false
					// got a header or possibly end of headers
					let segment = self.workingBuffer[startingOffset ..< (i-1)]
					// if segment is empty then it's the end of headers
					// if segment begins with a space then it's a continuation of the previous header
					// otherwise it's a new header
					
					let first = self.workingBufferOffset == 0
					
					startingOffset = i + 1
					self.workingBufferOffset = startingOffset
					
					if segment.count == 0 {
						callback(true)
						return
					} else if ICU.isWhiteSpace(UnicodeScalar(segment.first!)) {
						if !self.processHeaderContinuation(segment) {
							callback(false)
							return
						}
					} else if first {
						if !self.processRequestLine(segment) {
							callback(false)
							return
						}
					} else {
						if !self.processHeaderLine(segment) {
							callback(false)
							return
						}
					}
				} else {
					lastWasCr = c == HTTP_CR
				}
			}
			// not done yet
			self.readHeaders(callback)
		}
		
		func didReadHeaderData(b:[UInt8]?, callback: OkCallback) {
			guard b != nil else {
				callback(false)
				return
			}
			if b!.count == 0 { // no data was available for immediate consumption. try reading with timeout
				self.connection.readBytesFully(1, timeoutSeconds: READ_TIMEOUT) {
					(b2:[UInt8]?) in
					
					if b2 == nil { // timeout. request dead
						callback(false)
					} else {
						self.didReadHeaderData(b2, callback: callback)
					}
				}
			} else {
				self.workingBuffer.appendContentsOf(b!)
				self.scanWorkingBuffer(callback)
			}
		}
		
		func putStdinData(b: [UInt8]) {
			if self.stdin == nil && self.mimes == nil {
				let contentType = self.contentType
				if contentType == nil || !contentType!.hasPrefix("multipart/form-data") {
					self.stdin = b
				} else {
					self.mimes = MimeReader(contentType!)
					self.mimes!.addToBuffer(b)
				}
			} else if self.stdin != nil {
				self.stdin!.appendContentsOf(b)
			} else {
				self.mimes!.addToBuffer(b)
			}
		}
		
		func writeHeaderLine(h: String) {
			self.header += h + "\r\n"
		}
		
		func writeHeaderBytes(b: [UInt8]) {
			if !wroteHeader {
				wroteHeader = true
				
				let statusLine = "\(self.httpVersion) \(statusCode) \(statusMsg)\r\n"
				let firstBytes = [UInt8](statusLine.utf8)
				writeBytes(firstBytes)
				
			}
			if !b.isEmpty {
				writeBytes(b)
			}
		}
		
		func pushHeaderBytes() {
			if !wroteHeader {
				if self.httpOneOne {
					header += "Connection: keep-alive\r\n\r\n" // final CRLF
				} else {
					header += "\r\n" // final CRLF
				}
				writeHeaderBytes([UInt8](header.utf8))
				header = ""
			}
		}
		
		func writeBodyBytes(b: [UInt8]) {
			pushHeaderBytes()
			writeBytes(b)
		}
		
		func writeBytes(b: [UInt8]) {
			self.connection.writeBytesFully(b)
		}
		
	}
}

