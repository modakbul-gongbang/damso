import AppKit
import SwiftUI

struct DamsoRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let white = DamsoRGB(red: 1, green: 1, blue: 1)
    static let darkSurface = DamsoRGB(red: 0.12, green: 0.12, blue: 0.12)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        self.red = Double((hex >> 16) & 0xFF) / 255
        self.green = Double((hex >> 8) & 0xFF) / 255
        self.blue = Double(hex & 0xFF) / 255
    }

    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(on surface: DamsoRGB) -> Double {
        let lighter = max(relativeLuminance, surface.relativeLuminance)
        let darker = min(relativeLuminance, surface.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: 1)
    }

    var color: Color {
        Color(nsColor: nsColor)
    }
}

struct DamsoAdaptiveColor: Sendable {
    let light: DamsoRGB
    let dark: DamsoRGB

    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let selected = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return selected.nsColor
        })
    }

    var meetsTextContrast: Bool {
        light.contrast(on: DamsoTokens.canvasSpec.light) >= 4.5
            && dark.contrast(on: DamsoTokens.canvasSpec.dark) >= 4.5
    }
}

/// A fixed pastel block from the editorial design language. Blocks keep the
/// same value in light and dark appearance so they read as physical sticky
/// notes on either canvas, and text on a block always uses the block ink.
struct DamsoBlockColor: Equatable, Sendable {
    let fill: DamsoRGB
    let ink: DamsoRGB

    var fillColor: Color { fill.color }
    var inkColor: Color { ink.color }

    var meetsTextContrast: Bool {
        ink.contrast(on: fill) >= 4.5
    }
}

/// Design tokens translated from the reference editorial design system
/// (confident black-and-white frame interrupted by hand-cut pastel blocks)
/// into macOS-native values: system typography at native scales, adaptive
/// monochrome ink/canvas, appearance-invariant pastel blocks, and semantic
/// state colors regression-tested at 4.5:1 or higher.
enum DamsoTokens {
    // MARK: Monochrome frame

    static let inkSpec = DamsoAdaptiveColor(
        light: DamsoRGB(hex: 0x0A0A0A),
        dark: DamsoRGB(hex: 0xF5F5F2)
    )
    static let inkSecondarySpec = DamsoAdaptiveColor(
        light: DamsoRGB(hex: 0x4D4D4D),
        dark: DamsoRGB(hex: 0xA8A8A4)
    )
    static let canvasSpec = DamsoAdaptiveColor(
        light: DamsoRGB.white,
        dark: DamsoRGB.darkSurface
    )
    static let surfaceSoftSpec = DamsoAdaptiveColor(
        light: DamsoRGB(hex: 0xF7F7F5),
        dark: DamsoRGB(hex: 0x262626)
    )
    static let hairlineSpec = DamsoAdaptiveColor(
        light: DamsoRGB(hex: 0xE6E6E6),
        dark: DamsoRGB(hex: 0x333333)
    )

    // MARK: Semantic state (adaptive, contrast-tested)

    /// Product accent: the deep lilac side of the block palette, used for
    /// selection and interactive emphasis where pure ink would lose state.
    static let accentSpec = DamsoAdaptiveColor(
        light: DamsoRGB(hex: 0x5B3FAE),
        dark: DamsoRGB(hex: 0xC5B0F4)
    )
    static let warningSpec = DamsoAdaptiveColor(
        light: DamsoRGB(hex: 0x853D05),
        dark: DamsoRGB(hex: 0xFFB35E)
    )
    /// Live recording and destructive-looking stop state, derived from the
    /// design system's magenta and darkened to hold 4.5:1 on white.
    static let criticalSpec = DamsoAdaptiveColor(
        light: DamsoRGB(hex: 0xB3125F),
        dark: DamsoRGB(hex: 0xFF7AB8)
    )
    static let successSpec = DamsoAdaptiveColor(
        light: DamsoRGB(hex: 0x11703A),
        dark: DamsoRGB(hex: 0x5FD68D)
    )

    static var allSemanticSpecs: [DamsoAdaptiveColor] {
        [inkSpec, inkSecondarySpec, accentSpec, warningSpec, criticalSpec, successSpec]
    }

    // MARK: Pastel blocks (appearance-invariant)

    private static let blockInk = DamsoRGB(hex: 0x0A0A0A)

    static let blockLime = DamsoBlockColor(fill: DamsoRGB(hex: 0xDCEEB1), ink: blockInk)
    static let blockLilac = DamsoBlockColor(fill: DamsoRGB(hex: 0xC5B0F4), ink: blockInk)
    static let blockCream = DamsoBlockColor(fill: DamsoRGB(hex: 0xF4ECD6), ink: blockInk)
    static let blockPink = DamsoBlockColor(fill: DamsoRGB(hex: 0xEFD4D4), ink: blockInk)
    static let blockMint = DamsoBlockColor(fill: DamsoRGB(hex: 0xC8E6CD), ink: blockInk)
    static let blockCoral = DamsoBlockColor(fill: DamsoRGB(hex: 0xF3C9B6), ink: blockInk)
    static let blockNavy = DamsoBlockColor(fill: DamsoRGB(hex: 0x1F1D3D), ink: DamsoRGB.white)

    static var allBlocks: [DamsoBlockColor] {
        [blockLime, blockLilac, blockCream, blockPink, blockMint, blockCoral, blockNavy]
    }

    // MARK: Convenience colors

