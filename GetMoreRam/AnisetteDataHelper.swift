//
//  FetchAnisetteDataOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CryptoKit
import StosSign_API
import StosSign_Auth
import StosSign_Common

final class AnisetteDataHelper
{
    var socket: URLSessionWebSocketTask?
    
    var url: URL?
    var startProvisioningURL: URL?
    var endProvisioningURL: URL?
    
    var clientInfo: String?
    var userAgent: String?
    
    var mdLu: String?
    var deviceId: String?
    
    var menuAnisetteURL: String?
    
    static var shared: AnisetteDataHelper = AnisetteDataHelper()
    
    // Client info / user agent resolution order: custom value from Settings (UserDefaults via @AppStorage),
    // then whatever the anisette server reports on /v3/client_info, then the defaults below.
    static let clientInfoDefaultsKey = "AnisetteClientInfo"
    static let userAgentDefaultsKey = "AnisetteUserAgent"
    // Same as what ani.jkcoxson.com / ani2.stikstore.app report. macOS-style client info gets -22421 with them.
    static let defaultClientInfo = "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
    static let defaultUserAgent = "akd/1.0 CFNetwork/808.1.4"
    
    static let urlBagClientInfo = "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    static let xcodeVersion = "27.0 (27A5218g)"
    
    // adi.pb is bound to the client info it was provisioned with, remember which one that was.
    static let provisionedClientInfoDefaultsKey = "AnisetteProvisionedClientInfo"
    // Stored for an imported adi.pb, whose client info is unknown: never reset it automatically.
    static let provisionedClientInfoAnyValue = "*"
    // Bump the suffix when the provisioning identity (not just the client info) changes
    static func provisionedMarker(for clientInfo: String?) -> String { "\(clientInfo ?? "") #v2" }
    private static let legacyProvisionedClientInfo = "<iMac18,3> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    
    private static func customValue(forKey key: String) -> String? {
        let custom = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom?.isEmpty == false ? custom : nil
    }
    
    var loggingFunc: ((String)->Void)?
    
    /// Like isideload's forced reset: drop adi.pb and use a brand new device identifier, re-provisioning
    /// an identifier Apple has already seen fail can be rejected (-29002).
    func resetAnisetteState() {
        Keychain.shared.adiPb = nil
        Keychain.shared.identifier = nil
        mdLu = nil
        deviceId = nil
    }
    
    func resetClientInfo() {
        clientInfo = nil
        userAgent = nil
        mdLu = nil
        deviceId = nil
    }
    
    func getAnisetteData(refresh: Bool = false) async throws -> AnisetteData
    {
        
        if url == nil {
            throw "No Anisette Server Found!"
        }
        
        self.printOut("Anisette URL: \(self.url!.absoluteString)")
        
        await resolveClientInfo()
        
        let provisionedClientInfo = UserDefaults.standard.string(forKey: Self.provisionedClientInfoDefaultsKey) ?? Self.legacyProvisionedClientInfo
        if Keychain.shared.adiPb != nil,
           provisionedClientInfo != Self.provisionedClientInfoAnyValue,
           provisionedClientInfo != Self.provisionedMarker(for: self.clientInfo) {
            self.printOut("Client info changed since adi.pb was provisioned, resetting anisette state to provision again")
            resetAnisetteState()
        }
        
        let ans : AnisetteData
        if let identifier = Keychain.shared.identifier,
           let adiPb = Keychain.shared.adiPb {
            ans = try await self.fetchAnisetteV3(identifier, adiPb)
        } else {
            do {
                ans = try await self.provision()
            } catch {
                // Don't keep retrying with an identifier Apple just refused to provision
                self.printOut("Provisioning failed, using a new device identifier next time")
                resetAnisetteState()
                throw error
            }
        }
        return ans
    }
    
    // MARK: - COMMON
    
