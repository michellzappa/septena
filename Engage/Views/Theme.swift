import SwiftUI

// Things-style design tokens. See docs/things-reference/visual-design.md

enum Theme {
  // Accent colors for smart lists
  static let inboxBlue = Color(red: 0.29, green: 0.56, blue: 0.89)        // #4A90E2
  static let todayYellow = Color(red: 1.00, green: 0.80, blue: 0.00)      // #FFCC00
  static let upcomingRed = Color(red: 0.91, green: 0.30, blue: 0.41)      // #E94D6A
  static let anytimeTeal = Color(red: 0.31, green: 0.75, blue: 0.72)      // #4EBFB8
  static let somedayTan = Color(red: 0.79, green: 0.66, blue: 0.46)       // #C9A876
  static let logbookGreen = Color(red: 0.37, green: 0.75, blue: 0.49)     // #5FBE7D

  static let overdueRed = Color(red: 1.00, green: 0.23, blue: 0.19)       // #FF3B30
  static let magicPlusBlue = Color(red: 0.04, green: 0.52, blue: 1.00)    // #0A84FF

  // Neutrals
  static let divider = Color(red: 0.90, green: 0.90, blue: 0.92)          // #E5E5EA
  static let rowSelected = Color(red: 0.91, green: 0.94, blue: 0.99)      // #E8F0FE
  static let chipBackground = Color(red: 0.95, green: 0.95, blue: 0.97)   // #F2F2F7

  // Spacing
  static let hPadding: CGFloat = 20
  static let rowHeight: CGFloat = 44
  static let sidebarRowHeight: CGFloat = 48
  static let sectionSpacing: CGFloat = 24
}

// Typography shortcuts
extension Font {
  static let thingsScreenTitle = Font.system(size: 28, weight: .bold)
  static let thingsSectionHeader = Font.system(size: 17, weight: .semibold)
  static let thingsSidebarRow = Font.system(size: 17, weight: .regular)
  static let thingsTaskTitle = Font.system(size: 16, weight: .regular)
  static let thingsMeta = Font.system(size: 13, weight: .regular)
  static let thingsBadge = Font.system(size: 13, weight: .semibold)
  static let thingsDayChip = Font.system(size: 12, weight: .regular)
}