    static var ink: Color { inkSpec.color }
    static var inkSecondary: Color { inkSecondarySpec.color }
    static var canvas: Color { canvasSpec.color }
    static var surfaceSoft: Color { surfaceSoftSpec.color }
    static var hairline: Color { hairlineSpec.color }
    static var accent: Color { accentSpec.color }
    static var accentMuted: Color { blockLilac.fillColor.opacity(0.28) }
    /// Focused-selection surface: the adaptive accent at a low opacity, so a
    /// selected list row reads as focused on both light and dark canvases
    /// while its ink keeps full contrast.
    static var accentFocusFill: Color { accentSpec.color.opacity(0.16) }
    static var warning: Color { warningSpec.color }
    static var critical: Color { criticalSpec.color }
    static var success: Color { successSpec.color }

    // MARK: Radius scale (translated: xs 2 / sm 6 / md 8 / lg 24 / pill)

    static let radiusXS: CGFloat = 2
    static let radiusSM: CGFloat = 6
    static let radius: CGFloat = 12
    static let compactRadius: CGFloat = 8
    static let radiusLG: CGFloat = 24

    // MARK: Spacing (8pt grid)

    static let spacingXXS: CGFloat = 4
    static let spacingXS: CGFloat = 8
    static let spacingSM: CGFloat = 12
    static let spacing: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32
}

// MARK: Typography helpers

extension Font {
    /// The mono eyebrow/caption voice of the editorial system, translated to
    /// the system monospaced face at native caption scale.
    static var damsoEyebrow: Font {
        .system(.caption, design: .monospaced).weight(.medium)
    }

    static var damsoMonoCaption: Font {
        .system(.caption, design: .monospaced)
    }

    /// Editorial display voice: large system type at a lighter weight,
    /// standing in for the reference 340-weight display face.
    static var damsoDisplay: Font {
        .system(.largeTitle, design: .default).weight(.medium)
    }
}

/// Pill-shaped primary button: ink background, canvas text.
struct DamsoPillButtonStyle: ButtonStyle {
    enum Rank {
        case primary
        case secondary
    }

    var rank: Rank = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .foregroundStyle(rank == .primary ? DamsoTokens.canvas : DamsoTokens.ink)
            .background(
                Capsule().fill(rank == .primary ? DamsoTokens.ink : DamsoTokens.canvas)
            )
            .overlay(
                Capsule().strokeBorder(DamsoTokens.ink.opacity(rank == .primary ? 0 : 0.9), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct StatusPill: View {
    enum Tone {
        case recording
        /// Machine is working right now (transcribing, summarizing): accent
        /// with a pulsing dot so activity reads at a glance.
        case active
        case pending
        /// The user's turn or a retryable stop (speaker confirmation,
        /// summary retry): warning, distinct from passive waiting.
        case attention
        /// A failure state that needs investigation, not just a retry.
        case failed
        case complete
        case neutral

        var color: Color {
            switch self {
            case .recording: DamsoTokens.critical
            case .active: DamsoTokens.accent
            case .pending: DamsoTokens.accent
            case .attention: DamsoTokens.warning
            case .failed: DamsoTokens.critical
            case .complete: DamsoTokens.success
            case .neutral: DamsoTokens.inkSecondary
            }
        }

        var isAnimated: Bool {
            switch self {
            case .recording, .active: true
            default: false
            }
        }
    }

    let title: String
    let tone: Tone

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: tone == .recording ? "record.circle.fill" : "circle.fill")
                .symbolEffect(.pulse, options: .repeating, isActive: tone.isAnimated)
        }
        .font(.damsoEyebrow)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(tone.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tone.color.opacity(0.12), in: Capsule())
        .accessibilityLabel(title)
    }
}

/// One shared mapping from a record's pipeline stage to its pill, so the
/// meeting log row and the detail header can never disagree: gray while
/// waiting, pulsing accent while a machine stage runs, warning when it is
/// the user's turn, critical on failure.
extension ProcessingStage {
    var pillTitle: String {
        switch self {
        case .captured, .queued: Loc.tr("Waiting to transcribe")
        case .transcribing: Loc.tr("Transcribing")
        case .speakerReview: Loc.tr("Speakers need confirmation")
        case .summarizing: Loc.tr("Summarizing")
        case .complete: Loc.tr("Complete")
        case .partial: Loc.tr("Summary retry needed")
        case .failed, .quarantined: Loc.tr("Needs attention")
        }
    }

    var pillTone: StatusPill.Tone {
        switch self {
        case .captured, .queued: .neutral
        case .transcribing, .summarizing: .active
        case .speakerReview, .partial: .attention
        case .failed, .quarantined: .failed
        case .complete: .complete
        }
    }
}

extension MeetingRecord {
    /// Record-aware pill: `speakerReview` alone cannot tell "the user still
    /// has to confirm speakers" (orange, their turn) from "speakers already
    /// resolved, only the summary is missing" (neutral, informational). The
    /// saved resolutions and summary resolve that so the meeting log does not
    /// nag about work that is already done.
    var pillTitle: String {
        if stage == .speakerReview, !resolutions.isEmpty {
            return summary == nil ? Loc.tr("Summary pending") : Loc.tr("Complete")
        }
        return stage.pillTitle
    }

    var pillTone: StatusPill.Tone {
        if stage == .speakerReview, !resolutions.isEmpty {
            return summary == nil ? .neutral : .complete
        }
        return stage.pillTone
    }
}

/// A small pastel block chip: block fill with block ink text, used for stage
/// and identity accents that should read identically in light and dark.
struct BlockChip: View {
    let title: String
    let block: DamsoBlockColor

    var body: some View {
        Text(title)
            .font(.damsoEyebrow)
            .foregroundStyle(block.inkColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(block.fillColor, in: RoundedRectangle(cornerRadius: DamsoTokens.radiusSM))
            .accessibilityLabel(title)
    }
}
