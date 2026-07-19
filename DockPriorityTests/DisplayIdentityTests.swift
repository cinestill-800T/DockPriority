import CoreGraphics
import Foundation
import Testing
@testable import DockPriority

struct DisplayIdentityTests {
    @Test func validEDIDRequiresAllNonZeroComponents() {
        #expect(EDIDDisplayKey.validating(vendorID: 1, productID: 2, serialNumber: 3) != nil)
        #expect(EDIDDisplayKey.validating(vendorID: 0, productID: 2, serialNumber: 3) == nil)
        #expect(EDIDDisplayKey.validating(vendorID: 1, productID: 0, serialNumber: 3) == nil)
        #expect(EDIDDisplayKey.validating(vendorID: 1, productID: 2, serialNumber: 0) == nil)
    }

    @Test func resolverPrefersUniqueValidEDID() {
        let key = EDIDDisplayKey(vendorID: 10, productID: 20, serialNumber: 30)
        let result = DisplayIdentityResolver.resolve([
            DisplayIdentityCandidate(edidKey: key, cgUUID: "uuid-a"),
            DisplayIdentityCandidate(edidKey: nil, cgUUID: "uuid-b")
        ])

        #expect(result == [.edid(key), .cgUUID("uuid-b")])
    }

    @Test func resolverFallsBackToUUIDForInvalidEDID() {
        let invalidKey = EDIDDisplayKey(vendorID: 10, productID: 20, serialNumber: 0)
        let result = DisplayIdentityResolver.resolve([
            DisplayIdentityCandidate(edidKey: invalidKey, cgUUID: " uuid-a ")
        ])

        #expect(result == [.cgUUID("uuid-a")])
    }

    @Test func duplicateEDIDsDowngradeEveryConflictingDisplay() {
        let duplicate = EDIDDisplayKey(vendorID: 10, productID: 20, serialNumber: 30)
        let unique = EDIDDisplayKey(vendorID: 11, productID: 21, serialNumber: 31)
        let result = DisplayIdentityResolver.resolve([
            DisplayIdentityCandidate(edidKey: duplicate, cgUUID: "uuid-a"),
            DisplayIdentityCandidate(edidKey: unique, cgUUID: "uuid-b"),
            DisplayIdentityCandidate(edidKey: duplicate, cgUUID: "uuid-c")
        ])

        #expect(result == [.cgUUID("uuid-a"), .edid(unique), .cgUUID("uuid-c")])
    }

    @Test func duplicateEDIDWithoutUUIDIsUnmanaged() {
        let duplicate = EDIDDisplayKey(vendorID: 10, productID: 20, serialNumber: 30)
        let result = DisplayIdentityResolver.resolve([
            DisplayIdentityCandidate(edidKey: duplicate, cgUUID: nil),
            DisplayIdentityCandidate(edidKey: duplicate, cgUUID: "uuid-b")
        ])

        #expect(result == [nil, .cgUUID("uuid-b")])
    }

    @Test func storedModelsRoundTripWithoutRuntimeDisplayID() throws {
        let state = StoredPriorityState(orderedDisplays: [
            RememberedDisplay(identity: .edid(.init(vendorID: 1, productID: 2, serialNumber: 3)), lastKnownName: "Primary"),
            RememberedDisplay(identity: .cgUUID("fallback"), lastKnownName: "Secondary")
        ])

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(StoredPriorityState.self, from: encoded)

        #expect(decoded == state)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("runtimeID"))
    }

    @Test func normalizationKeepsFirstOccurrenceAndOrder() {
        let first = RememberedDisplay(identity: .cgUUID("one"), lastKnownName: "First")
        let duplicate = RememberedDisplay(identity: .cgUUID("one"), lastKnownName: "Ignored")
        let second = RememberedDisplay(identity: .cgUUID("two"), lastKnownName: "Second")

        let normalized = StoredPriorityState(orderedDisplays: [first, duplicate, second]).normalized()

        #expect(normalized.orderedDisplays == [first, second])
    }
}
