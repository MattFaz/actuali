import Foundation
import Testing
@testable import Actuali

struct ActualServerClientDecodingTests {

    @Test func decodesKeyInfoWithTest() throws {
        let json = """
        {"status":"ok","data":{"id":"kid-1","salt":"c2FsdA==","test":"{\\"value\\":\\"abc\\"}"}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(KeyInfoResponse.self, from: json)
        #expect(decoded.data?.id == "kid-1")
        #expect(decoded.data?.salt == "c2FsdA==")
        #expect(decoded.data?.test != nil)
    }

    @Test func decodesKeyInfoWithNullTest() throws {
        let json = """
        {"status":"ok","data":{"id":"kid-1","salt":"c2FsdA==","test":null}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(KeyInfoResponse.self, from: json)
        #expect(decoded.data?.test == nil)
    }

    @Test func decodesFullEncryptMeta() throws {
        let json = """
        {"status":"ok","data":{"fileId":"f1","groupId":"g1","name":"Budget","deleted":0,
         "encryptMeta":{"keyId":"kid-1","algorithm":"aes-256-gcm","iv":"aXY=","authTag":"dGFn"}}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FileInfoResponse.self, from: json)
        #expect(decoded.data?.encryptMeta?.keyId == "kid-1")
        #expect(decoded.data?.encryptMeta?.iv == "aXY=")
        #expect(decoded.data?.encryptMeta?.authTag == "dGFn")
    }
}
