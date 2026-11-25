import Foundation

/// The width bounds one shell column may take.
///
/// The numbers are the shell's contract, not a view's preference: the window's
/// minimum size is the sum of the minimums of every column on screen, so a
/// column that declares no bound measures its content instead and lets the
/// window grow past the screen (owner failure #2, field defect A3: a 1512pt
/// display produced a 1845-1941pt minimum window).
public struct ShellColumnWidth: Equatable, Sendable {
    /// The narrowest the column may become. Hard: it is the floor the window
    /// minimum is computed from.
    public let min: Double
    /// The width the column prefers. Soft: it never raises the minimum.
    public let ideal: Double
    /// The widest the column may become before it truncates its content.
    /// A finite maximum is what keeps a long path or a long list of codes
    /// from becoming a window-width demand.
    public let max: Double

    public init(min: Double, ideal: Double, max: Double) {
        self.min = min
        self.ideal = ideal
        self.max = max
    }
}

/// The tables the shell draws, and therefore the column budgets it declares.
///
/// Each case names one table; `ShellLayout.columns(for:)` returns that
/// table's columns in the order the view declares them.
public enum ShellTable: String, CaseIterable, Sendable {
    /// The workspace file table.
    case workspaceFiles
    /// The workspace project-candidate table.
    case workspaceCandidates
    /// The mapping result table.
    case mappingRows
    /// The blocked-entry table.
    case exceptionRows
}

/// How much room the shell has for the area it is showing.
///
/// The three classes are a presentation contract, not a measurement: the
/// window width decides the class, and the class decides whether an auxiliary
/// panel is beside the main content or stacked above it. The main content is
/// never cropped in any class.
public enum ShellWidthClass: String, CaseIterable, Sendable, Equatable {
    /// Narrow: auxiliary panels stack, the main content keeps its full width.
    case compact
    /// The ordinary case: a side-by-side layout.
    case regular
    /// Wide: the auxiliary panels take their preferred width.
    case wide

    /// The class a content width falls into.
    ///
    /// The thresholds are declared here so the app and the tests agree on what
    /// "compact" means; the app measures the width it was given and asks.
    public static func classify(contentWidth: Double) -> ShellWidthClass {
        if contentWidth < ShellLayout.compactContentWidth { return .compact }
        if contentWidth < ShellLayout.wideContentWidth { return .regular }
        return .wide
    }
}

/// Every width the shell declares, in one place.
///
/// The app used to keep these numbers inside `FormaApplication.swift`, which
/// meant no test could see them and the window's minimum was whatever the
/// views happened to add up to. They live here now, so the budget is a
/// checkable contract: `ShellLayoutTests` computes the minimum window width
/// of every area from these numbers and holds it under
/// `ShellLayout.maximumWindowMinimumWidth`.
///
/// This is a geometry contract only. It says nothing about how the window
/// looks; the rendered result is still verified on a Mac.
public enum ShellLayout {
    /// The widest minimum any area may declare. The target is a window that
    /// fits a 1280pt-wide screen with its sidebar and inspector open.
    public static let maximumWindowMinimumWidth: Double = 1280

    /// The content width below which the shell is compact.
    public static let compactContentWidth: Double = 900
    /// The content width at which the shell is wide.
    public static let wideContentWidth: Double = 1400

    /// The area navigation column.
    public static let sidebar = ShellColumnWidth(min: 132, ideal: 168, max: 230)
    /// The context inspector column.
    public static let inspector = ShellColumnWidth(min: 240, ideal: 320, max: 480)

    /// The leading pane of each area's split view.
    public static func leading(for area: AppArea) -> ShellColumnWidth {
        switch area {
        case .workspace: ShellColumnWidth(min: 140, ideal: 180, max: 260)
        case .mapping: ShellColumnWidth(min: 190, ideal: 240, max: 380)
        case .exceptions: ShellColumnWidth(min: 180, ideal: 230, max: 330)
        case .reviewDesk: ShellColumnWidth(min: 200, ideal: 300, max: 400)
        case .importArchive, .settings: ShellColumnWidth(min: 0, ideal: 0, max: 0)
        }
    }

    /// The review desk's two panes: the file queue and the detail.
    ///
    /// The desk is not an `AppArea` on every branch - it arrives with the
    /// business rework - so its budget is declared here as two columns
    /// instead of as a case, and the desk's own area arithmetic is added by
    /// the branch that has the desk.
    public static let deskQueue = ShellColumnWidth(min: 200, ideal: 300, max: 400)
    public static let deskDetail = ShellColumnWidth(min: 320, ideal: 560, max: 900)

    /// The minimum width the review desk's own content needs.
    public static var deskMinimumContentWidth: Double {
        deskQueue.min + deskDetail.min
    }

