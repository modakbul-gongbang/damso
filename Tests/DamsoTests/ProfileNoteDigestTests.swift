import Testing
@testable import Damso

/// `profile.md` is a file a human also edits by hand, so its Notes section
/// carries authoring syntax the profile screen must not show literally: a real
/// profile leaked `<!-- 사람이 직접 편집하는 영역. AI는 절대 수정하지 않음. -->`
/// and raw `- (date)` bullets into the UI.
@Test
func authoringCommentsAndBulletSyntaxNeverReachTheScreen() {
    let digest = ProfileNoteDigest.parse("""
    <!-- 사람이 직접 편집하는 영역. AI는 절대 수정하지 않음. -->
    - (2026-07-14) 커리큘럼 초안을 담당한다.
    - (2026-08-15) 부동산 경매 교육을 탐색한다.
    """)
    #expect(digest.freeform.isEmpty)
    #expect(digest.entries.map(\.text) == ["부동산 경매 교육을 탐색한다.", "커리큘럼 초안을 담당한다."])
    #expect(digest.entries.first?.date == "2026-08-15")
    #expect(!digest.plainText.contains("<!--"))
    #expect(!digest.plainText.contains("- ("))
}

/// Newest first: a profile accumulates for years, so the oldest fact must not
/// be the first one read. Notes sharing a date keep their file order.
@Test
func datedNotesAreNewestFirstAndSameDayNotesKeepFileOrder() {
    let digest = ProfileNoteDigest.parse("""
    - (2026-01-02) 첫 번째.
    - (2026-08-15) 같은 날 앞.
    - (2026-08-15) 같은 날 뒤.
    """)
    #expect(digest.entries.map(\.text) == ["같은 날 앞.", "같은 날 뒤.", "첫 번째."])
}

/// Hand-written prose has no date prefix. It is the user's own writing, so it
/// is kept and shown above the dated log rather than dropped as unparseable.
@Test
func handWrittenProseIsKeptSeparateFromTheDatedLog() {
    let digest = ProfileNoteDigest.parse("""
    회사 동료. 목요일 오후에는 연락이 안 된다.
    - (2026-08-15) 오픈소스 프로젝트를 분석한다.
    """)
    #expect(digest.freeform == ["회사 동료. 목요일 오후에는 연락이 안 된다."])
    #expect(digest.entries.count == 1)
}

@Test
func anEmptyOrCommentOnlyNotesSectionReadsAsEmpty() {
    #expect(ProfileNoteDigest.parse(nil).isEmpty)
    #expect(ProfileNoteDigest.parse("").isEmpty)
    #expect(ProfileNoteDigest.parse("<!-- nothing here -->\n\n---\n").isEmpty)
}
