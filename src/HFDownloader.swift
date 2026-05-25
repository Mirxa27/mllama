import Foundation
import SwiftUI

// MARK: - Download domain

enum HFDownloadState: Equatable {
    case queued
    case running
    case paused
    case completed(URL)
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

struct HFDownloadProgress: Equatable {
    var bytesReceived: Int64
    var bytesTotal: Int64
    var bytesPerSecond: Double
    var etaSeconds: Double?

    var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesReceived) / Double(bytesTotal))
    }
    var humanReceived: String { ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file) }
    var humanTotal:    String { ByteCountFormatter.string(fromByteCount: bytesTotal,    countStyle: .file) }
    var humanRate:     String {
        let s = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(s)/s"
    }
    var humanETA: String {
        guard let eta = etaSeconds, eta.isFinite, eta > 0 else { return "—" }
        let m = Int(eta) / 60, s = Int(eta) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

/// One file from a HF repo being downloaded.
@MainActor
final class HFDownloadJob: ObservableObject, Identifiable {
    let id = UUID()
    let repoId: String
    let file: String
    let destination: URL

    @Published var state: HFDownloadState = .queued
    @Published var progress: HFDownloadProgress = .init(bytesReceived: 0, bytesTotal: 0, bytesPerSecond: 0, etaSeconds: nil)

    fileprivate var task: URLSessionDownloadTask?
    fileprivate var resumeData: Data?
    fileprivate var lastSampleAt: Date = .init()
    fileprivate var lastSampleBytes: Int64 = 0

    init(repoId: String, file: String, destination: URL) {
        self.repoId = repoId
        self.file = file
        self.destination = destination
    }

    var displayName: String { (file as NSString).lastPathComponent }
}

// MARK: - Download manager

/// Manages concurrent downloads from HuggingFace with resume support.
/// Uses a single URLSession to share connections and auth.
@MainActor
final class HFDownloadManager: NSObject, ObservableObject {
    static let shared = HFDownloadManager()

    @Published private(set) var jobs: [HFDownloadJob] = []

    /// Root directory we drop downloaded weights into. Mirrors the HF cache layout
    /// loosely: ~/.mllama/hf/{author}/{repo}/{file}
    var rootDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let custom = UserDefaults.standard.string(forKey: HFKeys.downloadsRoot), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".mllama/hf")
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 12 * 3600
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // delegate-side state keyed by task identifier
    private var tasksToJobs: [Int: UUID] = [:]

    func destination(repoId: String, file: String) -> URL {
        rootDirectory
            .appendingPathComponent(repoId)
            .appendingPathComponent(file)
    }

    /// Enqueue a download. Returns the job so UI can observe it.
    @discardableResult
    func enqueue(repoId: String, file: String) -> HFDownloadJob {
        let dest = destination(repoId: repoId, file: file)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        // If destination already exists with non-zero size and we can verify it
        // via HEAD, skip the work.
        if let existing = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let size = existing[.size] as? Int64, size > 0 {
            let job = HFDownloadJob(repoId: repoId, file: file, destination: dest)
            job.state = .completed(dest)
            job.progress = .init(bytesReceived: size, bytesTotal: size, bytesPerSecond: 0, etaSeconds: 0)
            jobs.append(job)
            return job
        }

        let job = HFDownloadJob(repoId: repoId, file: file, destination: dest)
        jobs.append(job)
        refreshDockBadge()
        Task { await start(job: job) }
        return job
    }

    func cancel(job: HFDownloadJob) {
        if let t = job.task {
            t.cancel(byProducingResumeData: { [weak job] data in
                Task { @MainActor in
                    job?.resumeData = data
                    job?.state = .cancelled
                }
            })
        }
        if !job.state.isTerminal { job.state = .cancelled }
    }

    func pause(job: HFDownloadJob) {
        guard case .running = job.state, let t = job.task else { return }
        t.cancel(byProducingResumeData: { [weak job] data in
            Task { @MainActor in
                job?.resumeData = data
                job?.state = .paused
            }
        })
    }

    func resume(job: HFDownloadJob) async {
        let canResume: Bool
        switch job.state {
        case .paused, .failed:        canResume = true
        case .cancelled:              canResume = true
        case .queued, .running, .completed: canResume = false
        }
        guard canResume else { return }
        await start(job: job)
    }

    /// Bulk: download every file in the file list. Returns each job.
    @discardableResult
    func enqueueRepo(repoId: String, files: [HFFile]) -> [HFDownloadJob] {
        files.map { enqueue(repoId: repoId, file: $0.path) }
    }

    /// Remove all terminal jobs from the visible list.
    func clearCompleted() {
        jobs.removeAll { $0.state.isTerminal }
    }

    // MARK: - Private start/resume

    private func start(job: HFDownloadJob) async {
        let url = HuggingFaceClient.resolveURL(repoId: job.repoId, file: job.file)
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        if let token = await HuggingFaceClient.shared.token() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("Mllama/2.3", forHTTPHeaderField: "User-Agent")

        let task: URLSessionDownloadTask
        if let data = job.resumeData {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: req)
        }
        job.task = task
        job.resumeData = nil
        job.state = .running
        job.lastSampleAt = .init()
        job.lastSampleBytes = 0
        tasksToJobs[task.taskIdentifier] = job.id
        task.resume()
    }

    private func job(for taskID: Int) -> HFDownloadJob? {
        guard let id = tasksToJobs[taskID] else { return nil }
        return jobs.first { $0.id == id }
    }
}