    func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> AnisetteData {
        // make sure this JSON is in the format we expect
        // convert data to json
        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
            if v3 {
                if json["result"] == "GetHeadersError" {
                    let message = json["message"]
                    self.printOut("Error getting V3 headers: \(message ?? "no message")")
                    if let message = message,
                       message.contains("-45061") {
                        self.printOut("Error message contains -45061 (not provisioned), resetting anisette state and retrying")
                        resetAnisetteState()
                        return try await provision()
                    } else { throw message ?? "Unknown error" }
                }
            }
            
            // try to read out a dictionary
            // for some reason serial number isn't needed but it doesn't work unless it has a value
            var formattedJSON: [String: String] = ["deviceSerialNumber": "0"]
            if let machineID = json["X-Apple-I-MD-M"] { formattedJSON["machineID"] = machineID }
            if let oneTimePassword = json["X-Apple-I-MD"] { formattedJSON["oneTimePassword"] = oneTimePassword }
            if let routingInfo = json["X-Apple-I-MD-RINFO"] { formattedJSON["routingInfo"] = routingInfo }
            
            if v3 {
                formattedJSON["deviceDescription"] = self.clientInfo!
                formattedJSON["localUserID"] = self.mdLu!
                formattedJSON["deviceUniqueIdentifier"] = self.deviceId!
                
                // Generate date stuff on client
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                // The literal "Z" means UTC, using the local zone here skews the client time by the UTC offset (-22421)
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                let dateString = formatter.string(from: Date())
                formattedJSON["date"] = dateString
                formattedJSON["locale"] = Locale.current.identifier
                formattedJSON["timeZone"] = TimeZone.current.abbreviation()
            } else {
                if let deviceDescription = json["X-MMe-Client-Info"] { formattedJSON["deviceDescription"] = deviceDescription }
                if let localUserID = json["X-Apple-I-MD-LU"] { formattedJSON["localUserID"] = localUserID }
                if let deviceUniqueIdentifier = json["X-Mme-Device-Id"] { formattedJSON["deviceUniqueIdentifier"] = deviceUniqueIdentifier }
                
                if let date = json["X-Apple-I-Client-Time"] { formattedJSON["date"] = date }
                if let locale = json["X-Apple-Locale"] { formattedJSON["locale"] = locale }
                if let timeZone = json["X-Apple-I-TimeZone"] { formattedJSON["timeZone"] = timeZone }
            }
            
            if let response = response,
               let version = response.value(forHTTPHeaderField: "Implementation-Version") {
                self.printOut("Implementation-Version: \(version)")
            } else { self.printOut("No Implementation-Version header") }
            
            self.printOut("Anisette used: \(formattedJSON)")
            self.printOut("Original JSON: \(json)")
            do {
                let jsonData = try JSONEncoder().encode(formattedJSON)
                let anisette = try JSONDecoder().decode(AnisetteData.self, from: jsonData)
                
                self.printOut("Anisette is valid!")
                return anisette
            } catch {
                self.printOut("Anisette is invalid!!!!")
                if v3 {
                    throw "Invalid anisette (the returned data may not have all the required fields)"
                } else {
                    throw "Invalid anisette (the returned data may not have all the required fields)"
                }
            }
        } else {
            if v3 {
                throw "Invalid anisette (the returned data may not be in JSON)"
            } else {
                throw "Invalid anisette (the returned data may not be in JSON)"
            }
        }
    }
    
    
    // MARK: - V3: PROVISIONING
    
    func provision() async throws -> AnisetteData {
        try await fetchClientInfo()
            self.printOut("Getting provisioning URLs")
            // Like isideload: a non-Mac client info gets us the wrong URL bag, so lie for this request
            var request = self.buildAppleRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!,
                                                 clientInfo: Self.urlBagClientInfo,
                                                 includeDeviceHeaders: false)
            request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        if
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let startProvisioningString = plist["urls"]?["midStartProvisioning"] as? String,
           let startProvisioningURL = URL(string: startProvisioningString),
           let endProvisioningString = plist["urls"]?["midFinishProvisioning"] as? String,
           let endProvisioningURL = URL(string: endProvisioningString) {
            self.startProvisioningURL = startProvisioningURL
            self.endProvisioningURL = endProvisioningURL
            self.printOut("startProvisioningURL: \(self.startProvisioningURL!.absoluteString)")
            self.printOut("endProvisioningURL: \(self.endProvisioningURL!.absoluteString)")
            self.printOut("Starting a provisioning session")
            return try await self.startProvisioningSession()
        } else {
            self.printOut("Apple didn't give valid URLs! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
            throw "Apple didn't give valid URLs. Please try again later"
        }

        
    }
    
    func startProvisioningSession() async throws -> AnisetteData {
        let provisioningSessionURL = self.webSocketURL(from: self.url!.appendingPathComponent("v3").appendingPathComponent("provisioning_session"))
        var wsRequest = URLRequest(url: provisioningSessionURL)
        wsRequest.timeoutInterval = 5
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        self.socket = socket
        socket.resume()
        try await self.receiveProvisioningMessages(from: socket)
        return try await self.fetchAnisetteV3(Keychain.shared.identifier!, Keychain.shared.adiPb!)
    }

    private func receiveProvisioningMessages(from socket: URLSessionWebSocketTask) async throws {
        self.printOut("Connected")
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket {
                self.socket = nil
            }
        }
        
        while true {
            let message = try await socket.receive()
            switch message {
            case .string(let string):
                if try await handleProvisioningMessage(string, socket: socket) {
                    return
                }
            case .data:
                throw "The server sent binary data instead of text"
            @unknown default:
                throw "The server sent an unknown WebSocket message"
            }
        }
    }
    
    private func handleProvisioningMessage(_ string: String, socket: URLSessionWebSocketTask) async throws -> Bool {
        guard let data = string.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw "The server didn't give valid JSON"
        }
        
        guard let result = json["result"] as? String else {
            self.printOut("The server didn't give us a result")
            throw "The server didn't give us a result"
        }
        
        self.printOut("Received result: \(result)")
        switch result {
        case "GiveIdentifier":
            self.printOut("Giving identifier")
            try await socket.sendJSON(["identifier": Keychain.shared.identifier!])
            
        case "GiveStartProvisioningData":
            self.printOut("Getting start provisioning data")
            let spim = try await self.fetchStartProvisioningData()
            self.printOut("Giving start provisioning data")
            try await socket.sendJSON(["spim": spim])
            
        case "GiveEndProvisioningData":
            self.printOut("Getting end provisioning data")
            guard let cpim = json["cpim"] as? String else {
                self.printOut("The server didn't give us a cpim")
                throw "The server didn't give us a cpim"
            }
            let endProvisioningData = try await self.fetchEndProvisioningData(cpim: cpim)
            self.printOut("Giving end provisioning data")
            try await socket.sendJSON(endProvisioningData)
            
        case "ProvisioningSuccess":
            self.printOut("Provisioning succeeded!")
            guard let adiPb = json["adi_pb"] as? String else {
                self.printOut("The server didn't give us an adi.pb file")
                throw "The server didn't give us an adi.pb file"
            }
            Keychain.shared.adiPb = adiPb
            UserDefaults.standard.set(Self.provisionedMarker(for: self.clientInfo), forKey: Self.provisionedClientInfoDefaultsKey)
            return true
            
        default:
            if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                self.printOut("Failing because of \(result)")
                throw result + (json["message"] as? String ?? "")
            }
        }
        
        return false
    }
    
    private func fetchStartProvisioningData() async throws -> String {
        let body = [
            "Header": [String: Any](),
            "Request": [String: Any](),
        ]
        var request = self.buildAppleRequest(url: self.startProvisioningURL!)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let spim = plist["Response"]?["spim"] as? String {
            return spim
        } else {
            self.printOut("Apple didn't give valid start provisioning data! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
            throw "Apple didn't give valid start provisioning data. Please try again later"
        }
    }
    
    private func fetchEndProvisioningData(cpim: String) async throws -> [String: String] {
        let body = [
            "Header": [String: Any](),
            "Request": [
                "cpim": cpim,
            ],
        ]
        var request = self.buildAppleRequest(url: self.endProvisioningURL!)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let ptm = plist["Response"]?["ptm"] as? String,
           let tk = plist["Response"]?["tk"] as? String {
            return ["ptm": ptm, "tk": tk]
        } else {
            self.printOut("Apple didn't give valid end provisioning data! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
            throw "Apple didn't give valid end provisioning data. Please try again later"
        }
    }
    
    private func webSocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        
        return components.url ?? url
    }
    
    /// Headers mirror isideload's GrandSlam provisioning requests (no client time / locale / time zone).
    func buildAppleRequest(url: URL, clientInfo: String? = nil, includeDeviceHeaders: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(clientInfo ?? self.clientInfo!, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(self.userAgent!, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue(Self.xcodeVersion, forHTTPHeaderField: "X-Xcode-Version")
        request.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
        request.setValue("close", forHTTPHeaderField: "Connection")
        
        if includeDeviceHeaders {
            request.setValue(self.mdLu!, forHTTPHeaderField: "X-Apple-I-MD-LU")
            request.setValue(self.deviceId!, forHTTPHeaderField: "X-Mme-Device-Id")
        }
        return request
    }
    
    // MARK: - V3: FETCHING
    
    /// Picks client info / user agent: custom (Settings) > anisette server > built-in default.
    func resolveClientInfo() async {
        let customClientInfo = Self.customValue(forKey: Self.clientInfoDefaultsKey)
        let customUserAgent = Self.customValue(forKey: Self.userAgentDefaultsKey)
        
        var serverInfo: (clientInfo: String, userAgent: String)?
        if customClientInfo == nil || customUserAgent == nil {
            serverInfo = await fetchServerClientInfo()
        }
        
        self.clientInfo = customClientInfo ?? serverInfo?.clientInfo ?? Self.defaultClientInfo
        self.userAgent = customUserAgent ?? serverInfo?.userAgent ?? Self.defaultUserAgent
        
        self.printOut("Client-Info (\(customClientInfo != nil ? "custom" : serverInfo != nil ? "server" : "default")): \(self.clientInfo!)")
        self.printOut("User-Agent (\(customUserAgent != nil ? "custom" : serverInfo != nil ? "server" : "default")): \(self.userAgent!)")
    }
    
    private func fetchServerClientInfo() async -> (clientInfo: String, userAgent: String)? {
        guard let url = self.url else { return nil }
        
        let request = URLRequest(url: url.appendingPathComponent("v3").appendingPathComponent("client_info"), timeoutInterval: 10)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard ((response as? HTTPURLResponse)?.statusCode ?? 200) == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let clientInfo = json["client_info"], !clientInfo.isEmpty,
                  let userAgent = json["user_agent"], !userAgent.isEmpty else {
                self.printOut("Anisette server returned no usable client_info, using defaults")
                return nil
            }
            return (clientInfo, userAgent)
        } catch {
            self.printOut("Couldn't fetch client_info from anisette server (\(error.localizedDescription)), using defaults")
            return nil
        }
    }
    
    func fetchClientInfo() async throws {
        if self.clientInfo == nil || self.userAgent == nil {
            await resolveClientInfo()
        }
        
        if  self.mdLu != nil &&
                self.deviceId != nil &&
                Keychain.shared.identifier != nil {
            return
        }
        
        if Keychain.shared.identifier == nil {
            self.printOut("Generating identifier")
            var bytes = [Int8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            
            if status != errSecSuccess {
                self.printOut("ERROR GENERATING IDENTIFIER!!! \(status)")
                throw "Couldn't generate identifier"
            }
            
            Keychain.shared.identifier = Data(bytes: &bytes, count: bytes.count).base64EncodedString()
        }
        
        let decoded = Data(base64Encoded: Keychain.shared.identifier!)!
        // Lowercase like isideload, which signs in fine with the same servers
        self.mdLu = decoded.sha256().hexEncodedString().lowercased()
        self.printOut("X-Apple-I-MD-LU: \(self.mdLu!)")
        let uuid: UUID = decoded.object()
        self.deviceId = uuid.uuidString.lowercased()
        self.printOut("X-Mme-Device-Id: \(self.deviceId!)")

        // Client info on Anisette Servers are out of date for latest GSA
        /*
        let clientInfoURL = self.url!.appendingPathComponent("v3").appendingPathComponent("client_info")
        
        let (data, response) = try await URLSession.shared.data(from: clientInfoURL)
        

            do {
                
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
                    if let clientInfo = json["client_info"] {
                        self.printOut("Server is V3")
                        
                        self.clientInfo = clientInfo
                        self.userAgent = json["user_agent"]!
                        self.printOut("Client-Info: \(self.clientInfo!)")
                        self.printOut("User-Agent: \(self.userAgent!)")
                        
                        if Keychain.shared.identifier == nil {
                            self.printOut("Generating identifier")
                            var bytes = [Int8](repeating: 0, count: 16)
                            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                            
                            if status != errSecSuccess {
                                self.printOut("ERROR GENERATING IDENTIFIER!!! \(status)")
                                throw "Couldn't generate identifier"
                            }
                            
                            Keychain.shared.identifier = Data(bytes: &bytes, count: bytes.count).base64EncodedString()
                        }
                        
                        let decoded = Data(base64Encoded: Keychain.shared.identifier!)!
                        self.mdLu = decoded.sha256().hexEncodedString()
                        self.printOut("X-Apple-I-MD-LU: \(self.mdLu!)")
                        let uuid: UUID = decoded.object()
                        self.deviceId = uuid.uuidString.uppercased()
                        self.printOut("X-Mme-Device-Id: \(self.deviceId!)")
                        
                        return
                    } else { throw "v1 server is not supported" }
                } else { throw "Couldn't fetch client info. The returned data may not be in JSON" }
            }
        */
    }
    
    /// Apple answered a sign in with hsc 434: ask the anisette server for headers resynced with Apple's SIM
    /// (same request as isideload's `resync`).
    func resyncAnisetteData(sim: String) async throws -> AnisetteData {
        guard let identifier = Keychain.shared.identifier, let adiPb = Keychain.shared.adiPb else {
            throw "Anisette is not provisioned, can't resync"
        }
        self.printOut("Resyncing anisette")
        return try await fetchAnisetteV3(identifier, adiPb, sim: sim)
    }
    
    func fetchAnisetteV3(_ identifier: String, _ adiPb: String, sim: String? = nil) async throws -> AnisetteData {
        try await fetchClientInfo()
        self.printOut("Fetching anisette V3")
        let url = menuAnisetteURL
        var request = URLRequest(url: self.url!.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        var body: [String: String] = [
            "identifier": identifier,
            "adi_pb": adiPb
        ]
        if let sim {
            body["sim"] = sim
            body["device_id"] = self.deviceId!
            body["md_lu"] = self.mdLu!
        }
        request.httpBody = try! JSONSerialization.data(withJSONObject: body, options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        
        return try await self.extractAnisetteData(data, response as? HTTPURLResponse, v3: true)

    }
    
    
    private func printOut(_ text: String?){
        let isInternalLoggingEnabled = true
        if(isInternalLoggingEnabled){
            // logging enabled, so log it
            if let loggingFunc {
                loggingFunc(text ?? "\n")
            } else {
                text.map{ _ in print(text!) } ?? print()
            }

        }
    }
}

extension URLSessionWebSocketTask {
    func sendJSON(_ dictionary: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        try await self.send(.string(String(data: data, encoding: .utf8)!))
    }
}

extension Data {
    // https://stackoverflow.com/a/25391020
    func sha256() -> Data {
        Data(SHA256.hash(data: self))
    }
    
    // https://stackoverflow.com/a/40089462
    func hexEncodedString() -> String {
        return self.map { String(format: "%02hhX", $0) }.joined()
    }
    
    // https://stackoverflow.com/a/59127761
    func object<T>() -> T { self.withUnsafeBytes { $0.load(as: T.self) } }
}
