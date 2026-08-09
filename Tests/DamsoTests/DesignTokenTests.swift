import Foundation
import Testing
@testable import Damso

@Test
func semanticColorsMeetTextContrastInSystemAppearances() {
    for spec in DamsoTokens.allSemanticSpecs {
        #expect(spec.meetsTextContrast)
    }
}

@Test
func pastelBlockInkMeetsTextContrastOnEveryBlock() {
    for block in DamsoTokens.allBlocks {
        #expect(block.meetsTextContrast)
    }
}

@Test
func semanticColorsRemainDistinct() {
    #expect(DamsoTokens.accentSpec.light != DamsoTokens.warningSpec.light)
    #expect(DamsoTokens.warningSpec.dark != DamsoTokens.criticalSpec.dark)
    #expect(DamsoTokens.criticalSpec.light != DamsoTokens.successSpec.light)
    #expect(DamsoTokens.inkSpec.light != DamsoTokens.inkSecondarySpec.light)
}

@Test
func editorialFrameIsMonochrome() {
    // The frame stays achromatic so the pastel blocks carry all the color.
    for spec in [DamsoTokens.inkSpec, DamsoTokens.canvasSpec, DamsoTokens.surfaceSoftSpec, DamsoTokens.hairlineSpec] {
        for value in [spec.light, spec.dark] {
            let spread = max(value.red, value.green, value.blue) - min(value.red, value.green, value.blue)
            #expect(spread < 0.03)
        }
    }
}

// MARK: Localization catalog resolution

@Test
func theStringCatalogResolvesFromTheAppsOwnLayoutRatherThanTheBuildMachinesPath() throws {
    // SwiftPM's `Bundle.module` looks only at the bundle root and at the
    // absolute .build path of whoever compiled the binary, then fatalErrors.
    // An installed app was silently reading strings out of the developer's
    // working copy and crashed on launch anywhere else - copied to another
    // Mac, or after .build was deleted.
    let url = try #require(Loc.catalogURL(), "the string catalog must be discoverable")
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(url.lastPathComponent == "Localizable.xcstrings")

    // A real translation proves the catalog was parsed, not merely located.
    #expect(Loc.tr("Retry", language: .korean) == "재시도")
    // A missing key degrades to itself instead of crashing.
    #expect(Loc.tr("__no_such_key__", language: .korean) == "__no_such_key__")
}
