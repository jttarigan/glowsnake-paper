import CoreGraphics
import ImageIO
import Foundation

let args = CommandLine.arguments
let pdfURL = URL(fileURLWithPath: args[1]) as CFURL
let outURL = URL(fileURLWithPath: args[2]) as CFURL
let targetW = CGFloat(Double(args[3])!)
let pageNum = args.count > 4 ? Int(args[4])! : 1
guard let doc = CGPDFDocument(pdfURL), let page = doc.page(at: pageNum) else {
    fatalError("cannot open pdf page")
}
let box = page.getBoxRect(.mediaBox)
let scale = targetW / box.width
let w = Int(box.width * scale), h = Int(box.height * scale)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.scaleBy(x: scale, y: scale)
ctx.drawPDFPage(page)
let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(outURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("rendered \(w)x\(h)")
