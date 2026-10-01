import SwiftUI
import UIKit

/// Motion's Iron-inspired palette: blue actions, red heart rate, yellow rest and records.
/// Lighter foreground variants keep small labels readable on charcoal. Labels and symbols
/// carry meaning as well as color, including the green completed-set checkmark.
enum VitalsStyle {
    static let canvas = Color(red: 24 / 255, green: 24 / 255, blue: 26 / 255)
    static let text = Color(white: 244 / 255)
    static let secondary = Color(red: 180 / 255, green: 181 / 255, blue: 188 / 255)
    static let divider = Color(red: 58 / 255, green: 59 / 255, blue: 64 / 255)
    static let surface = Color(red: 36 / 255, green: 37 / 255, blue: 41 / 255)
    static let accent = Color(red: 104 / 255, green: 173 / 255, blue: 255 / 255)
    static let heart = Color(red: 255 / 255, green: 119 / 255, blue: 123 / 255)
    static let success = Color(red: 118 / 255, green: 214 / 255, blue: 152 / 255)
    static let caution = Color(red: 242 / 255, green: 203 / 255, blue: 66 / 255)
    static let error = heart

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

    /// Approximate intensity is always also labeled with its zone number.
    static func zoneTint(_ zone: Int?) -> Color {
        switch zone {
        case 1?: secondary
        case 2?: accent
        case 3?: success
        case 4?: caution
        case 5?: error
        default: heart
        }
    }
}

extension View {
    func vitalsScreen() -> some View {
        font(VitalsStyle.body)
            .foregroundStyle(VitalsStyle.text)
            .tint(VitalsStyle.accent)
            .background(VitalsStyle.canvas)
            .toolbarBackground(VitalsStyle.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    /// A clear blue primary action with a dark label for contrast.
    func vitalsPrimaryAction() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 10))
            .controlSize(.large)
            .tint(VitalsStyle.accent)
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
    @Environment(\.isEnabled) private var isEnabled
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
        .foregroundStyle(role == .destructive ? VitalsStyle.error : secondary ? VitalsStyle.secondary : VitalsStyle.accent)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

@MainActor enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
