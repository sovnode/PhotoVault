import Testing
import Foundation
import PhotoVaultCore
@testable import PhotoVault

/// The question before a long tagging run. Nothing in the photos changes —
/// the tags go into the catalog — but a long run keeps the Mac busy.
@MainActor
@Suite("Tagging question")
struct TaggingQuestionTests {
    @Test func asksOnlyAboveAHundredPhotos() {
        #expect(LibraryModel.askAbove == 100)
    }

    @Test func aFirstRunSaysHowManyAndHowLongAndThatThePhotosArentChanged() {
        let q = LibraryModel.question(ids: nil, plan: Store.ClassifyPlan(photos: 9_876), secondsPerPhoto: 0.17)
        #expect(q.title == "Tag 9,876 photos with JoyTag?")
        #expect(q.action == "Tag Photos")
        #expect(q.message.contains("kept in PhotoVault's catalog"))
        #expect(q.message.contains("the photos themselves aren't changed"))
        #expect(q.message.contains("about 28 minutes"))
        #expect(q.message.contains("carries on the next time PhotoVault opens"))
        #expect(!q.message.contains("grows"), "the vault doesn't grow")
    }

    @Test func reTaggingSaysOldTagsAreReplaced() {
        let q = LibraryModel.question(ids: Array(1...250), plan: Store.ClassifyPlan(photos: 250), secondsPerPhoto: 0.17)
        #expect(q.title == "Re-tag 250 photos with JoyTag?")
        #expect(q.action == "Re-tag Photos")
        #expect(q.message.contains("Their JoyTag tags are replaced"))
        #expect(q.message.contains("It takes less than a minute."))
    }

    @Test func timesReadNaturally() {
        #expect(LibraryModel.roughly(30) == "less than a minute")
        #expect(LibraryModel.roughly(61) == "about a minute")
        #expect(LibraryModel.roughly(35 * 60) == "about 35 minutes")
        #expect(LibraryModel.roughly(2.5 * 3600) == "about 2.5 hours")
    }
}
