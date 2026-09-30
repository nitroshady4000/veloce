import XCTest
@testable import VeloceCore

final class ProtocolTests: XCTestCase {
    func testPipeFramingPreservesSplitFrenchUTF8() throws {
        var buffer = JSONLineBuffer()
        let input = Data("{\"id\":\"1\",\"result\":{\"text\":\"Été à Véloce\"}}\n{\"event\":\"status\",\"state\":\"ready\"}\n".utf8)
        var lines: [Data] = []
        for byte in input { lines += try buffer.append(Data([byte])) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(EngineReply.self, from: lines[0]).result?.text, "Été à Véloce")
        XCTAssertEqual(try JSONDecoder().decode(EngineReply.self, from: lines[1]).state, "ready")
    }
    func testErrorsDoNotRequireResult() throws {
        let data = Data(#"{"id":"2","error":{"code":"invalid_request","message":"Missing audio"}}"#.utf8)
        let reply = try JSONDecoder().decode(EngineReply.self, from: data)
        XCTAssertEqual(reply.error?.code, "invalid_request")
        XCTAssertNil(reply.result)
    }
    func testIncompleteLineIsNotDecoded() throws {
        var buffer = JSONLineBuffer()
        XCTAssertTrue(try buffer.append(Data("{\"id\":".utf8)).isEmpty)
        XCTAssertEqual(try buffer.append(Data("\"3\"}\n\n".utf8)).count, 1)
    }
}
