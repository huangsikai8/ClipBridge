import Foundation
import AppKit

// ClipSetImage — put an image file on the Mac clipboard.
// `pbcopy` only ever writes text, which is why a pushed image used to land as
// garbage. Writes PNG and TIFF flavours so both modern and older Mac apps can
// paste it.

guard CommandLine.arguments.count > 1,
      let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
      let rep = NSBitmapImageRep(data: data) else { exit(1) }

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }

let pb = NSPasteboard.general
pb.clearContents()
pb.declareTypes([.png, .tiff], owner: nil)
pb.setData(png, forType: .png)
if let tiff = rep.representation(using: .tiff, properties: [:]) {
    pb.setData(tiff, forType: .tiff)
}
print("image \(rep.pixelsWide)x\(rep.pixelsHigh)")
