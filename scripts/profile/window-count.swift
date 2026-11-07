// Prints how many on-screen, normal-layer windows process <pid> owns. Used by profile.sh to confirm "UI closed".
// Needs no permission: it reads owner PIDs and layers only, never window titles or contents.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-count <pid>\n".utf8))
    exit(2)
}
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
print(windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.count)
