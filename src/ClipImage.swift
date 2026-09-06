import Foundation
import AppKit

// ClipImage — write the clipboard's image to stdout as PNG, or exit 1 if the
// clipboard holds no image. `pbpaste` cannot do this: it only ever returns
// text flavours, which is why Pull worked for text and returned nothing for
// pictures.

let pb = NSPasteboard.general
var png: Data? = pb.data(forType: .png)

// A screenshot copied on iOS arrives as PNG, but plenty of Mac apps put only
// TIFF on the pasteboard, so convert rather than give up.
if png == nil, let tiff = pb.data(forType: .tiff),
   let rep = NSBitmapImageRep(data: tiff) {
    png = rep.representation(using: .png, properties: [:])
}

guard let data = png, !data.isEmpty else { exit(1) }
FileHandle.standardOutput.write(data)
