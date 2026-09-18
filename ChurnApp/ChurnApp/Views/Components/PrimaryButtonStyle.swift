//
//  PrimaryButtonStyle.swift
//  ChurnApp
//
//  Shared chrome for the app's primary call-to-action buttons ("Save",
//  "Add Account", etc.) so every form doesn't restyle a Button by hand.
//  Most buttons in the app should just use the system `.borderedProminent`
//  style directly — this only exists for the handful of cases that need a
//  full-width, capsule-shaped CTA (e.g. bottom-of-form save buttons) that
//  `.borderedProminent` alone doesn't give you.
//

import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {

    /// When true, the button fills the available width — used for
    /// bottom-of-sheet primary actions. Inline buttons (e.g. inside a card)
    /// should leave this false.
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.vertical, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 20)
            .foregroundStyle(.white)
            // Tint-colored capsule fill dims on press via `.opacity` keyed
            // off `isPressed` — the standard SwiftUI recipe for custom
            // pressed-state feedback since `ButtonStyle` gives no automatic
            // highlight the way `.borderedProminent` does internally.
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    /// `.buttonStyle(.primary)` convenience, matching how system styles
    /// like `.borderedProminent` are spelled.
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }

    static func primary(fullWidth: Bool) -> PrimaryButtonStyle {
        PrimaryButtonStyle(fullWidth: fullWidth)
    }
}

// MARK: - Previews

#Preview("Full width") {
    VStack(spacing: 16) {
        Button("Add Account") {}
            .buttonStyle(.primary)
        Button("Save Changes") {}
            .buttonStyle(.primary(fullWidth: true))
    }
    .padding()
}

#Preview("Inline") {
    HStack {
        Button("Save") {}
            .buttonStyle(.primary(fullWidth: false))
        Button("Cancel") {}
            .buttonStyle(.bordered)
    }
    .padding()
}

#Preview("Dark mode") {
    Button("Add Account") {}
        .buttonStyle(.primary)
        .padding()
        .preferredColorScheme(.dark)
}
