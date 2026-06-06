import Foundation

// Locale-aware number formatting. `String(format: "%.Nf", x)` always emits a
// "." decimal separator regardless of locale, so it reads wrong in pt-BR / de /
// fr (which use ","). These helpers route through `FormatStyle`, which honors
// the current locale — "3,5" in pt-BR, "3.5" in en-US — and the development
// language still gets the familiar "." output.
public extension Double {
  /// Locale-aware decimal string. Drop-in for `String(format: "%.Nf", self)`.
  func decimalString(_ fractionDigits: Int = 1) -> String {
    formatted(.number.precision(.fractionLength(fractionDigits)))
  }
}
