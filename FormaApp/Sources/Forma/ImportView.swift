import FormaCore
import SwiftUI

/// The Alpha import surface: a dry run, and nothing else.
///
/// Every control here is read-only by construction. `ImportPlan.writesInThisBuild`
/// is a constant `false`, and the execute button is not merely disabled - it does
/// not exist, so a demo cannot end with a person believing an import happened.
/// The two actions the area owns - build and export the plan - sit in the
/// shell's toolbar grammar like every other command (owner failure #4: the old
/// tab owned neither a consistent leading pane nor a filling viewport).
struct ImportView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let plan = model.importPlan {
                planBody(plan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import plan")
                .font(.title2.weight(.semibold))
            // The most important sentence in this pane: this build cannot write.
            Label("Dry run only. This build has no import path to DEVONthink, so no record can be written.",
                  systemImage: "hand.raised.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("import-dry-run-notice")
            Label("The plan lists local file names; treat an export as private data, not as a sanitized artifact.",
                  systemImage: "lock.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("import-plan-privacy-notice")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Body

    private func planBody(_ plan: ImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            summary(plan)
            if plan.rows.isEmpty {
                Text("This manifest has no records to plan.")
                    .foregroundStyle(.secondary)
            } else {
                List(plan.rows, id: \.sourceID) { row in
                    rowView(row)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func summary(_ plan: ImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                stat("Records", "\(plan.rows.count)")
                stat("Blocked", "\(plan.blocked)", tint: .red)
                stat("Deferred", "\(plan.deferred)", tint: .orange)
                stat("Ready", "\(plan.passes)", tint: .green)
                Spacer()
                Text("revision \(plan.manifestRevision) · \(plan.profileID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !plan.codeCounts.isEmpty {
                // Why nothing can execute, in the plan's own words.
                WrapLine {
                    ForEach(plan.codeCounts, id: \.code) { entry in
                        Text("\(entry.code.rawValue) ×\(entry.count)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            Text(observationText(plan))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func observationText(_ plan: ImportPlan) -> String {
        var parts = ["Source facts: \(plan.observation)"]
        if !plan.targetObserved {
            parts.append("the target group was never observed, so it is reported as unresolved rather than missing")
        }
        parts.append("no content digest was recorded, so this plan makes no statement about file bytes")
        return parts.joined(separator: " · ")
    }

    private func stat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rowView(_ row: ImportPlanRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.relativePath)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                verdictBadge(row.verdict)
            }
            HStack(spacing: 8) {
                Text(row.groupPath.isEmpty ? "no target group" : row.groupPath.joined(separator: " / "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !row.targetResolved {
                    Text("unresolved")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .background(.quaternary, in: Capsule())
                }
                if row.hydrationPending {
                    Text("not downloaded")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .background(.quaternary, in: Capsule())
                }
            }
            if !row.details.isEmpty {
                ForEach(Array(row.details.enumerated()), id: \.offset) { _, detail in
                    Text("• \(detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("import-row-\(row.sourceID.uuidString)")
    }

    private func verdictBadge(_ verdict: ImportPreflightVerdict) -> some View {
        let label: String
        let tint: Color
        switch verdict {
        case .pass: label = "ready"; tint = .green
        case .blocked: label = "blocked"; tint = .red
        case .deferred: label = "deferred"; tint = .orange
        }
        return Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.manifest == nil
                 ? "先在「映射」完成映射：计划由清单生成。"
                 : "尚未生成计划。用工具栏的「生成计划」查看导入会指向哪里、为何不能执行。")
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A minimal flow layout: enough for a row of reason chips, without pulling in a
/// layout system the rest of the app does not use.
///
/// The chips wrap. A row of reason codes is data, and how many there are is
/// not the window's business: a single line would demand the width of every
/// chip at once and put the window's minimum back where it was.
private struct WrapLine<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 220), spacing: 6)],
                  alignment: .leading, spacing: 6) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
