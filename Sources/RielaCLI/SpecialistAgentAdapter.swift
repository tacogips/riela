import Foundation
import RielaCore

/// Authenticated, tool-free classifier boundary. Configuration supplies the
/// provider identity and credentials; request text and model output are never
/// treated as authority to select a specialist, workflow, or external target.
protocol SpecialistDecisionProvider: Sendable {
  func classify(
    request: SpecialistRequest,
    specialists: [SpecialistConfiguredSpecialist],
    deadline: Date
  ) async throws -> [SpecialistDecision]
}

/// Credentials are resolved at the composition boundary by name.  They are
/// deliberately not serializable classifier configuration: catalog/config
/// files may be inspected, copied, or committed, while the provider secret is
/// owned by the approved process secret environment.
protocol SpecialistSecretProviding: Sendable {
  func secret(named name: String) throws -> String
}

struct EnvironmentSpecialistSecretProvider: SpecialistSecretProviding {
  let environment: [String: String]

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  func secret(named name: String) throws -> String {
    guard isValidSecretName(name), let value = environment[name], !value.isEmpty else {
      throw SpecialistClassifierError.unavailable
    }
    return value
  }

  private func isValidSecretName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 128 && name.unicodeScalars.allSatisfy {
      ($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57) || $0.value == 95
    }
  }
}

/// Hermetic mock scenarios use this explicit provider boundary; normal serve
/// execution resolves Matrix credentials only by configured secret name.
struct FixtureSpecialistSecretProvider: SpecialistSecretProviding {
  let value: String

  func secret(named name: String) throws -> String {
    guard name == "FIXTURE_MATRIX_TOKEN", !value.isEmpty else { throw SpecialistClassifierError.unavailable }
    return value
  }
}

struct SpecialistAuthenticatedClassifier: SpecialistDecisionProvider {
  let endpoint: URL
  let bearerToken: String
  let providerIdentity: String
  let transport: any SpecialistHTTPTransport

  func classify(
    request: SpecialistRequest,
    specialists: [SpecialistConfiguredSpecialist],
    deadline: Date
  ) async throws -> [SpecialistDecision] {
    guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil,
          !bearerToken.isEmpty, !providerIdentity.isEmpty, Date() <= deadline else {
      throw SpecialistClassifierError.unavailable
    }
    let body = try JSONEncoder().encode(SpecialistClassifierRequest(
      providerIdentity: providerIdentity,
      requestId: request.requestId,
      body: String(request.body.prefix(16_384)),
      specialists: specialists.map { .init(id: $0.id, domain: $0.domain) }
    ))
    let reply: (status: Int, body: Data)
    do {
      reply = try await transport.send(
        url: endpoint, method: "POST",
        headers: ["Authorization": "Bearer \(bearerToken)", "Content-Type": "application/json"], body: body
      )
    } catch {
      throw SpecialistClassifierError.uncertain
    }
    guard (200 ... 299).contains(reply.status) else {
      throw reply.status == 408 || reply.status == 425 || reply.status == 429 || reply.status >= 500
        ? SpecialistClassifierError.uncertain : SpecialistClassifierError.unavailable
    }
    guard let decoded = try? JSONDecoder().decode(SpecialistClassifierResponse.self, from: reply.body),
          decoded.providerIdentity == providerIdentity else {
      throw SpecialistClassifierError.invalidResponse
    }
    let configured = Set(specialists.map(\.id))
    let decisions = decoded.decisions.filter { configured.contains($0.specialistId) }
    guard decisions.count == decoded.decisions.count,
          Set(decisions.map(\.specialistId)).count == decisions.count else {
      throw SpecialistClassifierError.invalidResponse
    }
    return decisions
  }
}

/// Hermetic-only classifier used by the documented smoke. It is gated by a
/// mock scenario path at composition, so a production submit can never accept
/// caller-authored fixture decisions as an ownership authority.
struct SpecialistFixtureClassifier: SpecialistDecisionProvider {
  let decisions: [SpecialistDecision]

  func classify(
    request _: SpecialistRequest,
    specialists: [SpecialistConfiguredSpecialist],
    deadline: Date
  ) async throws -> [SpecialistDecision] {
    guard Date() <= deadline else { throw SpecialistClassifierError.unavailable }
    let configured = Set(specialists.map(\.id))
    guard decisions.allSatisfy({ configured.contains($0.specialistId) }) else {
      throw SpecialistClassifierError.invalidResponse
    }
    return decisions
  }
}

enum SpecialistClassifierError: Error, Equatable, Sendable {
  case unavailable
  case uncertain
  case invalidResponse
}

struct SpecialistConfiguredSpecialist: Codable, Sendable {
  let id: String
  let capacity: Int
  let domain: String
  /// Operator-authored origins and executable capability ceilings. Empty
  /// policy is denied at composition; an LLM never gets to widen it.
  let allowedOriginIds: [String]
  let allowedWorkflowIds: [String]

  init(
    id: String, capacity: Int, domain: String,
    allowedOriginIds: [String] = [], allowedWorkflowIds: [String] = []
  ) {
    self.id = id
    self.capacity = capacity
    self.domain = domain
    self.allowedOriginIds = allowedOriginIds
    self.allowedWorkflowIds = allowedWorkflowIds
  }

  private enum CodingKeys: String, CodingKey {
    case id, capacity, domain, allowedOriginIds, allowedWorkflowIds
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    capacity = try values.decode(Int.self, forKey: .capacity)
    domain = try values.decode(String.self, forKey: .domain)
    allowedOriginIds = try values.decodeIfPresent([String].self, forKey: .allowedOriginIds) ?? []
    allowedWorkflowIds = try values.decodeIfPresent([String].self, forKey: .allowedWorkflowIds) ?? []
  }
}

private struct SpecialistClassifierRequest: Codable {
  struct Candidate: Codable { let id: String; let domain: String }
  let providerIdentity: String
  let requestId: String
  let body: String
  let specialists: [Candidate]
}

private struct SpecialistClassifierResponse: Codable {
  let providerIdentity: String
  let decisions: [SpecialistDecision]
}
