import CoreImage
import Foundation
import AurumCore

/// Whether server AI can be used right now.
public enum AIProviderAvailability: Equatable, Sendable {
    case available
    /// No server is configured (or it was switched off). The AI Studio shows
    /// a calm "coming soon" state instead of failing.
    case unavailable
}

public enum AIServiceError: Error, Equatable {
    case unavailable
    case missingInput
    case badResponse(status: Int)
    case invalidResultReference
}

/// An `AIProvider` that can also say whether it is reachable and fetch results.
public protocol AIBackend: AIProvider {
    var availability: AIProviderAvailability { get }
    /// Downloads one of the `resultRefs` of a succeeded job.
    func result(_ reference: String) async throws -> Data
}

/// Talks to AURUM's AI server over HTTPS.
///
/// The base URL comes from configuration (never hardcoded); with no base URL
/// the provider reports `.unavailable` and makes no network calls. No secrets
/// live in the app: requests carry an optional bearer token supplied at
/// runtime (for example a short-lived token minted for the signed-in user).
///
/// ## Contract (version 1)
///
/// All bodies are JSON with ISO 8601 dates. Every request carries
/// `Idempotency-Key: <job id>`; submitting the same id twice must return the
/// existing job rather than start (and charge) a second one.
///
/// `POST {base}/v1/jobs`
/// ```json
/// {
///   "request": { …AIJobRequest… },   // inputs[].localIdentifier is replaced by "input-0", "input-1"…
///   "inputs": ["<base64 JPEG>", …]    // one per request input, already within feature.maxInputPixels
/// }
/// ```
/// → `200` or `202` `{ "id": "<uuid>", "status": AIJobStatus }`
///
/// `GET {base}/v1/jobs/{id}` → `200` `{ "id": "<uuid>", "status": AIJobStatus }`
///
/// `DELETE {base}/v1/jobs/{id}` → `200`/`202`/`204`; cancelling a finished job is not an error.
///
/// `AIJobStatus` is the tagged union from AurumCore, for example
/// `{"type": "running", "progress": 0.4}` or
/// `{"type": "succeeded", "resultRefs": ["https://…/result.jpg"]}`.
/// A result reference is either an absolute HTTPS URL or a path relative to
/// the base URL (such as `/v1/jobs/{id}/results/0`); `GET` returns the JPEG.
/// Moderation rejections come back as `rejectedByModeration` with a short reason.
public final class RemoteAIProvider: AIBackend, @unchecked Sendable {
    /// Loads a photo as JPEG data no larger than `maxPixels` in total.
    public typealias InputLoader = @Sendable (_ source: SourceAsset, _ maxPixels: Int) async throws -> Data
    public typealias TokenProvider = @Sendable () async -> String?

    public let baseURL: URL?
    private let session: URLSession
    private let inputLoader: InputLoader?
    private let token: TokenProvider?

    public init(baseURL: URL?, session: URLSession = .shared, inputLoader: InputLoader?, token: TokenProvider? = nil) {
        // Only HTTPS is accepted; anything else counts as not configured.
        if let baseURL, baseURL.scheme?.lowercased() == "https" {
            self.baseURL = baseURL
        } else {
            self.baseURL = nil
        }
        self.session = session
        self.inputLoader = inputLoader
        self.token = token
    }

    public var availability: AIProviderAvailability {
        baseURL == nil || inputLoader == nil ? .unavailable : .available
    }

    struct SubmitBody: Encodable {
        var request: AIJobRequest
        var inputs: [String]
    }

    struct JobResponse: Decodable {
        var id: String
        var status: AIJobStatus
    }

    public func submit(_ request: AIJobRequest) async throws -> AIJobStatus {
        guard let base = baseURL, let inputLoader else { throw AIServiceError.unavailable }
        guard !request.inputs.isEmpty else { throw AIServiceError.missingInput }
        var encodedInputs: [String] = []
        var anonymous = request
        for (index, input) in request.inputs.enumerated() {
            let data = try await inputLoader(input, request.feature.maxInputPixels)
            encodedInputs.append(data.base64EncodedString())
            // The server never needs the Photos identifier.
            anonymous.inputs[index] = SourceAsset(localIdentifier: "input-\(index)", pixelSize: input.pixelSize)
        }
        let body = try EditDocument.makeEncoder().encode(SubmitBody(request: anonymous, inputs: encodedInputs))
        var urlRequest = await makeRequest(base.appendingPathComponent("v1/jobs"), method: "POST", jobID: request.id)
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(urlRequest).status
    }

