import Foundation

/// Neutralizes the wall-clock-dependent bytes AVAssetWriter embeds in every `.mov` it
/// writes, so two encodes of identical frames produce byte-identical files (a fixture
/// generator acceptance criterion). Confirmed by diffing two real runs of this generator:
/// every byte matched except eight in the `moov` atom's `mvhd`/`tkhd`/`mdhd` creation and
/// modification timestamps, plus a couple of bytes inside the first frame's H.264 SEI NAL
/// (VideoToolbox stamps encoder/session info there). Both are inert: QuickTime timestamps
/// are administrative metadata nothing decodes against, and H.264 decoders are required by
/// spec to skip SEI payloads they don't use for reconstruction — zeroing either changes
/// nothing about how the file plays.
///
/// This walks real ISO-BMFF box structure and real AVCC NAL boundaries rather than
/// patching fixed byte offsets, so it keeps working if a fixture's frame count or content
/// changes the file's layout.
enum MovieDeterminism {
    static func neutralize(fileAt url: URL) throws {
        var data = try Data(contentsOf: url)
        try walkAtoms(in: &data, start: 0, end: data.count)
        try data.write(to: url, options: .atomic)
    }

    private static let timestampAtoms: Set<String> = ["mvhd", "tkhd", "mdhd"]
    private static let containerAtoms: Set<String> = ["moov", "trak", "mdia"]

    private static func walkAtoms(in data: inout Data, start: Int, end: Int) throws {
        var offset = start
        while offset + 8 <= end {
            let size = Int(data.readUInt32BE(at: offset))
            let type = data.readFourCC(at: offset + 4)
            var headerLength = 8
            var atomSize = size
            if size == 1 {
                guard offset + 16 <= end else { throw MovieDeterminismError.malformed }
                atomSize = Int(data.readUInt64BE(at: offset + 8))
                headerLength = 16
            } else if size == 0 {
                atomSize = end - offset
            }
            guard atomSize >= headerLength, offset + atomSize <= end else {
                throw MovieDeterminismError.malformed
            }
            let payloadStart = offset + headerLength
            let payloadEnd = offset + atomSize

            if containerAtoms.contains(type) {
                try walkAtoms(in: &data, start: payloadStart, end: payloadEnd)
            } else if timestampAtoms.contains(type) {
                zeroTimestamps(in: &data, payloadStart: payloadStart, payloadEnd: payloadEnd)
            } else if type == "mdat" {
                zeroSEINALs(in: &data, start: payloadStart, end: payloadEnd)
            }

            offset += atomSize
        }
    }

    /// `mvhd`/`tkhd`/`mdhd` all start with 1 byte version + 3 bytes flags, then
    /// creation_time and modification_time — 32-bit each for version 0, 64-bit for
    /// version 1 (ISO/IEC 14496-12).
    private static func zeroTimestamps(in data: inout Data, payloadStart: Int, payloadEnd: Int) {
        guard payloadStart < payloadEnd else { return }
        let version = data[payloadStart]
        let fieldWidth = version == 0 ? 4 : 8
        let creationTimeStart = payloadStart + 4
        let modificationTimeStart = creationTimeStart + fieldWidth
        guard modificationTimeStart + fieldWidth <= payloadEnd else { return }
        data.zeroRange(creationTimeStart, length: fieldWidth)
        data.zeroRange(modificationTimeStart, length: fieldWidth)
    }

    /// `mdat` for H.264 in a QuickTime/MP4 container is AVCC: a sequence of
    /// [4-byte big-endian length][NAL data], back to back, with no other separators.
    /// NAL type 6 is SEI (ITU-T H.264 §7.4.1) — auxiliary data a conforming decoder must
    /// not use for picture reconstruction, so its payload can be zeroed freely; only the
    /// 1-byte NAL header (which carries the type) is left alone.
    private static func zeroSEINALs(in data: inout Data, start: Int, end: Int) {
        var offset = start
        while offset + 4 <= end {
            let length = Int(data.readUInt32BE(at: offset))
            let nalStart = offset + 4
            guard length > 0, nalStart + length <= end else { break }
            let nalType = data[nalStart] & 0x1F
            if nalType == 6, length > 1 {
                data.zeroRange(nalStart + 1, length: length - 1)
            }
            offset = nalStart + length
        }
    }
}

enum MovieDeterminismError: Error, CustomStringConvertible {
    case malformed
    var description: String { "malformed or unexpected .mov atom structure" }
}

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(self[offset + i])
        }
        return value
    }

    func readFourCC(at offset: Int) -> String {
        String(decoding: self[offset..<offset + 4], as: UTF8.self)
    }

    mutating func zeroRange(_ start: Int, length: Int) {
        for i in start..<(start + length) {
            self[i] = 0
        }
    }
}
