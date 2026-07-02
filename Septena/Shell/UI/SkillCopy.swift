// Extracted from AboutAdvancedSettingsPanes.swift so shells that don't
// compile the full Settings surface (Septask) share the one pasteboard
// impl — see docs/SEPTASK.md.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Tiny cross-platform pasteboard wrapper. Lives at file scope so all
/// skill views (and the per-section detail pane footer) share one impl.
enum SkillCopy {
  static func copy(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
  }
}
