//
//  DisplayPriorityStore.swift
//  DockPriority
//

import Foundation
import OSLog

protocol DisplayPriorityStoring {
    func load() throws -> StoredPriorityState?
    func save(_ state: StoredPriorityState) throws
}

final class UserDefaultsDisplayPriorityStore: DisplayPriorityStoring {
    static let storageKey = "displayPriority.state.v1"

    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(
        subsystem: "io.github.cinestill800t.DockPriority",
        category: "persistence"
    )

    init(defaults: UserDefaults = .standard, key: String = storageKey) {
        self.defaults = defaults
        self.key = key
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func load() throws -> StoredPriorityState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        do {
            let state = try decoder.decode(StoredPriorityState.self, from: data)
            guard state.schemaVersion == StoredPriorityState.currentSchemaVersion else {
                logger.error("Ignoring unsupported priority store schema version \(state.schemaVersion, privacy: .public)")
                return nil
            }
            return state.normalized()
        } catch {
            logger.error("Ignoring unreadable priority store: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ state: StoredPriorityState) throws {
        let normalized = StoredPriorityState(
            schemaVersion: StoredPriorityState.currentSchemaVersion,
            orderedDisplays: state.orderedDisplays
        ).normalized()
        let data = try encoder.encode(normalized)
        // UserDefaults replaces the value for one key atomically from this
        // process's perspective; no partial JSON or auxiliary keys are used.
        defaults.set(data, forKey: key)
    }
}
