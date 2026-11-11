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
/// Phase one groups files from directory structure, naming entities and
/// adjacency, with no assumption about which path level names a project. Phase
/// two aligns those groups with the profile vocabulary and any authorized
/// historical records. Nothing here calls a model or a provider: the output is
/// deterministic, so the same listing always produces the same context and a
/// reviewer can reproduce any clustering decision from the input alone.
///
/// The cases the clustering has to satisfy are the ones the contract states: a
/// project may own several subdirectories, one directory may hold several
/// projects, the same vendor material may appear in two projects, and vendor
/// documents may belong to no project at all.
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
        let groups = cluster(files)

        var candidates: [ContextCandidate] = []
        for group in groups.values.sorted(by: { $0.key < $1.key }) {
            guard !group.members.isEmpty else { continue }
            let matches = input.history.filter { relates($0, to: group) }
            var basis = group.basis
            var confidence = group.confidence
            if !matches.isEmpty {
                basis.insert(.historyReference)
                // History corroborates a structural candidate; it does not turn
                // a weak adjacency guess into a confirmed project on its own.
                if confidence == .low, matches.contains(where: { $0.strength == .exactName }) { confidence = .medium }
            }
            candidates.append(ContextCandidate(
                id: candidateID(profile: input.profile, key: group.key, members: group.members),
                projectKey: group.key,
                displayName: displayName(for: group, matches: matches),
                basis: basis.sorted { $0.rawValue < $1.rawValue },
                memberSourceIDs: group.members,
                confidence: confidence
            ))
        }

        // A file claimed by two surviving groups is a genuine disagreement about
        // project membership. Both claims stay and the file is reported as
        // conflicted; nothing picks a winner by confidence.
        var owners: [UUID: Set<String>] = [:]
        for candidate in candidates {
            for member in candidate.memberSourceIDs { owners[member, default: []].insert(candidate.projectKey) }
        }
        let present = Set(files.map(\.id))
        let conflicted = Set(owners.compactMap { $0.value.count > 1 ? $0.key : nil }).intersection(present)
        let covered = Set(candidates.flatMap(\.memberSourceIDs))

        return ProjectContext(
            revision: revision,
            scopeID: input.scopeID,
            profileID: input.profile.profileID,
            profileVersion: input.profile.profileVersion,
            inputDigest: digest,
            candidates: candidates,
            unassignedSourceIDs: present.subtracting(covered),
            conflictedSourceIDs: conflicted,
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

    struct Group {
        let key: String
        var members: Set<UUID>
        var basis: Set<ContextCandidate.Basis>
        var confidence: DecisionConfidence
    }

    /// Groups files, then resolves the two directions a project can spread.
    ///
    /// 1. Every directory that holds files becomes a candidate, and so does each
    ///    of its ancestors: a project with several subdirectories is one project
    ///    seen at different levels, and the ancestor absorbs the descendants.
    /// 2. A directory whose files split into two or more *disjoint* naming
    ///    entities, each holding at least two files and together covering most
    ///    of the directory, holds several projects. It is split by entity
    ///    instead of absorbed, because merging it upward would silently merge
    ///    the projects inside it.
    /// 3. An entity that appears in two different directories joins them: the
    ///    same project spread over separate folders is one candidate.
    static func cluster(_ files: [SourceEntry]) -> [String: Group] {
        var groups: [String: Group] = [:]
        let byDirectory = Dictionary(grouping: files) { parent(of: $0.relativePath) }
        let entities = namingEntities(files)

        for (directory, members) in byDirectory.sorted(by: { $0.key < $1.key }) {
            guard !directory.isEmpty else { continue }
            if let split = splitByEntity(members, entities: entities) {
                for (token, tokenMembers) in split {
                    merge(into: &groups, key: token, members: tokenMembers,
                          basis: [.naming, .adjacency], confidence: .medium)
                }
                continue
            }
            merge(into: &groups, key: directory, members: Set(members.map(\.id)),
                  basis: [.directory, .adjacency], confidence: .low)
            // Ancestors absorb this directory: the project level, not the
            // subdirectory, is what a mapping decision belongs to.
            var components = directory.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                merge(into: &groups, key: components.joined(separator: "/"),
                      members: Set(members.map(\.id)), basis: [.directory], confidence: .medium)
            }
        }

        // An entity shared across directories joins those directories.
        let idToFile = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        for (token, tokenMembers) in entities.sorted(by: { $0.key < $1.key }) where tokenMembers.count >= 2 {
            let directories = Set(tokenMembers.compactMap { idToFile[$0].map { parent(of: $0.relativePath) } })
            guard directories.count >= 2 else { continue }
            merge(into: &groups, key: token, members: tokenMembers, basis: [.naming], confidence: .medium)
        }

        return absorb(groups)
    }

    /// Two disjoint entity sets inside one directory mean two projects there.
    private static func splitByEntity(_ members: [SourceEntry], entities: [String: Set<UUID>])
        -> [(String, Set<UUID>)]?
    {
        let ids = Set(members.map(\.id))
        guard ids.count >= 4 else { return nil }
        let candidates = entities
            .filter { !$0.value.isDisjoint(with: ids) && $0.value.isSubset(of: ids) && $0.value.count >= 2 }
            .sorted { ($0.value.count, $0.key) > ($1.value.count, $1.key) }
        var chosen: [(String, Set<UUID>)] = []
        var taken: Set<UUID> = []
        for (token, set) in candidates {
            guard set.isDisjoint(with: taken) else { continue }
            chosen.append((token, set))
            taken.formUnion(set)
        }
        // Only a real split: at least two disjoint groups covering most of the
        // directory. Otherwise the naming overlap is noise, not two projects.
        guard chosen.count >= 2, taken.count * 3 >= ids.count * 2 else { return nil }
        return chosen
    }

    private static func merge(into groups: inout [String: Group], key: String, members: Set<UUID>,
                              basis: [ContextCandidate.Basis], confidence: DecisionConfidence) {
        if var existing = groups[key] {
            existing.members.formUnion(members)
            existing.basis.formUnion(basis)
            if existing.confidence == .low, confidence != .low { existing.confidence = confidence }
            groups[key] = existing
        } else {
            groups[key] = Group(key: key, members: members, basis: Set(basis), confidence: confidence)
        }
    }

    /// Drops a group whose members are entirely contained in another's, keeping
    /// the broader key as the project. Ties keep the lexicographically smaller
    /// key so the result does not depend on dictionary order.
    static func absorb(_ input: [String: Group]) -> [String: Group] {
        var groups = input
        var changed = true
        while changed {
            changed = false
            let keys = groups.keys.sorted()
            for outer in keys {
                guard let a = groups[outer] else { continue }
                for inner in keys where inner != outer {
                    guard let b = groups[inner], !b.members.isEmpty, b.members.isSubset(of: a.members) else { continue }
                    if a.members == b.members, inner < outer { continue }
                    groups.removeValue(forKey: inner)
                    changed = true
                    break
                }
                if changed { break }
            }
        }
        return groups.filter { !$0.value.members.isEmpty }
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

    /// A historical record corroborates a candidate; it must not create one.
    ///
    /// Containment is admitted only between whole tokens of a meaningful
    /// length. With bare substring matching, a one-character directory name
    /// would "match" every history project containing that character, and the
    /// interface would then display a guessed name as if it were confirmed.
    static func relates(_ match: ContextHistoryMatch, to group: Group) -> Bool {
        let target = normalize(match.projectName)
        guard !target.isEmpty else { return false }
        let keyForms = [normalize(group.key), normalize(lastSegment(group.key))]
        if keyForms.contains(target) { return true }
        let targetTokens = Set(nameTokens(match.projectName))
        guard !targetTokens.isEmpty else { return false }
        let groupTokens = Set(nameTokens(group.key))
        return groupTokens.contains { $0.count >= minimumTokenLength && targetTokens.contains($0) }
    }

    /// The shortest token that may support a non-exact historical match.
    static let minimumTokenLength = 3

    private static func nameTokens(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "/_-–— .·+ ,，()（）[]【】"))
            .map { normalize($0) }
            .filter { !$0.isEmpty && $0.count >= minimumTokenLength }
    }

    private static func displayName(for group: Group, matches: [ContextHistoryMatch]) -> String? {
        // Only a name equal to the structural key may replace the label.
        // Anything weaker is a hint about membership, not a title, and showing
        // it as the project name would present a guess as a fact.
        let keyForms = Set([group.key, lastSegment(group.key)].map(normalize))
        if let exact = matches.first(where: {
            $0.strength == .exactName && keyForms.contains(normalize($0.projectName))
        }) { return exact.projectName }
        let segment = lastSegment(group.key)
        return segment.isEmpty ? nil : segment
    }

    private static func lastSegment(_ key: String) -> String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
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
