import Foundation

struct GrammarModel: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String

    static let defaultID = "mlx-community/Qwen3.5-2B-4bit"

    static let catalog = [
        GrammarModel(id: "mlx-community/Qwen3.5-2B-4bit", name: "Qwen3.5 2B", note: "best quality · ~1.6 GB"),
        GrammarModel(id: "mlx-community/Qwen3.5-0.8B-4bit", name: "Qwen3.5 0.8B", note: "fastest · ~0.6 GB"),
        GrammarModel(id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B", note: "~1 GB"),
        GrammarModel(id: "mlx-community/gemma-3-1b-it-qat-4bit", name: "Gemma 3 1B", note: "~0.7 GB"),
    ]

    static func named(_ id: String) -> String {
        if let known = catalog.first(where: { $0.id == id }) { return known.name }
        let last = id.split(separator: "/").last.map(String.init) ?? id
        return last.replacingOccurrences(of: "-", with: " ")
    }

    static func isDownloaded(_ id: String) -> Bool {
        if id.hasPrefix("/") { return FileManager.default.fileExists(atPath: id + "/config.json") }
        let folder = "models--" + id.replacingOccurrences(of: "/", with: "--")
        let snapshots = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/\(folder)/snapshots")
        let fm = FileManager.default
        guard let revision = try? fm.contentsOfDirectory(atPath: snapshots.path).first else { return false }
        let snapshot = snapshots.appendingPathComponent(revision)
        let files = (try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? []
        guard files.contains("config.json"), files.contains(where: { $0.hasSuffix(".safetensors") }) else { return false }
        return requiredWeights(in: snapshot, files: files).allSatisfy { name in
            fm.fileExists(atPath: snapshot.appendingPathComponent(name).resolvingSymlinksInPath().path)
        }
    }

    private static func requiredWeights(in snapshot: URL, files: [String]) -> Set<String> {
        let index = snapshot.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: index),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String]
        else { return Set(files.filter { $0.hasSuffix(".safetensors") }) }
        return Set(weightMap.values)
    }
}
