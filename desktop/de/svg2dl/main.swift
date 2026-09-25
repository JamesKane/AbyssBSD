// svg2dl — turn an SVG icon into a draw list, at build time (PHASE11 P11.8).
//
//   svg2dl NAME FILE.svg >> themes/<theme>/icons/<set>.dl
//
// The subset and the reasons are in de/svgimport/SVGImport.swift. It refuses
// what it cannot convert, by name, and exits 1.

import SVGImport

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func die(_ m: String) -> Never {
    ("svg2dl: " + m + "\n").withCString { _ = write(2, $0, strlen($0)) }
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { die("usage: svg2dl NAME FILE.svg") }
guard let f = fopen(args[2], "rb") else { die("cannot read \(args[2])") }
var bytes: [UInt8] = []
var buf = [UInt8](repeating: 0, count: 65536)
while true {
    let n = fread(&buf, 1, buf.count, f)
    if n <= 0 { break }
    bytes += buf[0..<n]
}
fclose(f)
do {
    print(try SVGImport.drawList(named: args[1], svg: String(decoding: bytes, as: UTF8.self)), terminator: "")
} catch {
    die("\(args[2]): \(error)")
}
