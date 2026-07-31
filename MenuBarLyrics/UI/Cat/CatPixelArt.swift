import Foundation

/// User-selectable cat artwork. Declaration order is the order shown in Settings.
enum CatSkin: String, CaseIterable, Sendable {
    case maoMao = "maomao"
    case pangMaoMao = "pangmaomao"
    case miaoMiao = "miaomiao"
    case miMi = "mimi"

    var displayName: String {
        switch self {
        case .maoMao: "猫猫"
        case .pangMaoMao: "胖猫猫"
        case .miaoMiao: "喵喵"
        case .miMi: "咪咪"
        }
    }

    var spriteSheetResourceName: String { rawValue }
}

/// One exact cell in the approved 4-column × 3-row source sheet.
struct CatSheetCell: Equatable, Hashable, Sendable {
    let column: Int
    let row: Int
}

/// Semantic animation frames backed by the supplied design sheets.
///
/// The source artwork contains four idle poses, four play poses, and four DJ
/// poses. Fall/rise reuse the supplied jump and paw poses so every displayed
/// pixel still comes from the approved artwork rather than synthesized shapes.
enum CatFrame: String, CaseIterable, Sendable {
    case sit
    case blink
    case idleExcited
    case idleMusic
    case walkA
    case walkB
    case playA
    case playB
    case fallA
    case fallB
    case riseA
    case riseB
    case djA
    case djB
    case djC
    case djD

    var sheetCell: CatSheetCell {
        switch self {
        case .sit: CatSheetCell(column: 0, row: 0)
        case .blink: CatSheetCell(column: 1, row: 0)
        case .idleExcited: CatSheetCell(column: 2, row: 0)
        case .idleMusic: CatSheetCell(column: 3, row: 0)
        case .walkA, .fallB: CatSheetCell(column: 0, row: 1)
        case .walkB, .riseA: CatSheetCell(column: 1, row: 1)
        case .playA, .fallA, .riseB: CatSheetCell(column: 2, row: 1)
        case .playB: CatSheetCell(column: 3, row: 1)
        case .djA: CatSheetCell(column: 0, row: 2)
        case .djB: CatSheetCell(column: 1, row: 2)
        case .djC: CatSheetCell(column: 2, row: 2)
        case .djD: CatSheetCell(column: 3, row: 2)
        }
    }
}

enum CatAnimation: Sendable {
    case idle
    case walk
    case falling
    case rising
    case dj

    var frames: [CatFrame] {
        switch self {
        case .idle: [.sit, .blink, .idleExcited, .idleMusic]
        case .walk: [.walkA, .walkB, .playA, .playB]
        case .falling: [.fallA, .fallB]
        case .rising: [.riseA, .riseB]
        case .dj: [.djA, .djB, .djC, .djD]
        }
    }

    var frameDuration: TimeInterval {
        switch self {
        case .idle: 0.42
        case .walk: 0.22
        case .falling, .rising: 0.12
        case .dj: 0.18
        }
    }

    var repeats: Bool {
        switch self {
        case .falling, .rising: false
        case .idle, .walk, .dj: true
        }
    }
}
