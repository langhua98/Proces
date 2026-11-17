import Foundation
import SwiftUI

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []

    init() {
        load()
    }

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: ProjectPaths.root, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: ProjectPaths.root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var list: [Project] = []
        for d in dirs {
            let manifest = d.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: manifest),
               let p = try? decoder.decode(Project.self, from: data) {
                list.append(p)
            }
        }
        projects = list.sorted { $0.createdAt > $1.createdAt }
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    func save(_ p: Project) {
        do {
            try FileManager.default.createDirectory(at: ProjectPaths.dir(p.id), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(p)
            try data.write(to: ProjectPaths.manifest(p.id), options: .atomic)
        } catch {
            print("保存项目失败: \(error)")
        }
        if let i = projects.firstIndex(where: { $0.id == p.id }) {
            projects[i] = p
        } else {
            projects.insert(p, at: 0)
        }
    }

    func delete(_ p: Project) {
        try? FileManager.default.removeItem(at: ProjectPaths.dir(p.id))
        projects.removeAll { $0.id == p.id }
    }
}
