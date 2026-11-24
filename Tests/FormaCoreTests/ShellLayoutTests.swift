import Foundation
import Testing

@testable import FormaCore

/// #150: a window's minimum width is the sum of the minimums of every column
/// on screen. A column that declares no bound measures its content instead,
/// and the window then grows past the display it is on - the field measured a
/// 1845-1941pt minimum window on a 1512pt screen, and the app could not be
/// used there at all.
///
/// The width budget is therefore a contract rather than a preference, and this
/// suite is what holds it: every area's minimum window width, computed from
/// the declared columns, has to fit the target display with the sidebar and
/// the inspector open.
///
/// The numbers are a geometry contract. What the window looks like is still
/// verified on a Mac; this only says the frame is allowed to exist.
@Suite("Shell layout budget")
struct ShellLayoutTests {
    @Test("every area fits the target window with its sidebar and inspector open")
    func everyAreaFitsTheWindow() {
        for area in AppArea.allCases {
            let width = ShellLayout.minimumWindowWidth(for: area)
            #expect(width <= ShellLayout.maximumWindowMinimumWidth,
                    "\(area.rawValue) needs \(width)pt, over the \(ShellLayout.maximumWindowMinimumWidth)pt budget")
        }
        #expect(ShellLayout.minimumWindowWidth <= ShellLayout.maximumWindowMinimumWidth,
                "the window's floor is the worst area, and it has to fit too")
    }

    @Test("no table column is unbounded")
    func noColumnIsUnbounded() {
        for table in ShellTable.allCases {
            for (index, column) in ShellLayout.columns(for: table).enumerated() {
                #expect(column.min > 0, "\(table.rawValue)[\(index)] declares no minimum")
                #expect(column.max.isFinite, "\(table.rawValue)[\(index)] has no maximum")
                #expect(column.min <= column.ideal,
                        "\(table.rawValue)[\(index)] prefers a width narrower than its minimum")
                #expect(column.ideal <= column.max,
                        "\(table.rawValue)[\(index)] prefers a width wider than its maximum")
            }
        }
    }

    @Test("the workspace's two tables share the width instead of each demanding their own")
    func workspaceTablesStack() {
        let files = ShellLayout.columns(for: .workspaceFiles).reduce(0) { $0 + $1.min }
        let candidates = ShellLayout.columns(for: .workspaceCandidates).reduce(0) { $0 + $1.min }
        let expected = ShellLayout.leading(for: .workspace).min + max(files, candidates)
        #expect(ShellLayout.minimumContentWidth(for: .workspace) == expected)
        #expect(ShellLayout.minimumContentWidth(for: .workspace)
                < ShellLayout.leading(for: .workspace).min + files + candidates,
                "the two tables are stacked, so their minimums compete for the same width")
    }

    @Test("the review desk's own panes fit the budget")
    func deskPanesFitTheBudget() {
        let width = ShellLayout.sidebar.min + ShellLayout.deskMinimumContentWidth + ShellLayout.inspector.min
        #expect(width <= ShellLayout.maximumWindowMinimumWidth)
        #expect(ShellLayout.deskQueue.min > 0)
        #expect(ShellLayout.deskDetail.min > 0)
    }

    @Test("the width classes are ordered and cover every width")
    func widthClassesAreOrdered() {
        #expect(ShellLayout.compactContentWidth < ShellLayout.wideContentWidth)
        #expect(ShellLayout.classify(contentWidth: 0) == .compact)
        #expect(ShellLayout.classify(contentWidth: ShellLayout.compactContentWidth - 1) == .compact)
        #expect(ShellLayout.classify(contentWidth: ShellLayout.compactContentWidth) == .regular)
        #expect(ShellLayout.classify(contentWidth: ShellLayout.wideContentWidth - 1) == .regular)
        #expect(ShellLayout.classify(contentWidth: ShellLayout.wideContentWidth) == .wide)
        #expect(ShellLayout.classify(contentWidth: 10_000) == .wide)
    }
}
