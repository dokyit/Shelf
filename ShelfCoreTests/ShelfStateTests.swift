import Foundation
import Testing
@testable import ShelfCore

struct ShelfStateTests {
    @Test func newScopeDefaultsToAlwaysShow() {
        let layout = ShelfLayout()
        #expect(layout.section(for: "app:com.example.one") == .alwaysShow)
    }

    @Test func assignmentUpdatesSectionForWholeScope() {
        var layout = ShelfLayout()
        layout.assign("app:com.example.one", to: .onShelf)
        #expect(layout.section(for: "app:com.example.one") == .onShelf)
        #expect(layout.section(for: "app:com.example.two") == .alwaysShow)
    }

    @Test func closedShelfHidesOnShelfAndAlwaysHide() {
        var layout = ShelfLayout()
        layout.assign("app:com.example.one", to: .onShelf)
        layout.assign("app:com.example.two", to: .alwaysHide)
        layout.assign("app:com.example.three", to: .alwaysShow)
        let hidden = layout.hiddenScopes()
        #expect(hidden.contains("app:com.example.one"))
        #expect(hidden.contains("app:com.example.two"))
        #expect(!hidden.contains("app:com.example.three"))
    }

    @Test func inlineShelfRevealsOnShelfButNotAlwaysHide() {
        var layout = ShelfLayout()
        layout.assign("app:com.example.one", to: .onShelf)
        layout.assign("app:com.example.two", to: .alwaysHide)
        let hidden = layout.hiddenScopes(showShelfInMenuBar: true)
        #expect(!hidden.contains("app:com.example.one"))
        #expect(hidden.contains("app:com.example.two"))
    }

    @Test func temporaryRevealOnlyRevealsRequestedScope() {
        var layout = ShelfLayout()
        layout.assign("app:com.example.one", to: .onShelf)
        layout.assign("app:com.example.two", to: .onShelf)
        layout.assign("app:com.example.three", to: .alwaysHide)
        let hidden = layout.hiddenScopes(revealed: ["app:com.example.one"])
        #expect(!hidden.contains("app:com.example.one"))
        #expect(hidden.contains("app:com.example.two"))
        #expect(hidden.contains("app:com.example.three"))
    }

    @Test func layoutRoundTripsThroughJSON() throws {
        var layout = ShelfLayout()
        layout.assign("app:com.example.one", to: .onShelf)
        layout.assign("system:com.apple.menuextra.wifi", to: .alwaysHide)
        let data = try #require(layout.encoded())
        #expect(ShelfLayout.decoded(from: data) == layout)
    }

    @Test func rulesSurviveAbsentOwnersAndRenames() {
        var layout = ShelfLayout()
        layout.assign("app:com.example.one", to: .alwaysHide)
        let scopeStillHidden = layout.hiddenScopes()
        #expect(scopeStillHidden.contains("app:com.example.one"))
    }

    @Test func assignOrdersNewEntriesAfterExisting() {
        var layout = ShelfLayout()
        layout.assign("app:com.example.one", to: .onShelf)
        layout.assign("app:com.example.two", to: .onShelf)
        #expect(layout.rules["app:com.example.two"]?.order ?? -1 > (layout.rules["app:com.example.one"]?.order ?? -1))
    }

    @Test func bookCountMapping() {
        let vectors: [(Int, Int)] = [
            (-5, 0), (0, 0), (1, 1), (3, 3), (4, 4), (7, 4),
            (8, 5), (11, 5), (12, 6), (60, 6)
        ]
        for (items, books) in vectors {
            #expect(ShelfLayout.bookCount(for: items) == books)
        }
    }

    @Test func ownBundleNeverEntersHiddenTargets() {
        var layout = ShelfLayout()
        layout.assign("app:com.pinnyutility.Shelf", to: .alwaysHide)
        let targets = VisibilityPlan.hiddenTargets(
            layout: layout,
            revealed: [],
            showShelfInMenuBar: false,
            ownBundleID: "com.pinnyutility.Shelf"
        )
        #expect(!targets.bundles.contains("com.pinnyutility.Shelf"))
    }

    @Test func lockedSystemItemsNeverEntersHiddenTargets() {
        var layout = ShelfLayout()
        layout.assign("system:com.apple.menuextra.clock", to: .alwaysHide)
        layout.assign("system:com.apple.menuextra.controlcenter", to: .alwaysHide)
        layout.assign("system:com.apple.menuextra.wifi", to: .alwaysHide)
        let targets = VisibilityPlan.hiddenTargets(
            layout: layout,
            revealed: [],
            showShelfInMenuBar: false,
            ownBundleID: "com.pinnyutility.Shelf"
        )
        #expect(targets.systemCodes.isEmpty)
    }
}
