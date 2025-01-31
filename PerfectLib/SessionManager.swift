//
//  SessionManager.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 7/14/15.
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
import func ICU.ucal_getNow

let Perfect_SESSION_DB = "perfect_sessions"
let SESSION_NAME_PREFIX = "_PerfectSessionTracker_"

/// This struct is used for configuring the various options available for a session
/// - seealso `SessionManager`
public struct SessionConfiguration {
	var id: String
	let name: String
	let expires: Int
	let useCookie: Bool
	let useLink: Bool
	let useAuto: Bool
	let useNone: Bool
	let domain: String
	let path: String
	let cookieExpires: Double
	let rotate: Bool
	let secure: Bool
	let httpOnly: Bool
	
	var lastAccess = 0.0 // set after reading data
	
	/// Create a new SessionConfiguration struct
	/// - parameter name: The name for the new session. All session names must be unique for a given request. Attempting to initialize the same session twice will cause an exception.
	/// - parameter expires: The number of minutes from the last access after which the session will expire.
	/// - parameter useCookie: If true, indicates that the session should propagate by setting a browser cookie.
	/// - parameter useLink: If true, indicates that the session should propagate by rewriting all resulting page links so that they include a search parameter.
	/// - parameter useAuto: If true, the session begins by using both cookies and link rewriting. If the session manager detects that cookies are being properly passed then it will stop rewriting links.
	/// - parameter useNone: If true, neither cookies nor link rewriting will be utilized. This makes session propagation the responsibility of the page handler.
	/// - parameter id: If specified, this will be the value used to identify this session. Session ids are automatically generated when not explicitly provided.
	/// - parameter domain: When using cookies for session proagation, this optional value will indicate the cookie's `domain` value. By default no domain value is set for the session cookie.
	/// - parameter path: When using cookies for session proagation, this optional value will indicate the cookie's `path` value. By default no path value is set for the session cookie.
	/// - parameter cookieExpires: When specified this value will be used as the expiration date for the session's cookie. When not specified, the cookie will have the same expiration as that of the session itself.
	/// - parameter rotate: If true, the session will have a new unique session id generated for it on each request.
	/// - parameter secure: If true, the session cookie will be marked as `secure` when it is set. This prevents the session from propagating on non-SSL requests.
	/// - parameter httpOnly: If true, the session cookie will only be set on normal HTTP requests. This means the cookie will not be set on requests which come through the XMLHTTPRequest mechanism.
	public init(_ name: String, expires: Int = 15, useCookie: Bool = true, useLink: Bool = false,
				useAuto: Bool = true, useNone: Bool = false, id: String = "", domain: String = "", path: String = "/",
				cookieExpires: Double = 0.0, rotate: Bool = false, secure: Bool = false, httpOnly: Bool = false) {
		self.name = name
		self.expires = expires
		self.useCookie = useCookie
		self.useLink = useLink
		self.useAuto = useAuto
		self.useNone = useNone
		self.id = id
		self.domain = domain
		self.path = path
		self.cookieExpires = cookieExpires != 0.0 ? cookieExpires : Double(self.expires)
		self.rotate = rotate
		self.secure = secure
		self.httpOnly = httpOnly
	}
	
	/// Create a new SessionConfiguration struct
	/// - parameter name: The name for the new session. All session names must be unique for a given request. Attempting to initialize the same session twice will cause an exception.
	/// - parameter id: This will be the value used to identify this session.
	/// - parameter copyFrom: Copy all other configuration values from the given `SessionConfiguration` struct.
	public init(_ name: String, id: String, copyFrom: SessionConfiguration) {
		self.name = name
		self.id = id
		self.expires = copyFrom.expires
		self.useCookie = copyFrom.useCookie
		self.useLink = copyFrom.useLink
		self.useAuto = copyFrom.useAuto
		self.useNone = copyFrom.useNone
		self.domain = copyFrom.domain
		self.path = copyFrom.path
		self.cookieExpires = copyFrom.cookieExpires
		self.rotate = copyFrom.rotate
		self.secure = copyFrom.secure
		self.httpOnly = copyFrom.httpOnly
	}
}

/// This enum is used to indicate the result of initializing the session.
public enum SessionResult {
	/// No session initialization result.
	case None
	/// The session existed and its values were loaded.
	case Load
	/// The session did not exist but was created anew.
	case New
	/// The session existed and its id was rotated.
	case Rotate
	/// The session existed but had expired and was created anew.
	case Expire
}

/// This class is used to manage an individual session. One is a acquired through the current WebResponse object given to a page handler.
/// Session related variables can be set and retrieved though this object. Any variables which are set will be persisted and made available the next time the session is loaded.
public class SessionManager {
	
	static func initializeSessionsDatabase() throws {
		
		try Dir(PerfectServer.staticPerfectServer.homeDir() + SQLITE_DBS).create()
		
		let sqlite = try SQLite(PerfectServer.staticPerfectServer.homeDir() + SQLITE_DBS + Perfect_SESSION_DB)
		sqlite.doWithClose {
			do {
				try sqlite.execute("CREATE TABLE IF NOT EXISTS sessions (" +
					"id INTEGER PRIMARY KEY," +
					"session_key TEXT NOT NULL UNIQUE," +
					"data BLOB," +
					"last_access TEXT," +
					"expire_minutes INTEGER DEFAULT 15" +
				")")
			} catch {
				
			}
		}
	}
	
