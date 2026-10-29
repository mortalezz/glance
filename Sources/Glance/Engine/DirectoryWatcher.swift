import Foundation
import CoreServices

public protocol DirectoryWatcherDelegate: AnyObject, Sendable {
    @MainActor func directoryWatcherDidDetectChanges(in directoryURL: URL)
}

/// Native macOS folder monitor using CoreServices FSEvents.
/// Incorporates kernel-level self-trigger suppression (`kFSEventStreamCreateFlagIgnoreSelf`)
/// and path filtering to ensure Glance never thrashes or re-scans its own .xmp sidecar writes
/// or in-place EXIF orientation updates.
public final class DirectoryWatcher: @unchecked Sendable {
    public weak var delegate: DirectoryWatcherDelegate?

    private let directoryURL: URL
    private var streamRef: FSEventStreamRef? = nil
    private let queue = DispatchQueue(label: "com.glance.directorywatcher", qos: .utility)
    private var debounceTimer: DispatchSourceTimer? = nil

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// Starts monitoring the directory for external filesystem modifications.
    public func start() {
        stop()

        let pathsToWatch = [directoryURL.path] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Flags:
        // - kFSEventStreamCreateFlagUseCFTypes: Receives CFArray of CFStrings
        // - kFSEventStreamCreateFlagFileEvents: Granular file-level notifications
        // - kFSEventStreamCreateFlagIgnoreSelf: CRITICAL: Kernel-level suppression of our own process ID writes
        // - kFSEventStreamCreateFlagNoDefer: Immediate dispatch
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagIgnoreSelf |
            kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientInfo = clientCallBackInfo else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }

            watcher.handleEvents(paths: paths)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15, // Latency in seconds
            flags
        ) else {
            return
        }

        self.streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stops monitoring and invalidates the event stream.
    public func stop() {
        queue.sync {
            debounceTimer?.cancel()
            debounceTimer = nil
        }

        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
    }

    private func handleEvents(paths: [String]) {
        // Path filtering: ignore .xmp sidecars, temp files, and non-image artifacts
        var relevantChangeDetected = false

        for path in paths {
            let lower = path.lowercased()
            let filename = (path as NSString).lastPathComponent

            // 1. Explicitly ignore XMP sidecar mutations to prevent re-sorting mid-cull
            if lower.hasSuffix(".xmp") {
                continue
            }

            // 2. Ignore hidden system and temporary files
            if filename.hasPrefix(".") || filename.contains(".glance_tmp_") || lower.hasSuffix(".tmp") {
                continue
            }

            // 3. Relevant if directory itself changed or a supported image was added/removed
            let ext = (path as NSString).pathExtension.lowercased()
            if SupportedFormats.allExtensions.contains(ext) || path == directoryURL.path {
                relevantChangeDetected = true
                break
            }
        }

        guard relevantChangeDetected else { return }

        // Debounce external batch file additions (e.g. card sync or AirDrop)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.debounceTimer?.cancel()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.35)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.directoryWatcherDidDetectChanges(in: self.directoryURL)
                }
            }
            self.debounceTimer = timer
            timer.resume()
        }
    }

    deinit {
        stop()
    }
}
