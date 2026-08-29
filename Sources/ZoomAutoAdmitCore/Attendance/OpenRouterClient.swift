import Foundation
import OSLog

/// Talks to OpenRouter for the handful of names local matching could not settle.
///
/// Failure here is always survivable: attendance recording and Auto Admit carry
/// on regardless, and unresolved names simply stay Needs Review.
public final class OpenRouterClient {
    public struct Configuration: Equatable {
        public var model: String
        public var timeout: TimeInterval
        public var maxAttempts: Int

        public init(
            model: String = "openai/gpt-4o-mini",
            timeout: TimeInterval = 30,
            maxAttempts: Int = 2
        ) {
            self.model = model
            self.timeout = timeout
            self.maxAttempts = max(1, min(maxAttempts, 3))
        }
    }

    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "ai-matching")
    private let configuration: Configuration
    private let session: URLSession
    private let apiKeyProvider: () -> String?

    public init(
        configuration: Configuration = Configuration(),
        session: URLSession = .shared,
        apiKeyProvider: @escaping () -> String? = { APIKeyStore.load() }
    ) {
        self.configuration = configuration
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    /// The instruction the model gets. Deliberately narrow: it may only pair
    /// names that were given to it, and must say so when it cannot.
    public static func prompt(for request: AIMatchRequest) -> String {
        let students = request.students
            .map { "  {\"id\": \"\($0.id)\", \"name\": \"\(escape($0.officialName))\"}" }
            .joined(separator: ",\n")
        let names = request.zoomNames
            .map { "  \"\(escape($0))\"" }
            .joined(separator: ",\n")

        return """
        You match official student names to the display names people used in a Zoom meeting.

        Rules:
        - Only pair a student with a Zoom name from the list given. Never invent either.
        - Each student may appear at most once. Each Zoom name may appear at most once.
        - A shared first name alone is weak evidence. A device name such as "Ahmed's iPhone" \
        is weak evidence unless nothing else fits.
        - Names may be written in Arabic or transliterated English; treat them as the same language family.
        - If you are unsure, leave the Zoom name unresolved rather than guessing.

        Students:
        [
        \(students)
        ]

        Zoom names:
        [
        \(names)
        ]

        Reply with JSON only, in exactly this shape:
        {"matches":[{"studentId":"...","zoomName":"...","confidence":0.0,"reason":"..."}],\
        "unresolvedZoomNames":["..."]}
        """
    }

    /// Sends the request. Never logs the key or the Authorization header.
    public func proposeMatches(for request: AIMatchRequest) async -> Swift.Result<AIMatchResponse, AIMatchError> {
        guard request.isWorthSending else {
            return .success(AIMatchResponse(matches: [], unresolvedZoomNames: request.zoomNames))
        }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            return .failure(.noAPIKey)
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": "You reply with JSON only."],
                ["role": "user", "content": Self.prompt(for: request)]
            ]
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.malformedResponse("request could not be encoded"))
        }

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = payload

        var lastError: AIMatchError = .network("no attempt was made")

        for attempt in 1...configuration.maxAttempts {
            // Only counts and the model name are logged; never names, never the key.
            logger.info("AI matching attempt \(attempt) students=\(request.students.count) names=\(request.zoomNames.count)")
            do {
                let (data, response) = try await session.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse else {
                    lastError = .network("no HTTP response")
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    lastError = .httpStatus(http.statusCode)
                    // Client-side errors will not improve on a retry.
                    if (400..<500).contains(http.statusCode), http.statusCode != 429 { break }
                    continue
                }
                guard let content = Self.extractContent(from: data) else {
                    lastError = .malformedResponse("no message content")
                    continue
                }
                do {
                    return .success(try AIMatchValidator.decode(content))
                } catch let error as AIMatchError {
                    lastError = error
                    continue
                } catch {
                    lastError = .malformedResponse("\(error)")
                    continue
                }
            } catch {
                lastError = .network(error.localizedDescription)
            }
        }

        logger.notice("AI matching failed: \(lastError.message, privacy: .public)")
        return .failure(lastError)
    }

    /// Pulls `choices[0].message.content` out of an OpenAI-shaped reply.
    static func extractContent(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
