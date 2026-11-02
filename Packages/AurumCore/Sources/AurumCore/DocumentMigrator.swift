import Foundation

/// Upgrades saved documents from older schema versions.
///
/// Each step takes the JSON object of version N and returns version N + 1.
/// When the schema changes: bump `EditDocument.currentSchemaVersion`, add a
/// step here, and add a fixture of the old version to the test bundle.
public enum DocumentMigrator {
    public enum MigrationError: Error, Equatable {
        case notAnObject
        case newerThanSupported(Int)
    }

    typealias Step = ([String: Any]) throws -> [String: Any]

    /// steps[n] migrates version n + 1 to version n + 2.
    static let steps: [Step] = []

    public static func decode(_ data: Data) throws -> EditDocument {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationError.notAnObject
        }
        var version = object["schemaVersion"] as? Int ?? 1
        if version > EditDocument.currentSchemaVersion {
            throw MigrationError.newerThanSupported(version)
        }
        while version < EditDocument.currentSchemaVersion {
            object = try steps[version - 1](object)
            version += 1
            object["schemaVersion"] = version
        }
        let upgraded = try JSONSerialization.data(withJSONObject: object)
        return try EditDocument.makeDecoder().decode(EditDocument.self, from: upgraded)
    }
}