	public typealias Key = JSONDictionaryType.Key
	public typealias Value = JSONDictionaryType.Value
	
	var dictionary: JSONDictionaryType?
	var configuration: SessionConfiguration
	var result = SessionResult.None
	
	internal init(_ configuration: SessionConfiguration) {
		self.configuration = configuration
		let name = configuration.name
		let key = configuration.id
		
		let fullKey = name + ":" + key
		// load values
		do {
			let sqlite = try SQLite(PerfectServer.staticPerfectServer.homeDir() + SQLITE_DBS + Perfect_SESSION_DB)
			defer { sqlite.close() }
			try sqlite.execute("BEGIN")
			try sqlite.forEachRow("SELECT data,last_access,expire_minutes FROM sessions WHERE session_key = ?",
					doBindings: {
						(stmt: SQLiteStmt) throws -> () in
				
						try stmt.bind(1, fullKey)
					},
					handleRow: {
						(stmt: SQLiteStmt, count: Int) -> () in
						do {
							let lastAccess = stmt.columnDouble(1)
							let expireMinutes = stmt.columnDouble(2)
							let now = self.getNowSeconds()
							let minutesSinceAccess = (now - lastAccess) / 60
							if minutesSinceAccess > expireMinutes {
								
								try sqlite.execute("DELETE FROM sessions WHERE session_key = ?", doBindings: {
									(stmt: SQLiteStmt) -> () in
									
									try stmt.bind(1, fullKey)
									self.result = .Expire
								})
								
							} else {
								self.result = .Load
								let data = stmt.columnText(0)
								self.dictionary = try JSONDecode().decode(data) as? JSONDictionaryType
							}
						} catch {}
					})
			try sqlite.execute("COMMIT")
		} catch {
			
		}
		if self.dictionary == nil {
			self.dictionary = JSONDictionaryType()
			if self.result == .None {
				self.result = .New
			}
		} else if self.configuration.rotate {
			self.result = .Rotate
			self.configuration.id = SessionManager.generateSessionKey()
		}
	}
	
	/// !FIX! needs to support all the special cookie options
	func initializeForResponse(response: WebResponse) {
		let c = Cookie()
		c.name = SESSION_NAME_PREFIX + self.configuration.name
		c.value = self.configuration.id
		c.expiresIn = Double(self.configuration.cookieExpires)
		response.addCookie(c)
	}
	
	/// Get the `SessionResult` for the current session.
	public func getLoadResult() -> SessionResult {
		return result
	}
	
	/// Get the `SessionConfiguration` which was used to intialize the current session.
	public func getConfiguration() -> SessionConfiguration {
		return self.configuration
	}
	
	func getNowSeconds() -> Double {
		return Double(ICU.icuDateToSeconds(ICU.getNow()))
	}
	
	func commit() throws {
		// save values
		let fullKey = self.configuration.name + ":" + self.configuration.id
		let encoded = try JSONEncode().encode(self.dictionary!)
		let sqlite = try SQLite(PerfectServer.staticPerfectServer.homeDir() + SQLITE_DBS + Perfect_SESSION_DB)
		defer { sqlite.close() }
		
		try sqlite.execute("INSERT OR REPLACE INTO sessions (data,last_access,expire_minutes,session_key) " +
							"VALUES (?,?,?,?)", doBindings: {
			(stmt: SQLiteStmt) -> () in
			
			try stmt.bind(1, UTF8Encoding.decode(encoded))
			try stmt.bind(2, self.getNowSeconds())
			try stmt.bind(3, self.configuration.expires)
			try stmt.bind(4, fullKey)
		})
		
	}
	
	/// Get a session variable by name.
	/// - parameter key: The name of the session variable.
	/// - returns: The session variable's value or nil if no variable existed with the provided name.
	public subscript(key: Key) -> Value? {
		get {
			return dictionary![key]
		}
		set(newValue) {
			dictionary![key] = newValue
		}
	}
	
	/// Get a session variable based on its name while also proving a default value.
	/// If the indicated variable does not already exist, it will be created with the indicated value.
	/// - parameter key: The name of the session variable.
	/// - parameter defaultValue: The default value for the variable which will be used if the variable did not already exist.
	/// - returns: The session variable value.
	public func getVar<T: Value>(key: Key, defaultValue: T) -> T {
		if let test = self[key] as? T {
			return test
		}
		dictionary![key] = defaultValue
		return defaultValue
	}
	
	/// Generate a presumably unique session id
	static public func generateSessionKey() -> String {
		let u = UnsafeMutablePointer<UInt8>.alloc(sizeof(uuid_t))
		let unu = UnsafeMutablePointer<Int8>.alloc(37) // as per spec. 36 + null
		
		defer {
			u.destroy() ; u.dealloc(sizeof(uuid_t))
			unu.destroy() ; unu.dealloc(37)
		}
		
		uuid_generate_random(u)
		uuid_unparse(u, unu)
		
		return String.fromCString(unu)!
	}
}




