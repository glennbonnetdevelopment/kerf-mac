import XCTest
@testable import KerfCore

final class XToolWiFiTests: XCTestCase {
    func testBaseURLAcceptsBareIPHostPortAndPastedURL() {
        XCTAssertEqual(XToolWiFi.baseURL(host: "192.168.1.50", port: 8080)?.absoluteString, "http://192.168.1.50:8080")
        XCTAssertEqual(XToolWiFi.baseURL(host: " 10.0.0.7:9000 ", port: 8080)?.absoluteString, "http://10.0.0.7:9000")
        XCTAssertEqual(XToolWiFi.baseURL(host: "http://10.0.0.7/ping", port: 8080)?.absoluteString, "http://10.0.0.7:8080")
        XCTAssertNil(XToolWiFi.baseURL(host: "  ", port: 8080))
    }

    func testEndpointURLs() {
        let base = XToolWiFi.baseURL(host: "192.168.1.50", port: 8080)!
        XCTAssertEqual(XToolWiFi.pingURL(base).absoluteString, "http://192.168.1.50:8080/ping")
        XCTAssertEqual(XToolWiFi.uploadURL(base).absoluteString, "http://192.168.1.50:8080/cnc/data?filetype=1")
        XCTAssertEqual(XToolWiFi.startURL(base).absoluteString, "http://192.168.1.50:8080/read?file=/tmp.gcode")
        XCTAssertEqual(XToolWiFi.actionURL(base, .pause).absoluteString, "http://192.168.1.50:8080/cnc/data?action=pause")
        XCTAssertEqual(XToolWiFi.workingStateURL(base).absoluteString,
                       "http://192.168.1.50:8080/system?action=get_working_sta")
        XCTAssertEqual(XToolWiFi.commandURL(base, line: "$I")?.absoluteString, "http://192.168.1.50:8080/cmd?cmd=%24I")
        XCTAssertEqual(XToolWiFi.commandURL(base, line: "G0 X1.5 ; move")?.absoluteString,
                       "http://192.168.1.50:8080/cmd?cmd=G0%20X1.5")
        XCTAssertNil(XToolWiFi.commandURL(base, line: "; just a comment"))
    }

    func testReplies() {
        XCTAssertTrue(XToolWiFi.isOK(#"{"result":"ok"}"#))
        XCTAssertFalse(XToolWiFi.isOK(#"{"result":"fail"}"#))
        XCTAssertFalse(XToolWiFi.isOK(#"{"result":"no file"}"#))
        XCTAssertEqual(XToolWiFi.workingState(#"{"working":"0"}"#), .idle)
        XCTAssertEqual(XToolWiFi.workingState(#"{"working":2}"#), .runningFromButton)
        XCTAssertNil(XToolWiFi.workingState("garbage"))
        let fw = XToolWiFi.firmware(fromVersionReply: #"{"sn":"MXD1","version":"V40.30.010.01 B2"}"#)
        XCTAssertEqual(fw, XToolFirmware(40, 30, 10, 1))
        XCTAssertEqual(fw?.description, "40.30.010.01 B2")
        XCTAssertTrue(fw!.hasJobControl)
        XCTAssertFalse(XToolFirmware.parse("40.30.002.01")!.hasJobControl)
    }

    func testJobFileEnablesSteppersOnce() {
        let text = XToolWiFi.jobFile(["; Kerf job", "G90", "G21", "M5"])
        XCTAssertEqual(text, "; Kerf job\nM17 S1\nG90\nG21\nM5\n")
        XCTAssertEqual(XToolWiFi.jobFile(["M17 S1", "G90"]), "M17 S1\nG90\n")
    }

    func testFrameJobTurnsJogsIntoMovesWithCrosshair() {
        let jogs = ["$J=G90 G21 X10 Y20 F3000", "$J=G90 G21 X30 Y20 F3000"]
        XCTAssertEqual(XToolWiFi.frameJob(jogs),
                       ["; Kerf frame", "G90", "G21", "M5", "M106 S1", "G0 X10 Y20 F3000", "G0 X30 Y20 F3000", "M106 S0"])
        XCTAssertEqual(XToolWiFi.frameJob([]), [])
    }

    func testMultipartBody() {
        let body = String(decoding: XToolWiFi.multipartBody("G90\n", boundary: "B"), as: UTF8.self)
        XCTAssertEqual(body, "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"kerf.gcode\"\r\n"
                       + "Content-Type: application/octet-stream\r\n\r\nG90\n\r\n--B--\r\n")
    }

    func testProfilesWithoutLinkStillDecodeAsUSB() throws {
        var p = DeviceProfile.presets.first { $0.name == "xTool D1 Pro (Wi-Fi)" }!
        XCTAssertTrue(p.usesWiFi)
        p.networkHost = "192.168.1.50"
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(DeviceProfile.self, from: data)
        XCTAssertEqual(back, p)

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for k in ["link", "networkHost", "networkPort", "wifiAutoStart"] { json.removeValue(forKey: k) }
        let old = try JSONDecoder().decode(DeviceProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.link, .usbSerial)
        XCTAssertEqual(old.networkPort, 8080)
        XCTAssertFalse(old.usesWiFi)
    }
}