// MARK: - URLSession delegate

extension HFDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // CRITICAL: the temp file at `location` is deleted as soon as this
        // delegate method returns. We MUST move it synchronously here, before
        // hopping back to MainActor. (Reading via Data(contentsOf:) would OOM
        // for multi-GB GGUF files.) We move it to a stable tmp path next to
        // its final destination, then finish the rename on the main actor.
        let taskID = downloadTask.taskIdentifier
        let moveResult: Result<URL, Error>
        do {
            // Stage inside the same APFS volume as the final destination so the
            // later move-into-place is intra-volume (atomic, no cross-volume
            // copy). NSTemporaryDirectory could be on a different volume for
            // some users (network homes, multi-volume setups).
            let stagingDir: URL = {
                if let home = UserDefaults.standard.string(forKey: HFKeys.downloadsRoot),
                   !home.isEmpty {
                    return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
                        .appendingPathComponent(".staging")
                }
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".mllama/hf/.staging")
            }()
            try FileManager.default.createDirectory(at: stagingDir,
                                                    withIntermediateDirectories: true)
            let staging = stagingDir.appendingPathComponent("dl-\(taskID)-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: staging)
            moveResult = .success(staging)
        } catch {
            moveResult = .failure(error)
        }

        Task { @MainActor in
            guard let job = self.job(for: taskID) else { return }
            switch moveResult {
            case .success(let staging):
                do {
                    try FileManager.default.createDirectory(
                        at: job.destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: job.destination.path) {
                        try FileManager.default.removeItem(at: job.destination)
                    }
                    try FileManager.default.moveItem(at: staging, to: job.destination)
                    job.state = .completed(job.destination)
                    NotificationCenterBridge.post(
                        kind: .downloadDone,
                        title: "Download complete",
                        body: "\(job.displayName)\n\(job.repoId)"
                    )
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    job.state = .failed("Could not save file: \(error.localizedDescription)")
                }
            case .failure(let e):
                job.state = .failed("Could not capture downloaded file: \(e.localizedDescription)")
            }
            job.task = nil
            self.tasksToJobs.removeValue(forKey: taskID)
            self.refreshDockBadge()
        }
    }

    @MainActor
    private func refreshDockBadge() {
        let active = jobs.filter {
            switch $0.state {
            case .running, .queued, .paused: return true
            default: return false
            }
        }.count
        DockBadge.shared.setDownloads(active)
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let job = job(for: taskID) else { return }
            let now = Date()
            let dt = max(0.001, now.timeIntervalSince(job.lastSampleAt))
            let dBytes = max(0, totalBytesWritten - job.lastSampleBytes)
            let rate = Double(dBytes) / dt
            var eta: Double? = nil
            if totalBytesExpectedToWrite > 0 && rate > 1 {
                eta = Double(totalBytesExpectedToWrite - totalBytesWritten) / rate
            }
            job.progress = .init(
                bytesReceived: totalBytesWritten,
                bytesTotal: totalBytesExpectedToWrite,
                bytesPerSecond: rate,
                etaSeconds: eta
            )
            // Only resample every ~0.5s to avoid noise.
            if dt > 0.5 {
                job.lastSampleAt = now
                job.lastSampleBytes = totalBytesWritten
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        let ns = error as NSError
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard let job = self.job(for: taskID) else { return }
            if ns.code == NSURLErrorCancelled {
                if let resume { job.resumeData = resume }
                // state already set by caller (paused/cancelled)
                return
            }
            if let resume { job.resumeData = resume }
            job.state = .failed(error.localizedDescription)
            job.task = nil
            self.tasksToJobs.removeValue(forKey: taskID)
        }
    }
}
