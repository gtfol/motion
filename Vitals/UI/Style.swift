import SwiftUI
import UIKit

/// vitals' tokens. Canvas, text, secondary, divider, surface, caution, and error are the dark column of gtfol's
/// design standard (gtfol/ai DESIGN.md) as used by capsule's iPhone app. The larger numeric sizes and the zone
/// ramp are vitals' own choices for readable live numbers; they are not a published gtfol token set.
enum VitalsStyle {
    static let canvas = Color.black
    static let text = Color(white: 238 / 255)
    static let secondary = Color(white: 170 / 255)
    static let divider = Color(white: 44 / 255)
    static let surface = Color(white: 17 / 255)
    static let caution = Color(red: 212 / 255, green: 178 / 255, blue: 106 / 255)
    static let error = Color(red: 239 / 255, green: 150 / 255, blue: 150 / 255)

    static let body = Font.custom("Lato-Regular", size: 15, relativeTo: .subheadline)
    static let heading = Font.custom("Lato-Regular", size: 17, relativeTo: .headline)
    static let caption = Font.custom("Lato-Regular", size: 13, relativeTo: .footnote)
    /// Set-table numbers: large enough to read at arm's length.
    static let entry = Font.custom("Lato-Regular", size: 20, relativeTo: .title3)
    /// Elapsed and rest clocks.
    static let clock = Font.custom("Lato-Regular", size: 24, relativeTo: .title2)
    /// Live beats per minute.
    static let live = Font.custom("Lato-Regular", size: 56, relativeTo: .largeTitle)

    static let gutter: CGFloat = 20

    /// Approximate zone tint. Zones 1–3 stay neutral; only high intensity gets color, and the zone is always
    /// also written out, so color is never the only signal.
    static func zoneTint(_ zone: Int?) -> Color {
        switch zone {
        case 4?: caution
        case 5?: error
        default: text
        }
    }
}

extension View {
    func vitalsScreen() -> some View {
        font(VitalsStyle.body)
            .foregroundStyle(VitalsStyle.text)
            .tint(VitalsStyle.text)
            .background(VitalsStyle.canvas)
            .toolbarBackground(VitalsStyle.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    /// capsule's primary action: a solid off-white button with a 2 pt radius.
    func vitalsPrimaryAction() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 2))
            .controlSize(.large)
            .tint(VitalsStyle.text)
            .foregroundStyle(VitalsStyle.canvas)
    }

    func vitalsTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { Text(title).font(VitalsStyle.heading) } }
    }
}

extension ToolbarContent {
    /// Keeps toolbar items plain on iOS 26 instead of grouping them on a glass background.
    @ToolbarContentBuilder func quietBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(VitalsStyle.divider).frame(height: 0.5).accessibilityHidden(true)
    }
}

/// A section label in the quiet capsule style: heading text, no card.
struct SectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(VitalsStyle.heading)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(VitalsStyle.caption).foregroundStyle(VitalsStyle.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// capsule's information popover, for explanations that shouldn't crowd the screen.
struct InfoButton: View {
    let title: String
    let paragraphs: [String]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(VitalsStyle.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("about \(title)")
        .accessibilityHint("opens more information")
        .popover(isPresented: $showing, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(title).font(VitalsStyle.heading)
                        Spacer(minLength: 8)
                        Button { showing = false } label: {
                            Image(systemName: "xmark").font(.system(size: 12)).frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("close information")
                    }
                    ForEach(paragraphs, id: \.self) { paragraph in
                        Text(paragraph).font(VitalsStyle.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .frame(idealWidth: dynamicTypeSize.isAccessibilitySize ? nil : 280,
                   maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 320,
                   idealHeight: dynamicTypeSize.isAccessibilitySize ? nil : 260,
                   maxHeight: dynamicTypeSize.isAccessibilitySize ? .infinity : 420)
            .foregroundStyle(VitalsStyle.text)
            .presentationBackground(VitalsStyle.canvas)
            .presentationCompactAdaptation(dynamicTypeSize.isAccessibilitySize ? .sheet : .popover)
            .preferredColorScheme(.dark)
        }
    }
}

/// A plain text action at least 44 pt tall, the default control on quiet screens.
struct TextAction: View {
    let title: String
    var role: ButtonRole?
    var secondary = false
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, secondary: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.secondary = secondary; self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(secondary ? VitalsStyle.secondary : VitalsStyle.text)
    }
}

@MainActor enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
