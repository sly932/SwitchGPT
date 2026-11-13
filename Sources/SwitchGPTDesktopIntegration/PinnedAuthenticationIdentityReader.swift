import CryptoKit
import Foundation
import SwitchGPTSafetyCore

public final class PinnedAuthenticationIdentityReader: InstalledIdentityReading {
  private let authenticationFileURL: URL

  public init(authenticationFileURL: URL) {
    self.authenticationFileURL = authenticationFileURL.standardizedFileURL
  }

  public func currentIdentity() throws -> IdentityID {
    let data = try SecureAuthenticationFileInstaller.readPrivateAuthenticationFile(
      at: authenticationFileURL
    )
    return try Self.identity(fromAuthenticationData: data)
  }

  public static func identity(fromAuthenticationData data: Data) throws -> IdentityID {
    let email = try identityEmail(fromAuthenticationData: data)
    guard let identity = IdentityID(rawValue: hash(email.lowercased())) else {
      throw DesktopIntegrationError.invalidAuthenticationPayload
    }
    return identity
  }

  public static func identityHashes(fromAuthenticationData data: Data) throws -> Set<String> {
    identityHashes(forEmail: try identityEmail(fromAuthenticationData: data))
  }

  /// Existing quota records can hold the original-case hash, while desktop switching
  /// uses the case-normalized hash.
  public static func identityHashes(forEmail email: String) -> Set<String> {
    [hash(email), hash(email.lowercased())]
  }

  private static func hash(_ email: String) -> String {
    let digest = SHA256.hash(data: Data(email.utf8))
    return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
  }

  private static func identityEmail(fromAuthenticationData data: Data) throws -> String {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = object["tokens"] as? [String: Any],
      let idToken = tokens["id_token"] as? String,
      let email = claims(fromJWT: idToken)?["email"] as? String, !email.isEmpty
    else {
      throw DesktopIntegrationError.invalidAuthenticationPayload
    }
    return email
  }

  package static func claims(fromJWT token: String?) -> [String: Any]? {
    guard let token else { return nil }
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else { return nil }
    var payload = String(segments[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder != 0 {
      payload += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: payload) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}
