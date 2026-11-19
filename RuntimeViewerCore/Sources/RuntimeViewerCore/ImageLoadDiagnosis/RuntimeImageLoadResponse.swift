/// What `loadImage` answers.
///
/// Encodes as an empty object when the load succeeded — what
/// `RuntimeEngineEmpty`, the reply before it, encoded — so a requester of an
/// earlier version reads it as it always did. `failure` is filled only for a
/// requester that asked for it (`LoadImageCommand.reportsFailureDiagnosis`),
/// which a requester of an earlier version never does.
public struct RuntimeImageLoadResponse: Codable, Sendable {
    public var failure: RuntimeImageLoadError?

    public init(failure: RuntimeImageLoadError? = nil) {
        self.failure = failure
    }
}
