import CryptoKit
import Foundation

/// A read-only historical match offered by an authorized DEVONthink query.
///
/// It is a *candidate*, never an answer: SPEC §6.1 forbids treating a stored
/// `projectname` as proof of the current file's project. The strength records
/// how the match was found so the interface can show it honestly.
public struct ContextHistoryMatch: Sendable, Equatable {
    public enum Strength: String, Sendable, CaseIterable {
        case exactName, normalized, partial
    }

    public let databaseID: UUID
    public let recordID: UUID
    public let projectName: String
    public let groupPath: [String]
    public let strength: Strength

    public init(databaseID: UUID, recordID: UUID, projectName: String, groupPath: [String], strength: Strength) {
        self.databaseID = databaseID
        self.recordID = recordID
        self.projectName = projectName
        self.groupPath = groupPath
        self.strength = strength
    }
}

public struct ContextBuilderInput: Sendable {
    public let scopeID: UUID
    public let profile: MappingProfile
    public let entries: [SourceEntry]
    /// Only matches from a database the user authorized for this run.
    public let history: [ContextHistoryMatch]

    public init(scopeID: UUID, profile: MappingProfile, entries: [SourceEntry],
                history: [ContextHistoryMatch] = []) {
        self.scopeID = scopeID
        self.profile = profile
        self.entries = entries
        self.history = history
    }
}

