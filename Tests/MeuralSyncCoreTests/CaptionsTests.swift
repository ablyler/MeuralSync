import Foundation
import Testing
@testable import MeuralSyncCore

@Suite("Captions")
struct CaptionsTests {
    private static let sampleAliases: [String: String] = [
        "Robert Smith": "Pap",
        "Mary Smith": "Nana",
        "George Miller": "Grandpa",
        "Evelyn Miller": "Grandma",
        "Evie Miller": "Grandma",
        "Evelyn Davis": "Grandma",
    ]

    @Test("Family aliases map correctly")
    func familyAliases() {
        #expect(
            Captions.displayPersonNames(
                ["Robert Smith", "Mary Smith", "George Miller", "Evelyn Miller"],
                personAliases: Self.sampleAliases
            ) == ["Pap", "Nana", "Grandpa", "Grandma"]
        )
        #expect(Captions.displayPersonNames(["Evelyn Davis"], personAliases: Self.sampleAliases) == ["Grandma"])
        #expect(Captions.displayPersonNames(["Evie Miller"], personAliases: Self.sampleAliases) == ["Grandma"])
    }

    @Test("Aliases match whole names ignoring case and whitespace")
    func aliasesCaseAndWhitespace() {
        #expect(
            Captions.displayPersonNames(["  ROBERT   Smith ", "Robert Jones"], personAliases: Self.sampleAliases)
                == ["Pap", "Robert"]
        )
        #expect(Captions.displayPersonNames(["Robert Smith Jr."], personAliases: Self.sampleAliases) == ["Robert"])
    }

    @Test("Alternate names for Grandma are counted once")
    func alternateNamesCountedOnce() {
        #expect(
            Captions.formatPersonList(
                ["Evelyn Miller", "Evelyn Davis", "Evie Miller", "Robert Smith"],
                maxNames: 1,
                personAliases: Self.sampleAliases
            ) == "Grandma +1 other"
        )
    }

    @Test("Aliases preserve original inclusion priority")
    func aliasesPreservePriority() {
        #expect(
            Captions.displayPersonNames(
                ["Evelyn Miller", "Jane Doe", "Robert Smith", "Evelyn Davis"],
                includeList: ["Robert Smith", "Evelyn Davis"],
                personAliases: Self.sampleAliases
            ) == ["Pap", "Grandma", "Jane"]
        )
    }

    @Test("First-name collisions keep full names")
    func firstNameCollisions() {
        #expect(
            Captions.displayPersonNames(["Alex Smith", "Jane Doe", "Alex Jones", "Becca Smith"])
                == ["Alex Smith", "Jane", "Alex Jones", "Becca"]
        )
        #expect(
            Captions.displayPersonNames(["Jane Doe", "Jane Doe", "_UNKNOWN_", ""])
                == ["Jane"]
        )
        #expect(
            Captions.formatPersonList(
                ["Alex Smith", "Jane Doe", "Alex Jones"],
                includeList: ["Alex Jones"],
                maxNames: 1
            ) == "Alex Jones +2 others"
        )
        #expect(
            Captions.displayPersonNames(["Alex Smith", "alex Jones"])
                == ["Alex Smith", "alex Jones"]
        )
        #expect(Captions.displayPersonNames(["Mary-Jane Doe"]) == ["Mary-Jane"])
    }

    @Test("US geography is shortened while international is preserved")
    func geographyFormatting() {
        for label in [
            "Ann Arbor, Michigan, United States",
            "Ann Arbor, MI, USA",
            "Ann Arbor, Michigan",
        ] {
            #expect(Captions.formatLocation(label) == FormattedLocation(label: "Ann Arbor", iconName: nil))
        }
        #expect(
            Captions.formatLocation("Paris, Île-de-France, France")
                == FormattedLocation(label: "Paris, Île-de-France, France", iconName: nil)
        )
    }

    @Test("Parks and attractions resolve to expected labels and bundled icons")
    func parksAndAttractions() {
        #expect(
            Captions.formatLocation(
                "World Showcase, EPCOT, Walt Disney World Resort, Bay Lake, Florida, United States"
            ) == FormattedLocation(label: "EPCOT · World Showcase", iconName: "sphere")
        )
        #expect(Captions.formatLocation("Orlando, Florida, United States") == FormattedLocation(label: "Orlando", iconName: nil))
        #expect(
            Captions.formatLocation("Magic Kingdom Gift Shop, Ann Arbor, Michigan, United States")
                == FormattedLocation(label: "Magic Kingdom Gift Shop, Ann Arbor", iconName: nil)
        )
        #expect(
            Captions.formatLocation("Odd Photos label", aliases: ["odd photos LABEL": "EPCOT"])
                == FormattedLocation(label: "EPCOT", iconName: "sphere")
        )
        #expect(Captions.formatLocation(nil) == FormattedLocation(label: "", iconName: nil))

        // Verify entire bundled catalog
        #expect(Captions.attractions.count >= 34)
        for entry in Captions.attractions {
            #expect(Captions.iconURL(for: entry.icon) != nil)
            for alias in [entry.label] + entry.aliases {
                let formatted = Captions.formatLocation("\(alias), \(entry.park)")
                #expect(formatted == FormattedLocation(label: "\(entry.park) · \(entry.label)", iconName: entry.icon))
            }
        }
    }

    @Test("Ambiguous, wrong-park, and area-of-interest matching")
    func attractionEdgeCases() {
        #expect(Captions.formatLocation("Space Mountain, Disneyland Park").iconName == "ride-dl-space-mountain")
        #expect(Captions.formatLocation("Space Mountain, Magic Kingdom Park").iconName == "ride-mk-space-mountain")
        #expect(Captions.formatLocation("Space Mountain") == FormattedLocation(label: "Space Mountain", iconName: nil))
        #expect(Captions.formatLocation("Space Mountain, EPCOT") == FormattedLocation(label: "EPCOT · Space Mountain", iconName: "sphere"))
        #expect(Captions.formatLocation("Space Mountain, Haunted Mansion, Magic Kingdom").iconName == "castle")
        #expect(
            Captions.formatLocation("Kilimanjaro Safaris")
                == FormattedLocation(label: "Animal Kingdom · Kilimanjaro Safaris", iconName: "ride-ak-kilimanjaro-safaris")
        )
        #expect(
            Captions.formatLocation("Space Mountain, Walt Disney World Resort")
                == FormattedLocation(label: "Magic Kingdom · Space Mountain", iconName: "ride-mk-space-mountain")
        )
        #expect(Captions.formatLocation("Magic Kingdom · Peter Pan’s Flight™").iconName == "ride-mk-peter-pan-s-flight")
        #expect(Captions.formatLocation("Magic Kingdom - Space Mountain").iconName == "ride-mk-space-mountain")
        #expect(
            Captions.formatLocation("Guardians of the Galaxy – Mission: BREAKOUT!, California Adventure").iconName
                == "ride-dca-guardians-of-the-galaxy-mission-breakout"
        )
        #expect(
            Captions.formatLocation("EPCOT", areasOfInterest: ["Orlando Metropolitan Area", "Living with the Land"])
                == FormattedLocation(label: "EPCOT · Living with the Land", iconName: "ride-epcot-living-with-the-land")
        )
        #expect(
            Captions.formatLocation("Original place", aliases: ["Original place": "Home"], areasOfInterest: ["Space Mountain", "Magic Kingdom"])
                == FormattedLocation(label: "Home", iconName: nil)
        )
    }
}
