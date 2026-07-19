import Foundation
import Testing
@testable import DockPriority

struct DisplayPriorityStoreTests {
    @Test func emptyStoreLoadsNil() throws {
        let defaults = makeDefaults()
        let store = UserDefaultsDisplayPriorityStore(defaults: defaults)

        #expect(try store.load() == nil)
    }

    @Test func corruptDataLoadsNilWithoutThrowing() throws {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: UserDefaultsDisplayPriorityStore.storageKey)

        #expect(try UserDefaultsDisplayPriorityStore(defaults: defaults).load() == nil)
    }

    @Test func mismatchedSchemaLoadsNilWithoutThrowing() throws {
        let defaults = makeDefaults()
        let state = StoredPriorityState(schemaVersion: 99, orderedDisplays: [])
        defaults.set(try JSONEncoder().encode(state), forKey: UserDefaultsDisplayPriorityStore.storageKey)

        #expect(try UserDefaultsDisplayPriorityStore(defaults: defaults).load() == nil)
    }

    @Test func saveAndLoadPreservePriorityOrderAndDisconnectedEntries() throws {
        let defaults = makeDefaults()
        let store = UserDefaultsDisplayPriorityStore(defaults: defaults)
        let connected = RememberedDisplay(identity: .cgUUID("connected"), lastKnownName: "Connected")
        let disconnected = RememberedDisplay(
            identity: .edid(.init(vendorID: 9, productID: 8, serialNumber: 7)),
            lastKnownName: "Disconnected"
        )
        let state = StoredPriorityState(orderedDisplays: [connected, disconnected])

        try store.save(state)

        #expect(try store.load() == state)
    }

    @Test func loadNormalizesDuplicateIdentityWithoutChangingFirstName() throws {
        let defaults = makeDefaults()
        let first = RememberedDisplay(identity: .cgUUID("same"), lastKnownName: "Original")
        let duplicate = RememberedDisplay(identity: .cgUUID("same"), lastKnownName: "Later")
        let state = StoredPriorityState(orderedDisplays: [first, duplicate])
        defaults.set(try JSONEncoder().encode(state), forKey: UserDefaultsDisplayPriorityStore.storageKey)

        let loaded = try UserDefaultsDisplayPriorityStore(defaults: defaults).load()

        #expect(loaded?.orderedDisplays == [first])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "DockPriorityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
