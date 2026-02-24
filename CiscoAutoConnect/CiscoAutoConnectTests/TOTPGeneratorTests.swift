import XCTest
@testable import CiscoAutoConnect

final class TOTPGeneratorTests: XCTestCase {
    // RFC 6238 Appendix B test vectors (SHA1, 8-digit codes)
    // The standard test secret is "12345678901234567890" (ASCII) = base32 "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    private let testSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    func testBase32Decode() {
        let decoded = TOTPGenerator.base32Decode(testSecret)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(String(data: decoded!, encoding: .ascii), "12345678901234567890")
    }

    func testBase32DecodeWithSpaces() {
        let decoded = TOTPGenerator.base32Decode("GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ")
        XCTAssertNotNil(decoded)
        XCTAssertEqual(String(data: decoded!, encoding: .ascii), "12345678901234567890")
    }

    func testBase32DecodeWithPadding() {
        let decoded = TOTPGenerator.base32Decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ====")
        XCTAssertNotNil(decoded)
        XCTAssertEqual(String(data: decoded!, encoding: .ascii), "12345678901234567890")
    }

    func testBase32DecodeInvalidInput() {
        let decoded = TOTPGenerator.base32Decode("!!!invalid!!!")
        XCTAssertNil(decoded)
    }

    // RFC 6238 test vectors for SHA1 (using 6-digit codes and 30-second period)
    // We test with known Unix timestamps and verify the generated codes.
    func testTOTPAtEpoch59() {
        // T = 59s → counter = 1 → expected 8-digit: 94287082 → 6-digit: 287082
        let date = Date(timeIntervalSince1970: 59)
        let code = TOTPGenerator.generateTOTP(secret: testSecret, time: date, digits: 6)
        XCTAssertNotNil(code)
        XCTAssertEqual(code, "287082")
    }

    func testTOTPAt1111111109() {
        // T = 1111111109 → expected 6-digit: 081804
        let date = Date(timeIntervalSince1970: 1111111109)
        let code = TOTPGenerator.generateTOTP(secret: testSecret, time: date, digits: 6)
        XCTAssertNotNil(code)
        XCTAssertEqual(code, "081804")
    }

    func testTOTPAt1111111111() {
        // T = 1111111111 → expected 6-digit: 050471
        let date = Date(timeIntervalSince1970: 1111111111)
        let code = TOTPGenerator.generateTOTP(secret: testSecret, time: date, digits: 6)
        XCTAssertNotNil(code)
        XCTAssertEqual(code, "050471")
    }

    func testTOTPAt1234567890() {
        // T = 1234567890 → expected 6-digit: 005924
        let date = Date(timeIntervalSince1970: 1234567890)
        let code = TOTPGenerator.generateTOTP(secret: testSecret, time: date, digits: 6)
        XCTAssertNotNil(code)
        XCTAssertEqual(code, "005924")
    }

    func testTOTPAt2000000000() {
        // T = 2000000000 → expected 6-digit: 279037
        let date = Date(timeIntervalSince1970: 2000000000)
        let code = TOTPGenerator.generateTOTP(secret: testSecret, time: date, digits: 6)
        XCTAssertNotNil(code)
        XCTAssertEqual(code, "279037")
    }

    func testTOTPGeneratesCurrentCode() {
        // Smoke test: should generate a 6-digit code for current time
        let code = TOTPGenerator.generateTOTP(secret: testSecret)
        XCTAssertNotNil(code)
        XCTAssertEqual(code?.count, 6)
        XCTAssertTrue(code?.allSatisfy(\.isNumber) ?? false)
    }
}
