import Darwin
import Foundation

final class InstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    static func acquire() -> InstanceLock? {
        let lockName = "typemore.lock"
        let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(lockName)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }

        return InstanceLock(fileDescriptor: fd)
    }
}
