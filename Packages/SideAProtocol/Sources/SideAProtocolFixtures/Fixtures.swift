import Foundation

/// The shared wire fixtures, named `<Type>.<variant>`; forward-compatibility ones sit under `future/`.
public enum Fixtures {
    public enum Missing: Error { case fixture(String) }

    public static func data(_ name: String, version: String = "v1") throws -> Data {
        try Data(contentsOf: folder(version).appendingPathComponent(name + ".json"))
    }

    /// Every fixture of a version, `future/…` included, sorted.
    public static func names(version: String = "v1") -> [String] {
        let root = folder(version)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { String($0.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1).dropLast(5)) }
            .sorted()
    }

    /// A binary fixture (`TermFrame.output.bin`).
    public static func binary(_ name: String, version: String = "v1") throws -> Data {
        try Data(contentsOf: folder(version).appendingPathComponent(name + ".bin"))
    }

    /// Every fixture file, JSON and binary, with its extension.
    public static func files(version: String = "v1") -> [String] {
        let root = folder(version)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { ["json", "bin"].contains($0.pathExtension) }
            .map { String($0.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)) }
            .sorted()
    }

    /// The SHA-256 of every fixture that has shipped, as `<hex>  <file>` lines.
    public static func manifest(version: String = "v1") throws -> String {
        try String(contentsOf: folder(version).appendingPathComponent("MANIFEST"), encoding: .utf8)
    }

    public static func folder(_ version: String = "v1") -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(version)
    }
}
