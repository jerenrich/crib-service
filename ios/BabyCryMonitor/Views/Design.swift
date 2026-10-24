import SwiftUI

enum Palette {
    static let background = Color(red: 0.047, green: 0.067, blue: 0.133)
    static let panel = Color(red: 0.106, green: 0.133, blue: 0.208)
    static let lavender = Color(red: 0.706, green: 0.698, blue: 0.929)
    static let mint = Color(red: 0.55, green: 0.86, blue: 0.76)
    static let muted = Color(red: 0.64, green: 0.73, blue: 0.79)
    static let amber = Color(red: 1, green: 0.75, blue: 0.44)
}
func durationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds)); return String(format: "%02d:%02d", value / 60, value % 60)
}
func spokenDuration(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    if value < 60 { return "\(value) sec" }
    return value % 60 == 0 ? "\(value / 60) min" : "\(value / 60) min \(value % 60) sec"
}
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 16) { content }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel, in: RoundedRectangle(cornerRadius: 24)) }
}
struct Caption: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(.caption, design: .rounded).weight(.semibold)).tracking(2).foregroundStyle(Palette.muted) }
}
struct StatusPill: View {
    let text: String; let active: Bool
    var body: some View { HStack(spacing: 8) { Circle().fill(active ? Palette.mint : Palette.amber).frame(width: 7, height: 7); Text(text).font(.subheadline.weight(.medium)) }.padding(.horizontal, 14).padding(.vertical, 9).background(.white.opacity(0.06), in: Capsule()).accessibilityElement(children: .combine) }
}
struct PrimaryButton: View {
    let title: String; var destructive = false; var action: () -> Void
    var body: some View { Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 18).background(destructive ? Palette.panel : Palette.mint, in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(destructive ? Color.white : Palette.background) }.buttonStyle(.plain) }
}