    /// The columns of one table, in the order its view declares them.
    ///
    /// Every column is bounded on all three sides. A column without a bound
    /// measures its content, and a table's minimum is the sum of its columns'
    /// minima plus whatever the unbounded ones measured.
    public static func columns(for table: ShellTable) -> [ShellColumnWidth] {
        switch table {
        case .workspaceFiles:
            [
                ShellColumnWidth(min: 120, ideal: 220, max: 400),
                ShellColumnWidth(min: 100, ideal: 150, max: 260),
                ShellColumnWidth(min: 64, ideal: 88, max: 120),
                ShellColumnWidth(min: 76, ideal: 110, max: 170)
            ]
        case .workspaceCandidates:
            [
                ShellColumnWidth(min: 100, ideal: 150, max: 240),
                ShellColumnWidth(min: 56, ideal: 70, max: 100),
                ShellColumnWidth(min: 120, ideal: 190, max: 300),
                ShellColumnWidth(min: 64, ideal: 88, max: 120)
            ]
        case .mappingRows:
            [
                ShellColumnWidth(min: 110, ideal: 200, max: 380),
                ShellColumnWidth(min: 80, ideal: 110, max: 170),
                ShellColumnWidth(min: 76, ideal: 106, max: 160),
                ShellColumnWidth(min: 64, ideal: 88, max: 130),
                ShellColumnWidth(min: 80, ideal: 110, max: 170),
                ShellColumnWidth(min: 80, ideal: 110, max: 170),
                ShellColumnWidth(min: 52, ideal: 72, max: 110)
            ]
        case .exceptionRows:
            [
                ShellColumnWidth(min: 110, ideal: 200, max: 380),
                ShellColumnWidth(min: 72, ideal: 96, max: 140),
                ShellColumnWidth(min: 120, ideal: 180, max: 280),
                ShellColumnWidth(min: 88, ideal: 140, max: 240),
                ShellColumnWidth(min: 56, ideal: 76, max: 120)
            ]
        }
    }

    /// The table an area draws, if it draws one.
    public static func table(for area: AppArea) -> ShellTable? {
        switch area {
        case .workspace: .workspaceFiles
        case .mapping: .mappingRows
        case .exceptions: .exceptionRows
        case .reviewDesk, .importArchive, .settings: nil
        }
    }

    /// The narrowest table-column sum a pane may still show completely.
    public static func tableMinimumWidth(_ table: ShellTable) -> Double {
        columns(for: table).reduce(0) { $0 + $1.min }
    }

    /// One uniform floor for every area's own content.
    ///
    /// The window's minimum must not depend on which area happens to be
    /// mounted, or switching areas resizes the outer window - the second half
    /// of the physical acceptance failure (Archive at 1280pt jumped to 1645pt
    /// on entering Workspace). Every area therefore declares the same
    /// `minWidth` at the shell's content root, and the area's own views hold
    /// that promise: tables scroll horizontally inside the pane rather than
    /// pushing the floor up, and no pane's fitting width is consulted for the
    /// window minimum, because the scene resizability is `.contentMinSize`.
    /// 132 sidebar + 640 floor + 240 inspector = 1012pt with every column
    /// open - below the 1104pt the Owner had observed for the *smallest* area
    /// - and the floor alone (sidebar and inspector closed) is 640pt.
    public static let areaContentMinWidth: Double = 640

    /// The minimum width the area's own content needs.
    ///
    /// An area with a leading pane pays for that pane beside its table; an
    /// area without one pays only for its table. The review desk pays for
    /// both of its panes.
    public static func minimumContentWidth(for area: AppArea) -> Double {
        let leading = leading(for: area)
        switch area {
        case .reviewDesk:
            return deskMinimumContentWidth
        case .importArchive:
            return 360
        case .settings:
            return 340
        default:
            guard let table = table(for: area) else { return leading.min }
            // The workspace stacks its two tables vertically, so they compete
            // for the same width instead of adding up.
            let tableWidth = area == .workspace
                ? max(columns(for: .workspaceFiles).reduce(0) { $0 + $1.min },
                       columns(for: .workspaceCandidates).reduce(0) { $0 + $1.min })
                : columns(for: table).reduce(0) { $0 + $1.min }
            return leading.min + tableWidth
        }
    }

    /// The minimum width the whole window needs while this area is shown.
    ///
    /// The sidebar and the inspector are on screen at the same time as the
    /// area, so they are part of the minimum whether or not the area itself
    /// needs them.
    public static func minimumWindowWidth(for area: AppArea) -> Double {
        sidebar.min + minimumContentWidth(for: area) + inspector.min
    }

    /// The minimum window width over every area: the window's own floor.
    public static var minimumWindowWidth: Double {
        AppArea.allCases.map { minimumWindowWidth(for: $0) }.max() ?? 0
    }
}
