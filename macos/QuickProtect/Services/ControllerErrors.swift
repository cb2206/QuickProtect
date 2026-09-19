import Foundation

/// Maps a failed controller request to a user-facing message. The English
/// texts are also the catalog keys of the .NET port's `ControllerErrors`, so
/// both platforms share one set of translations.
///
/// Foundation's own descriptions are generic ("A server with the specified
/// hostname could not be found.", or "HTTP 401 – {json}" from our own error)
/// and are localized by the OS in its first preferred language — which need
/// not be a language the app ships, leaving an English UI with a Swedish
/// error. Recognized failures therefore get the app's own wording; anything
/// else falls back to the error's description.
enum ControllerErrors {
    static let hostNotFound = String(localized: "Can't find the controller. Check the IP address or hostname in Settings.")
    static let connectionRefused = String(localized: "The controller refused the connection. Check the IP address in Settings.")
    static let unreachable = String(localized: "Can't reach the controller. Check that it's online and on the same network.")
    static let timedOut = String(localized: "The controller didn't respond in time. Check that it's online and on the same network.")
    static let secureConnectionFailed = String(localized: "A secure connection to the controller couldn't be established.")
    static let invalidAddress = String(localized: "Invalid IP address or URL.")
    static let apiKeyRejected = String(localized: "The controller rejected the API key. Check it in Settings.")
    static let busy = String(localized: "The controller is busy. Try again in a moment.")
    static let serverError = String(localized: "The controller reported an internal error. Try again later.")
    static let unexpectedResponse = String(localized: "The controller returned an unexpected response.")
    static let unreadableResponse = String(localized: "The controller sent a response QuickProtect couldn't read.")

    static func describe(_ error: Error) -> String {
        switch error {
        case let api as ProtectService.APIError:
            return describe(api)
        case is DecodingError:
            return unreadableResponse
        case let url as URLError:
            return describe(url) ?? url.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    static func describe(_ error: ProtectService.APIError) -> String {
        switch error {
        case .invalidURL:
            return invalidAddress
        case .notHTTP:
            return unexpectedResponse
        case .http(let status, _):
            switch status {
            case 401, 403: return apiKeyRejected
            case 429:      return busy
            case 500...:   return serverError
            default:       return unexpectedResponse
            }
        }
    }

    /// `nil` for codes with no better wording than Foundation's.
    private static func describe(_ error: URLError) -> String? {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return hostNotFound
        case .cannotConnectToHost:
            // Covers refused and unreachable alike; the POSIX code tells them apart.
            return posixCode(of: error) == Int(ECONNREFUSED) ? connectionRefused : unreachable
        case .timedOut:
            return timedOut
        case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff,
             .dataNotAllowed, .callIsActive:
            return unreachable
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return secureConnectionFailed
        case .badURL, .unsupportedURL:
            return invalidAddress
        case .badServerResponse:
            return unexpectedResponse
        case .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData, .zeroByteResource:
            return unreadableResponse
        default:
            return nil
        }
    }

    /// The socket error CFNetwork attached, when it reports one in the POSIX domain.
    private static func posixCode(of error: URLError) -> Int? {
        let info = error.errorUserInfo
        guard info["_kCFStreamErrorDomainKey"] as? Int == 1 else { return nil } // kCFStreamErrorDomainPOSIX
        return info["_kCFStreamErrorCodeKey"] as? Int
    }
}
