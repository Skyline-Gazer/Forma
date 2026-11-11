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
/// Phase one decides which directory level is the *project* level and groups
/// files there, splitting a shared directory by naming entity when it holds
/// several projects. Phase two aligns the groups with the profile vocabulary
/// and any authorized historical records. Nothing here calls a model or a
/// provider: the output is deterministic, so the same listing always produces
/// the same context and a reviewer can reproduce any clustering decision from
/// the input alone.
///
/// The project level is identified from the profile, not from a fixed depth: a
/// directory whose name is one of the profile's categories (`01_招标文件`,
/// `Datasheet`, …) is a filing level, so its parent is the project. That is what
/// lets one project own several subdirectories, what keeps a customer or year
/// directory from being mistaken for a project, and what makes a shared
/// directory containing several projects splittable by file name.
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
        let groups = cluster(files, profile: input.profile)
        let present = Set(files.map(\.id))

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
        var conflicted = Set(owners.compactMap { $0.value.count > 1 ? $0.key : nil })
        // The same material filed under two projects is the other way a claim
        // can be contested: identical file names in different project
        // directories mean two candidate memberships for one document, and
        // choosing one silently is exactly the failure mode the profile exists
        // to prevent.
        if !input.profile.permitsUnaffiliatedDocuments {
            for member in sameMaterialSourceIDs(files, groups: groups) { conflicted.insert(member) }
        }

        let covered = Set(candidates.flatMap(\.memberSourceIDs))
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

    struct Group {
        let key: String
        var members: Set<UUID>
        var basis: Set<ContextCandidate.Basis>
        var confidence: DecisionConfidence
    }

    /// Groups files at the project level.
    ///
    /// A profile that permits unaffiliated documents (Vendor Library) produces
    /// no project groups at all: filing vendor material under an invented
    /// project would fabricate a business fact, and PLAN §5.2 says a vendor
    /// file may legitimately have no project.
    static func cluster(_ files: [SourceEntry], profile: MappingProfile) -> [String: Group] {
        guard !profile.permitsUnaffiliatedDocuments else { return [:] }
        var groups: [String: Group] = [:]
        for file in files {
            guard let key = projectKey(of: file, profile: profile) else { continue }
            if var existing = groups[key] {
                existing.members.insert(file.id)
                groups[key] = existing
            } else {
                groups[key] = Group(key: key, members: [file.id], basis: [.directory, .adjacency],
                                    confidence: .low)
            }
        }
        // A project directory that actually holds several projects is split by
        // naming entity, because the directory itself says nothing about which
        // project a file belongs to.
        var split: [String: Group] = [:]
        for (key, group) in groups.sorted(by: { $0.key < $1.key }) {
            let members = files.filter { group.members.contains($0.id) }
            if let parts = splitByEntity(members, inside: group) {
                for (token, tokenMembers) in parts {
                    split[token] = Group(key: token, members: tokenMembers,
                                         basis: [.naming, .adjacency], confidence: .medium)
                }
                // Files the entities do not explain stay in the directory
                // group rather than disappearing.
                let explained = parts.reduce(Set<UUID>()) { $0.union($1.1) }
                let rest = group.members.subtracting(explained)
                if !rest.isEmpty {
                    if var existing = split[key] {
                        existing.members.formUnion(rest)
                        split[key] = existing
                    } else {
                        split[key] = Group(key: key, members: rest, basis: group.basis, confidence: group.confidence)
                    }
                }
            } else {
                split[key] = group
            }
        }
        return split.filter { !$0.value.members.isEmpty }
    }

    /// The deepest directory whose child segment is one of the profile's
    /// categories. Nil means the file sits at the workspace root and cannot be
    /// attributed to a project by structure alone.
    static func projectKey(of file: SourceEntry, profile: MappingProfile) -> String? {
        let segments = file.relativePath.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return nil }
        let directories = Array(segments.dropLast())
        // Scan from the deepest directory upward: the first one whose child is
        // a category level is the project.
        for index in stride(from: directories.count - 1, through: 0, by: -1) {
            let child = segments[index + 1]
            if isCategoryLike(child, profile: profile) {
                let key = directories[...index].joined(separator: "/")
                return key.isEmpty ? nil : key
            }
        }
        // No category signal: the immediate parent is the project, unless the
        // file is already at the root.
        let parent = directories.joined(separator: "/")
        return parent.isEmpty ? nil : parent
    }

    /// True when a directory segment names a filing category rather than a
    /// project. Matching is by normalized containment in either direction so
    /// `招标` under a customer tree still reads as a category level, while a
    /// project name that merely contains a category word does not.
    static func isCategoryLike(_ segment: String, profile: MappingProfile) -> Bool {
        let needle = normalize(segment)
        guard needle.count >= 2 else { return false }
        for category in profile.categories {
            let name = normalize(category.identifier)
            // Drop the numeric prefix (`01_招标文件` -> `招标文件`) before
            // comparing, so the label part is what matches.
            let bare = name.replacingOccurrences(of: "^[0-9]+_", with: "", options: .regularExpression)
            if bare.isEmpty { continue }
            if needle == bare || needle == name || bare.contains(needle) || needle.contains(bare) { return true }
        }
        for type in profile.documentTypes {
            if normalize(type.identifier) == needle { return true }
        }
        return false
    }

    /// Two disjoint naming entities inside one directory mean two projects.
    private static func splitByEntity(_ members: [SourceEntry], inside group: Group) -> [(String, Set<UUID>)]? {
        let ids = group.members
        guard ids.count >= 4 else { return nil }
        let entities = namingEntities(members)
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

    /// Files whose name appears under two different project directories.
    static func sameMaterialSourceIDs(_ files: [SourceEntry], groups: [String: Group]) -> Set<UUID> {
        var stems: [String: Set<UUID>] = [:]
        var owner: [UUID: String] = [:]
        for (key, group) in groups {
            for id in group.members { owner[id] = key }
        }
        for file in files {
            let name = (file.relativePath as NSString).lastPathComponent
            let stem = normalize((name as NSString).deletingPathExtension)
            guard stem.count >= 2 else { continue }
            stems[stem, default: []].insert(file.id)
        }
        var conflicted: Set<UUID> = []
        for (_, ids) in stems where ids.count >= 2 {
            let owners = Set(ids.compactMap { owner[$0] })
            if owners.count >= 2 { conflicted.formUnion(ids) }
        }
        return conflicted
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

    static func normalize(_ value: String) -> String {
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
