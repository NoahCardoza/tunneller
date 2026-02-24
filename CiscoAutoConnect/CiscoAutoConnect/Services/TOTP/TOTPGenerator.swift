import CryptoKit
import Foundation

enum TOTPGenerator {
    /// Generate a 6-digit TOTP code per RFC 6238 (HMAC-SHA1, 30-second period).
    static func generateTOTP(secret: String, time: Date = Date(), period: UInt64 = 30, digits: Int = 6) -> String? {
        guard let keyData = base32Decode(secret) else { return nil }
        let key = SymmetricKey(data: keyData)

        let counter = UInt64(time.timeIntervalSince1970) / period
        var bigEndianCounter = counter.bigEndian
        let counterData = Data(bytes: &bigEndianCounter, count: 8)

        let hmac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let hmacBytes = Array(hmac)

        let offset = Int(hmacBytes[hmacBytes.count - 1] & 0x0F)
        let truncated =
            (UInt32(hmacBytes[offset]) & 0x7F) << 24
            | UInt32(hmacBytes[offset + 1]) << 16
            | UInt32(hmacBytes[offset + 2]) << 8
            | UInt32(hmacBytes[offset + 3])

        let mod = truncated % UInt32(pow(10, Double(digits)))
        return String(format: "%0\(digits)d", mod)
    }

    // MARK: - Base32 Decode (RFC 4648)

    static func base32Decode(_ input: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let cleaned = input.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "=", with: "")

        var bits = 0
        var accumulator: UInt32 = 0
        var output = Data()

        for char in cleaned {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            let value = UInt32(alphabet.distance(from: alphabet.startIndex, to: index))
            accumulator = (accumulator << 5) | value
            bits += 5

            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }

        return output
    }
}
