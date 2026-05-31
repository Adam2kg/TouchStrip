import IOKit
import Foundation

// MARK: - Helpers

private func fourCC(_ s: String) -> UInt32 {
    let b = Array(s.utf8)
    guard b.count == 4 else { return 0 }
    return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
}

private let kOpGetKeyInfo: UInt8 = 9
private let kOpReadKey:    UInt8 = 5
private let kOpWriteKey:   UInt8 = 6

// MARK: - SMC Param Struct
//
// Flat layout with explicit padding fields to match the 80-byte C struct the
// AppleSMC IOUserClient expects. Swift doesn't add implicit padding between
// fields, so every gap that C would insert must be spelled out here.
//
// C layout (verified against AppleSMC source and SMCKit):
//  0  key          uint32   4
//  4  vers         6 bytes (uint8×4 + uint16)
// 10  _p0          2 bytes  → aligns pLimitData to offset 12
// 12  pLimitData   16 bytes (uint16+uint16+uint32×3)
// 28  ki_size      uint32   4
// 32  ki_type      uint32   4
// 36  ki_attr      uint8    1
// 37  _p1–_p3      3 bytes  → aligns result to offset 40
// 40  result       uint8
// 41  status       uint8
// 42  data8        uint8
// 43  _p4          1 byte   → aligns data32 to offset 44
// 44  data32       uint32   4
// 48  bytes        32 bytes
// Total: 80 bytes

private struct SMCParam {
    var key: UInt32 = 0
    // SMCVersion (6 bytes)
    var v_major: UInt8 = 0;  var v_minor: UInt8 = 0
    var v_build: UInt8 = 0;  var v_reserved: UInt8 = 0; var v_release: UInt16 = 0
    var _p0: UInt16 = 0                                  // padding → offset 12
    // SMCPLimitData (16 bytes)
    var pl_version: UInt16 = 0; var pl_length: UInt16 = 0
    var pl_cpu: UInt32 = 0;     var pl_gpu: UInt32 = 0;  var pl_mem: UInt32 = 0
    // SMCKeyInfoData (9 bytes)
    var ki_size: UInt32 = 0;    var ki_type: UInt32 = 0; var ki_attr: UInt8 = 0
    var _p1: UInt8 = 0; var _p2: UInt8 = 0; var _p3: UInt8 = 0  // pad → offset 40
    var result: UInt8 = 0;  var status: UInt8 = 0;  var data8: UInt8 = 0
    var _p4: UInt8 = 0                                   // padding → offset 44
    var data32: UInt32 = 0
    var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (
                0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// MARK: - SMCController

final class SMCController {
    private var conn: io_connect_t = 0

    func open() -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                             IOServiceMatching("AppleSMC"))
        guard svc != 0 else {
            tsDebugLog("smc: AppleSMC service not found\n"); return false
        }
        let kr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        IOObjectRelease(svc)
        if kr != kIOReturnSuccess {
            tsDebugLog("smc: IOServiceOpen failed \(kr)\n"); return false
        }
        tsDebugLog("smc: opened (struct size=\(MemoryLayout<SMCParam>.size))\n")
        return true
    }

    func close() {
        guard conn != 0 else { return }
        IOServiceClose(conn)
        conn = 0
    }

    // MARK: Read helpers

    func readUInt8(_ key: String) -> UInt8? {
        guard let r = read(key) else { return nil }
        return r.bytes.0
    }

    /// FPE2: 16-bit big-endian fixed-point with 2 fractional bits → divide by 4 for RPM.
    func readFPE2(_ key: String) -> Double? {
        guard let r = read(key) else { return nil }
        let raw = (UInt16(r.bytes.0) << 8) | UInt16(r.bytes.1)
        return Double(raw) / 4.0
    }

    // MARK: Write helpers

    @discardableResult
    func writeUInt16(_ key: String, _ value: UInt16) -> Bool {
        guard let info = keyInfo(key) else { return false }
        var p = SMCParam()
        p.key     = fourCC(key)
        p.ki_size = info.ki_size
        p.ki_type = info.ki_type
        p.ki_attr = info.ki_attr
        p.bytes.0 = UInt8((value >> 8) & 0xFF)
        p.bytes.1 = UInt8(value & 0xFF)
        p.data8   = kOpWriteKey
        guard let r = call(&p) else { return false }
        if r.result != 0 { tsDebugLog("smc: write \(key) result=\(r.result)\n") }
        return r.result == 0
    }

    @discardableResult
    func writeFPE2(_ key: String, rpm: Double) -> Bool {
        writeUInt16(key, UInt16(rpm * 4.0))
    }

    // MARK: Private

    private func keyInfo(_ key: String) -> SMCParam? {
        var p = SMCParam()
        p.key   = fourCC(key)
        p.data8 = kOpGetKeyInfo
        return call(&p)
    }

    private func read(_ key: String) -> SMCParam? {
        guard let info = keyInfo(key) else { return nil }
        var p = SMCParam()
        p.key     = fourCC(key)
        p.ki_size = info.ki_size
        p.data8   = kOpReadKey
        return call(&p)
    }

    private func call(_ p: inout SMCParam) -> SMCParam? {
        var out = SMCParam()
        var outSize = MemoryLayout<SMCParam>.size
        let kr = IOConnectCallStructMethod(conn, 2, &p,
                                          MemoryLayout<SMCParam>.size,
                                          &out, &outSize)
        if kr != kIOReturnSuccess {
            tsDebugLog("smc: IOConnectCallStructMethod failed \(kr)\n")
            return nil
        }
        return out
    }
}
