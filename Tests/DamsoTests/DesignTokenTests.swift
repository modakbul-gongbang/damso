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