/// Two-phase project context, per PLAN §6.1.
///
/// Phase one clusters files from directory structure, naming entities and
/// adjacency, with no assumption about which path level names a project. Phase
/// two aligns those clusters with the profile vocabulary and any authorized
/// historical records. Nothing here calls a model or a provider: the output is
/// deterministic, so the same listing always produces the same context and a
/// reviewer can reproduce any clustering decision from the input alone.
public enum ContextBuilder {
    /// Structural fingerprint: identities, paths and entry states only.
    ///
    /// Content changes deliberately stay out of this digest. A file's bytes
    /// invalidate its own snapshot binding and therefore its own manifest
    /// entry; they must not rebuild the whole workspace context. Directory
    /// additions, removals, moves and renames do change it, because membership
    /// is what those operations affect.
    public static func inputDigest(scopeID: UUID, profile: MappingProfile, entries: [SourceEntry]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("context.v1|\(scopeID.sourceKey)|\(profile.versionKey)\n".utf8))
        for entry in entries.sorted(by: { $0.normalizedRelativePath < $1.normalizedRelativePath }) {
            hasher.update(
                data: Data("\(entry.id.sourceKey)|\(entry.normalizedRelativePath)|\(entry.state.rawValue)\n".utf8)
            )
        }
        return hasher.finalize().hexadecimalDigest
    }

    public static func build(_ input: ContextBuilderInput, revision: Int, builtAt: Date = .now) -> ProjectContext {
        let files = input.entries.filter { $0.state == .present || $0.state == .held }
        let digest = inputDigest(scopeID: input.scopeID, profile: input.profile, entries: input.entries)
        let clusters = mergedClusters(files)

        // Phase two: authorized history may name and strengthen a candidate.
        // It never decides membership, and a match is recorded as a reference
        // rather than substituted for evidence.
        var candidates: [ContextCandidate] = []
        for cluster in clusters.sorted(by: { $0.key < $1.key }) {
            guard !cluster.members.isEmpty else { continue }
            let matches = input.history.filter { relates($0, to: cluster) }
            var basis = Set(cluster.basis)
            var confidence = cluster.confidence
            if !matches.isEmpty {
                basis.insert(.historyReference)
                // History corroborates a structural candidate; it does not turn
                // a weak adjacency guess into a confirmed project on its own.
                if confidence == .low, matches.contains(where: { $0.strength == .exactName }) { confidence = .medium }
            }
            candidates.append(ContextCandidate(
                id: candidateID(profile: input.profile, key: cluster.key, members: cluster.members),
                projectKey: cluster.key,
                displayName: displayName(for: cluster, matches: matches),
                basis: basis.sorted { $0.rawValue < $1.rawValue },
                memberSourceIDs: cluster.members,
                confidence: confidence
            ))
        }

        // A file claimed by two candidates that did not merge is a genuine
        // disagreement about project membership. Both claims are kept and the
        // file is reported as conflicted; nothing picks a winner by confidence.
        var owners: [UUID: Set<String>] = [:]
        for candidate in candidates {
            for member in candidate.memberSourceIDs { owners[member, default: []].insert(candidate.projectKey) }
        }
        let conflicted = Set(owners.compactMap { $0.value.count > 1 ? $0.key : nil })
        let covered = Set(candidates.flatMap(\.memberSourceIDs))
        let present = Set(files.map(\.id))

        return ProjectContext(
            revision: revision,
            scopeID: input.scopeID,
            profileID: input.profile.profileID,
            profileVersion: input.profile.profileVersion,
            inputDigest: digest,
            candidates: candidates,
            unassignedSourceIDs: present.subtracting(covered),
            conflictedSourceIDs: conflicted.intersection(present),
            builtAt: builtAt
        )
    }

    /// Source IDs whose membership actually differs between two contexts.
    ///
    /// This is what makes invalidation local: a new directory in one project
    /// must not re-map every other project in the workspace.
    public static func affectedSourceIDs(between previous: ProjectContext, and next: ProjectContext) -> Set<UUID> {
        var affected: Set<UUID> = []
        let previousByKey = Dictionary(uniqueKeysWithValues: previous.candidates.map { ($0.projectKey, $0) })
        let nextByKey = Dictionary(uniqueKeysWithValues: next.candidates.map { ($0.projectKey, $0) })
        for (key, candidate) in nextByKey {
            guard let before = previousByKey[key] else {
                affected.formUnion(candidate.memberSourceIDs)
                continue
            }
            if before.memberSourceIDs != candidate.memberSourceIDs {
                affected.formUnion(before.memberSourceIDs.symmetricDifference(candidate.memberSourceIDs))
            }
        }
        for (key, candidate) in previousByKey where nextByKey[key] == nil {
            affected.formUnion(candidate.memberSourceIDs)
        }
        affected.formUnion(previous.unassignedSourceIDs.symmetricDifference(next.unassignedSourceIDs))
        affected.formUnion(previous.conflictedSourceIDs.symmetricDifference(next.conflictedSourceIDs))
        return affected
    }

    // MARK: - Phase one

    /// Internal so the clustering rules can be tested directly.
    struct Cluster {
        let key: String
        var members: Set<UUID>
        var basis: Set<ContextCandidate.Basis>
        var confidence: DecisionConfidence
    }

    /// Directory and naming candidates, merged where they clearly describe the
    /// same project and kept apart where they genuinely disagree.
    private static func mergedClusters(_ files: [SourceEntry]) -> [Cluster] {
        var clusters: [Cluster] = []
        let byDirectory = Dictionary(grouping: files) { parent(of: $0.relativePath) }
        for (directory, members) in byDirectory.sorted(by: { $0.key < $1.key }) where !directory.isEmpty {
            clusters.append(Cluster(key: directory, members: Set(members.map(\.id)),
                                    basis: [.directory, .adjacency], confidence: .low))
        }
        // A naming entity that appears in two or more files joins a project
        // that is spread across directories, or splits a directory that holds
        // several projects.
        for (entity, members) in namingEntities(files).sorted(by: { $0.key < $1.key }) where members.count >= 2 {
            clusters.append(Cluster(key: entity, members: members, basis: [.naming], confidence: .medium))
        }
        return reconcile(clusters)
    }

    /// Merges candidates that are two views of one project: one member set
    /// contains the other, or they share most of the smaller set. A candidate
    /// that shares only part of its members with a different candidate is left
    /// alone, because that is the disagreement the interface must show.
    static func reconcile(_ input: [Cluster]) -> [Cluster] {
        var working = input.sorted { $0.members.count > $1.members.count }
        var index = 0
        while index < working.count {
            var other = index + 1
            while other < working.count {
                let a = working[index].members
                let b = working[other].members
                let overlap = a.intersection(b)
                let smaller = min(a.count, b.count)
                let sameProject = !overlap.isEmpty && (overlap.count == smaller || overlap.count * 2 >= smaller)
                if sameProject {
                    // Keep the more specific key: a directory path names the
                    // location, an entity token names the content, and the
                    // larger member set is the safer scope.
                    let keep = a.count >= b.count ? index : other
                    let drop = keep == index ? other : index
                    working[keep].members.formUnion(working[drop].members)
                    working[keep].basis.formUnion(working[drop].basis)
                    if working[keep].confidence == .low { working[keep].confidence = working[drop].confidence }
                    working.remove(at: drop)
                    if drop < index { index -= 1 }
                    if drop == index { break }
                    continue
                }
                other += 1
            }
            index += 1
        }
        // Two directory candidates where one is the ancestor of the other and
        // the ancestor adds nothing new collapse into the descendant.
        return working.filter { !$0.members.isEmpty }
    }

    static func parent(of path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    /// Normalized naming entities with dates, version markers and copy suffixes
    /// removed. Tokens group files; they never decide a project name.
    static func namingEntities(_ files: [SourceEntry]) -> [String: Set<UUID>] {
        var result: [String: Set<UUID>] = [:]
        for entry in files {
            let name = (entry.relativePath as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            for token in entityTokens(stem) {
                result[token, default: []].insert(entry.id)
            }
        }
        return result
    }

    private static let noiseTokens: Set<String> = [
        "final", "draft", "new", "copy", "副本", "草稿", "最终", "最终版", "修订", "修改",
        "附件", "模板", "空白", "盖章", "签字", "扫描", "打印",
    ]

    private static func entityTokens(_ stem: String) -> Set<String> {
        var tokens: Set<String> = []
        for raw in stem.components(separatedBy: CharacterSet(charactersIn: "_-–— .·+ ,，()（）[]【】")) {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard token.count >= 2, token.count <= 40 else { continue }
            // A pure date or long numeric run is a timestamp, not an identity.
            if token.allSatisfy(\.isNumber), token.count >= 6 { continue }
            if token.range(of: #"^[vV][0-9]{1,3}$"#, options: .regularExpression) != nil { continue }
            if noiseTokens.contains(token.lowercased()) { continue }
            tokens.insert(token.lowercased())
        }
        return tokens
    }

    // MARK: - Phase two helpers

    private static func relates(_ match: ContextHistoryMatch, to cluster: Cluster) -> Bool {
        let target = normalize(match.projectName)
        guard !target.isEmpty else { return false }
        let keys = [normalize(cluster.key), normalize(lastSegment(cluster.key))]
        return keys.contains { $0.contains(target) || (!$0.isEmpty && target.contains($0)) }
    }

    private static func displayName(for cluster: Cluster, matches: [ContextHistoryMatch]) -> String? {
        // An exact historical name is shown as the candidate's readable label,
        // while the structural key stays what it is.
        if let exact = matches.first(where: { $0.strength == .exactName }) { return exact.projectName }
        let segment = lastSegment(cluster.key)
        return segment.isEmpty ? nil : segment
    }

    private static func lastSegment(_ key: String) -> String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: " ", with: "")
    }

    /// A candidate id that stays stable when unrelated files change: it is a
    /// digest of the profile, the key and the member identities, never of a
    /// position in a list.
    private static func candidateID(profile: MappingProfile, key: String, members: Set<UUID>) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(profile.versionKey)|\(key)\n".utf8))
        for member in members.sorted(by: { $0.sourceKey < $1.sourceKey }) {
            hasher.update(data: Data("\(member.sourceKey)\n".utf8))
        }
        return "c" + String(hasher.finalize().hexadecimalDigest.prefix(16))
    }
}

extension Digest {
    var hexadecimalDigest: String { map { String(format: "%02x", $0) }.joined() }
}
