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
        #expect(ShellWidthClass.classify(contentWidth: 0) == .compact)
        #expect(ShellWidthClass.classify(contentWidth: ShellLayout.compactContentWidth - 1) == .compact)
        #expect(ShellWidthClass.classify(contentWidth: ShellLayout.compactContentWidth) == .regular)
        #expect(ShellWidthClass.classify(contentWidth: ShellLayout.wideContentWidth - 1) == .regular)
        #expect(ShellWidthClass.classify(contentWidth: ShellLayout.wideContentWidth) == .wide)
        #expect(ShellWidthClass.classify(contentWidth: 10_000) == .wide)
    }

    /// M0-R2 (#153): under the default window policy the window's floor was
    /// the mounted content's *fitting* width, and it changed with the area -
    /// 1665pt at the Review Desk, 1645 at Workspace, on a 1512pt display.
    /// The scene now declares `.contentMinSize` and every area promises one
    /// uniform content floor; this is the arithmetic that promise has to hold.
    @Test("the shell declares one uniform window floor, and it fits the narrowest display in the field")
    func uniformWindowFloor() {
        let floor = ShellLayout.areaContentMinWidth
        // The decisive property: no area's own content demand may exceed the
        // uniform floor, or mounting that area raises the window above the
        // floor again - which is exactly how mapping's 542pt column sum beside
        // its 190pt panel once forced a 1104pt minimum (#172). With tables
        // scrolling their columns inside the pane, every table area now pays
        // only the usable table floor, so this must hold for every area.
        for area in AppArea.allCases {
            #expect(ShellLayout.minimumContentWidth(for: area) <= floor,
                    "\(area) demands more than the uniform floor; switching to it would resize the window")
        }
        // The floor must dominate the desk's two panes too.
        #expect(floor >= ShellLayout.deskMinimumContentWidth,
                "the floor is the one number; a bigger area demand splits it again")
        // Sidebar and inspector open (the launch state): below the 1104pt the
        // Owner saw for the *smallest* area, and below the 1180pt default.
        let everyColumn = ShellLayout.sidebar.min + floor + ShellLayout.inspector.min
        #expect(everyColumn <= 1104,
                "the window floor with every column open was 1104pt in the field; it must be below it")
        // The documented supported minimum: sidebar and inspector closed.
        #expect(floor <= 660,
                "the bare window minimum is the floor itself; it must stay a usable small window")
        // Tables may exceed the floor - that width belongs to the table's own
        // horizontal scroller inside the pane, never to the window. The
        // column sums stay declared budgets, not window demands.
        for table in ShellTable.allCases {
            let width = ShellLayout.tableMinimumWidth(table)
            #expect(width > 0)
            #expect(width >= ShellLayout.scrollableTableMinWidth)
        }
    }
}
