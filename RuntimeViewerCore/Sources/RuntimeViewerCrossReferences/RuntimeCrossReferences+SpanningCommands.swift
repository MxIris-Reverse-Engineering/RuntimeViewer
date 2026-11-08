import Foundation
import RuntimeViewerCore

// The scans over every indexed image, answered across an engine that borrows
// shared cache images and its owners: each participant scans the images it
// has indexed — its own, or the shared cache images it keeps — and keeps the
// references found in its images. The requested engine's process maps the
// whole shared cache, so it finds the functions of a shared cache image by
// address without indexing the image; only a member's addresses come from
// the image's owner, which has its sections. A query scoped to one image
// names that image and goes to its owner instead.

extension RuntimeCrossReferences.CallersCommand: RuntimeEngineSpanningProgressCommand {
    func response(
        across participants: [RuntimeSharedCacheParticipant],
        onProgress: (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)?
    ) async throws -> RuntimeCrossReferenceQueryResult {
        let progressTally = RuntimeSpanningCrossReferenceProgressTally()
        let parts = try await participants.concurrentResults { participant -> RuntimeCrossReferenceQueryResult in
            var references: [RuntimeCrossReference] = []
            var isComplete = true
            for participantSubject in try await subjects(askedOf: participant, among: participants) {
                let command = RuntimeCrossReferences.CallersCommand(subject: participantSubject, scope: scope, options: options)
                let result = try await participant.dispatch(command, onProgress: progressTally.forwarding(to: onProgress, for: participant))
                references += result.references.filter { participant.includesImage($0.referencingFunction.imagePath) }
                isComplete = isComplete && result.isComplete
            }
            return RuntimeCrossReferenceQueryResult(references: references, isComplete: isComplete)
        }
        return RuntimeCrossReferenceQueryResult(combining: parts, resultLimit: options.resultLimit)
    }

    /// What `participant` is asked about. A member of a shared cache image
    /// another participant keeps becomes the member's functions, by address,
    /// as that participant's sections list them: this one has not indexed
    /// the image, so it could not find the member by name.
    private func subjects(
        askedOf participant: RuntimeSharedCacheParticipant,
        among participants: [RuntimeSharedCacheParticipant]
    ) async throws -> [RuntimeCrossReferenceSubject] {
        guard case .member(let member) = subject,
              !participant.includesImage(member.object.imagePath),
              let memberOwner = participants.first(where: { $0.includesImage(member.object.imagePath) })
        else { return [subject] }
        let memberAddresses = try await memberOwner.engine.memberAddresses(for: member.object, memberName: member.name)
        let functionSubjects = memberAddresses
            .filter { MemberAddressMatching.matches($0, member) }
            .compactMap { memberAddress in
                MemberAddressMatching.address(of: memberAddress).map { address in
                    RuntimeCrossReferenceSubject.function(imagePath: member.object.imagePath, address: address)
                }
            }
        var seenSubjects = Set<RuntimeCrossReferenceSubject>()
        let distinctSubjects = functionSubjects.filter { seenSubjects.insert($0).inserted }
        return distinctSubjects.isEmpty ? [subject] : distinctSubjects
    }
}

extension RuntimeCrossReferences.TypeReferencesCommand: RuntimeEngineSpanningProgressCommand {
    func response(
        across participants: [RuntimeSharedCacheParticipant],
        onProgress: (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)?
    ) async throws -> RuntimeCrossReferenceQueryResult {
        let progressTally = RuntimeSpanningCrossReferenceProgressTally()
        let parts = try await participants.concurrentResults { participant -> RuntimeCrossReferenceQueryResult in
            let result = try await participant.dispatch(self, onProgress: progressTally.forwarding(to: onProgress, for: participant))
            return RuntimeCrossReferenceQueryResult(
                references: result.references.filter { participant.includesImage($0.referencingFunction.imagePath) },
                isComplete: result.isComplete
            )
        }
        return RuntimeCrossReferenceQueryResult(combining: parts, resultLimit: options.resultLimit)
    }
}

private extension RuntimeCrossReferenceQueryResult {
    /// One result of `parts`, the requested engine's references first: two
    /// processes number their images differently, so their lists are joined,
    /// not interleaved. The query's limit holds for the joined list.
    init(combining parts: [RuntimeCrossReferenceQueryResult], resultLimit: Int?) {
        var seenReferences = Set<RuntimeCrossReference>()
        let references = parts.flatMap(\.references).filter { seenReferences.insert($0).inserted }
        let isComplete = parts.allSatisfy(\.isComplete)
        if let resultLimit, references.count > resultLimit {
            self.init(references: Array(references.prefix(max(0, resultLimit))), isComplete: false)
        } else {
            self.init(references: references, isComplete: isComplete)
        }
    }
}

/// The scan progress of every participant as one: the images scanned and to
/// scan, summed over the participants' latest reports, with each report's
/// references from the reporting participant's own images.
private actor RuntimeSpanningCrossReferenceProgressTally {
    private var countsByParticipant: [ObjectIdentifier: (scanned: Int, total: Int)] = [:]

    nonisolated func forwarding(
        to onProgress: (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)?,
        for participant: RuntimeSharedCacheParticipant
    ) -> (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)? {
        guard let onProgress else { return nil }
        return { progress in
            let combinedProgress = await self.combine(progress, from: participant)
            await onProgress(combinedProgress)
        }
    }

    private func combine(_ progress: RuntimeCrossReferenceQueryProgress, from participant: RuntimeSharedCacheParticipant) -> RuntimeCrossReferenceQueryProgress {
        countsByParticipant[ObjectIdentifier(participant.engine)] = (progress.scannedImageCount, progress.totalImageCount)
        return RuntimeCrossReferenceQueryProgress(
            scannedImageCount: countsByParticipant.values.map(\.scanned).reduce(0, +),
            totalImageCount: countsByParticipant.values.map(\.total).reduce(0, +),
            references: progress.references.filter { participant.includesImage($0.referencingFunction.imagePath) }
        )
    }
}