    public func status(of jobID: UUID) async throws -> AIJobStatus {
        guard let base = baseURL else { throw AIServiceError.unavailable }
        let url = base.appendingPathComponent("v1/jobs").appendingPathComponent(jobID.uuidString)
        return try await send(await makeRequest(url, method: "GET", jobID: jobID)).status
    }

    public func cancel(jobID: UUID) async throws {
        guard let base = baseURL else { throw AIServiceError.unavailable }
        let url = base.appendingPathComponent("v1/jobs").appendingPathComponent(jobID.uuidString)
        let (_, response) = try await session.data(for: await makeRequest(url, method: "DELETE", jobID: jobID))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 and 409: already gone or already finished.
        guard (200..<300).contains(code) || code == 404 || code == 409 else { throw AIServiceError.badResponse(status: code) }
    }

    public func result(_ reference: String) async throws -> Data {
        guard let base = baseURL else { throw AIServiceError.unavailable }
        guard let url = Self.resolve(reference, base: base) else { throw AIServiceError.invalidResultReference }
        let (data, response) = try await session.data(for: await makeRequest(url, method: "GET", jobID: nil))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AIServiceError.badResponse(status: code) }
        return data
    }

    /// An absolute HTTPS reference, or a path relative to the base URL.
    static func resolve(_ reference: String, base: URL) -> URL? {
        if let url = URL(string: reference), let scheme = url.scheme {
            return scheme.lowercased() == "https" ? url : nil
        }
        let path = reference.hasPrefix("/") ? String(reference.dropFirst()) : reference
        guard !path.isEmpty, !path.contains("..") else { return nil }
        return base.appendingPathComponent(path)
    }

    private func makeRequest(_ url: URL, method: String, jobID: UUID?) async -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jobID { request.setValue(jobID.uuidString, forHTTPHeaderField: "Idempotency-Key") }
        if let token, let value = await token() {
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> JobResponse {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AIServiceError.badResponse(status: code) }
        return try EditDocument.makeDecoder().decode(JobResponse.self, from: data)
    }

    /// Loads inputs from the photo library, downscaled to the feature's limit
    /// and encoded as JPEG.
    public static func libraryLoader(_ photos: PhotoLibraryService) -> InputLoader {
        { source, maxPixels in
            let w = Double(max(source.pixelSize.width, 1)), h = Double(max(source.pixelSize.height, 1))
            let scale = min(1, (Double(maxPixels) / (w * h)).squareRoot())
            let longest = CGFloat((max(w, h) * scale).rounded(.down))
            let image = try await photos.image(for: source.localIdentifier, maxPixelSize: longest)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let data = CIContext().jpegRepresentation(of: image, colorSpace: space, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]) else {
                throw PhotoLibraryError.loadFailed
            }
            return data
        }
    }
}

// MARK: - Credits and job history

/// Keeps the credit ledger and the AI job history as JSON files in
/// Application Support. The server stays the authority on credits; this is
/// the device's mirror, so the UI never double-charges or forgets a refund.
public final class CreditStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var cachedLedger: CreditLedger?
    private var cachedHistory: AIJobHistory?

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AI", isDirectory: true)
    }

    var ledgerURL: URL { directory.appendingPathComponent("credits.json") }
    var historyURL: URL { directory.appendingPathComponent("jobs.json") }

    public var ledger: CreditLedger {
        lock.lock(); defer { lock.unlock() }
        if let cachedLedger { return cachedLedger }
        let loaded = read(CreditLedger.self, from: ledgerURL) ?? CreditLedger()
        cachedLedger = loaded
        return loaded
    }

    public var history: AIJobHistory {
        lock.lock(); defer { lock.unlock() }
        if let cachedHistory { return cachedHistory }
        let loaded = read(AIJobHistory.self, from: historyURL) ?? AIJobHistory()
        cachedHistory = loaded
        return loaded
    }

    /// Changes the ledger and saves it. Returns what `change` returned.
    @discardableResult
    public func updateLedger<T>(_ change: (inout CreditLedger) -> T) -> T {
        var value = ledger
        let result = change(&value)
        lock.lock(); cachedLedger = value; lock.unlock()
        write(value, to: ledgerURL)
        return result
    }

    @discardableResult
    public func updateHistory<T>(_ change: (inout AIJobHistory) -> T) -> T {
        var value = history
        let result = change(&value)
        lock.lock(); cachedHistory = value; lock.unlock()
        write(value, to: historyURL)
        return result
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? EditDocument.makeDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? EditDocument.makeEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
