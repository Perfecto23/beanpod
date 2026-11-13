import Foundation

/// 项目：把几条录音、素材放在一起管。比如「新品发布」下面放三次周会录音和两条竞品视频。
/// 一条录音只归一个项目；删掉项目，里面的录音不删，只是不再归类。
extension BeanStore {
    private var projectsURL: URL { folder.appendingPathComponent("projects.json") }

    func loadProjects() {
        guard let data = try? Data(contentsOf: projectsURL),
              let list = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = list
    }

    private func saveProjects() {
        try? JSONEncoder().encode(projects).write(to: projectsURL, options: .atomic)
    }

    func project(_ id: UUID?) -> Project? { id.flatMap { pid in projects.first { $0.id == pid } } }

    func count(in project: UUID) -> Int { recordings.filter { $0.project == project }.count }

    @discardableResult
    func createProject(_ name: String) -> UUID? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if let same = projects.first(where: { $0.name == n }) { return same.id }
        let p = Project(name: String(n.prefix(40)))
        projects.append(p)
        saveProjects()
        addLog("新建项目「\(p.name)」")
        return p.id
    }

    func renameProject(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = String(n.prefix(40))
        saveProjects()
    }

    /// 删掉项目：里面的录音都留着，只是不再归这个项目。
    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for i in recordings.indices where recordings[i].project == id { recordings[i].project = nil }
        saveProjects()
        saveLibrary()
    }

    /// 把几条录音放进一个项目（nil 是移出项目）。
    func move(_ ids: Set<UInt32>, to project: UUID?) {
        var moved = 0
        for i in recordings.indices where ids.contains(recordings[i].id) {
            recordings[i].project = project
            moved += 1
        }
        saveLibrary()
        if moved > 0 {
            toast("folder", project.flatMap { self.project($0)?.name }.map { "\(moved) 条放进了「\($0)」" } ?? "\(moved) 条移出了项目")
        }
    }

    func setStar(_ ids: Set<UInt32>, _ on: Bool) {
        for i in recordings.indices where ids.contains(recordings[i].id) { recordings[i].starred = on }
        saveLibrary()
    }
}
