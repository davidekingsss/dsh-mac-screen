// macs — macOS 底层屏幕读取与精准截图
//
// 设计约束(全部来自本机实测,勿凭直觉改):
//   1. 坐标一律从像素域计算,绝不由模型看图估计。CSS 不参与本文件。
//   2. CGWindowList 的 bounds 是「逻辑点」;screencapture -R 收的也是「逻辑点」;
//      截出的 PNG 是物理像素 = 逻辑点 × backingScale。三处同源,不要混用。
//   3. AX 元素的 position/size 是「屏幕逻辑点」,窗口被遮挡时不能直接喂 -R;
//      必须换算成窗口内相对坐标,再在 screencapture -l 的窗口图上裁剪。
//   4. Chromium/Electron 应用的 AX 内容层为空(只有窗口骨架),
//      这类目标必须走 OCR 降级路径。
//   5. 窗口 bounds 会过期,裁剪前应重新枚举,不要复用旧值。

import Foundation
import AppKit
import ApplicationServices
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 基础

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}
func note(_ msg: String) { print(msg) }

// MARK: - AX 取值

func axAttr(_ el: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil
}
func axStr(_ el: AXUIElement, _ n: String) -> String? { axAttr(el, n) as? String }

/// AX 元素的屏幕矩形(逻辑点)
func axRect(_ el: AXUIElement) -> CGRect? {
    guard let pv = axAttr(el, kAXPositionAttribute as String),
          let sv = axAttr(el, kAXSizeAttribute as String) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &p),
          AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}
func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let a = names as? [String] else { return [] }
    return a
}

// MARK: - 窗口枚举(CGWindowList,只需屏幕录制权限)

struct Win {
    let id: Int, pid: Int, layer: Int
    let owner: String, title: String
    let rect: CGRect
}

func allWindows() -> [Win] {
    let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.map { w in
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let r = CGRect(x: (b["X"] as? NSNumber)?.doubleValue ?? 0,
                       y: (b["Y"] as? NSNumber)?.doubleValue ?? 0,
                       width: (b["Width"] as? NSNumber)?.doubleValue ?? 0,
                       height: (b["Height"] as? NSNumber)?.doubleValue ?? 0)
        return Win(id: w[kCGWindowNumber as String] as? Int ?? 0,
                   pid: w[kCGWindowOwnerPID as String] as? Int ?? 0,
                   layer: w[kCGWindowLayer as String] as? Int ?? 0,
                   owner: w[kCGWindowOwnerName as String] as? String ?? "?",
                   title: w[kCGWindowName as String] as? String ?? "",
                   rect: r)
    }
}

func resolveApp(_ name: String) -> (pid_t, String) {
    if let p = pid_t(name), NSRunningApplication(processIdentifier: p) != nil {
        return (p, "pid:\(p)")
    }
    for app in NSWorkspace.shared.runningApplications {
        if let n = app.localizedName, n.lowercased().contains(name.lowercased()) {
            return (app.processIdentifier, n)
        }
    }
    die("app not found: \(name)")
}

/// 该 pid 最可能的「那个窗口」:layer 0 且面积最大
func mainWindow(of pid: pid_t) -> Win? {
    let cands = allWindows().filter { $0.pid == Int(pid) && $0.layer == 0 }
    return cands.max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
}

// MARK: - 截图(调系统 screencapture;坐标一律逻辑点)

@discardableResult
func run(_ launch: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { die("spawn \(launch) failed: \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

let shotDir = "/tmp/macs-shots"

/// 默认区保留多少张。`MACS_KEEP=0` 关掉清理。
/// 过程性截图(为看一眼而截、喂完 read_image 就没用)占绝大多数,靠这个上限
/// 做到无人值守也不膨胀;证据性截图走 --out 到别处,不受这里影响。
let shotKeep: Int = {
    if let raw = ProcessInfo.processInfo.environment["MACS_KEEP"], let n = Int(raw) { return n }
    return 40
}()

/// 本工具生成的文件名形状。清理只认这些形状,绝不碰别的文件。
func isOwnShot(_ name: String) -> Bool {
    guard name.hasSuffix(".png") else { return false }
    return ["focus-", "shot-", "screen-", "region-", "crop-", "win"].contains { name.hasPrefix($0) }
}

/// 把默认区压到 shotKeep 以内,按修改时间留最新的。
/// 不递归、只处理默认区的直接子项、只删自己生成的文件。
func pruneDefaultDir() {
    guard shotKeep > 0 else { return }
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: shotDir) else { return }
    let mine = names.filter(isOwnShot)
    guard mine.count > shotKeep else { return }
    let dated: [(String, Date)] = mine.compactMap { n in
        let p = shotDir + "/" + n
        guard let a = try? fm.attributesOfItem(atPath: p),
              let d = a[.modificationDate] as? Date else { return nil }
        return (p, d)
    }.sorted { $0.1 > $1.1 }          // 新的在前
    for (p, _) in dated.dropFirst(shotKeep) { try? fm.removeItem(atPath: p) }
}

func ensureShotDir() {
    try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
}

func defaultOut(_ tag: String) -> String {
    ensureShotDir()
    pruneDefaultDir()                  // 写新图之前先回收:磁盘峰值不超过上限 +1
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    return "\(shotDir)/\(tag)-\(ts).png"
}

func humanSize(_ b: Int64) -> String {
    let mb = Double(b) / 1_048_576
    return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.1f MB", mb)
}

func dirStats(_ path: String) -> (count: Int, bytes: Int64, oldest: Date?, newest: Date?) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: path) else { return (0, 0, nil, nil) }
    var count = 0; var bytes: Int64 = 0; var oldest: Date?; var newest: Date?
    for n in names where n.hasSuffix(".png") {
        let p = path + "/" + n
        guard let a = try? fm.attributesOfItem(atPath: p) else { continue }
        count += 1
        bytes += (a[.size] as? NSNumber)?.int64Value ?? 0
        if let d = a[.modificationDate] as? Date {
            if oldest == nil || d < oldest! { oldest = d }
            if newest == nil || d > newest! { newest = d }
        }
    }
    return (count, bytes, oldest, newest)
}

func cmdShots(_ args: [String]) {
    let df = DateFormatter()
    df.dateFormat = "MM-dd HH:mm"
    func report(_ label: String, _ path: String) {
        let s = dirStats(path)
        guard s.count > 0 else { note("[\(label)] \(path) — 空或不存在"); return }
        note("[\(label)] \(path)")
        var line = "           \(s.count) 个 / \(humanSize(s.bytes))"
        if let o = s.oldest, let n = s.newest {
            line += "   最老 \(df.string(from: o))  最新 \(df.string(from: n))"
        }
        note(line)
    }
    report("默认区", shotDir)
    for d in args where !d.hasPrefix("--") { report("持久区", d) }
    note("\n默认区上限 \(shotKeep) 张(MACS_KEEP 控制,0 = 关掉清理),只收自己生成的文件名;持久区不自动清理。")
}

// MARK: - 视觉网格:把「第几行第几列」交给工具算

struct GridItem {
    let x: Double, y: Double, w: Double, h: Double
    let label: String
}

func collectGridItems(_ el: AXUIElement, _ depth: Int, _ maxDepth: Int, _ budget: inout Int, _ into: inout [GridItem]) {
    if depth > maxDepth || budget <= 0 { return }
    budget -= 1
    let t = axStr(el, kAXTitleAttribute as String) ?? ""
    let d = axStr(el, kAXDescriptionAttribute as String) ?? ""
    var v = ""
    if let raw = axAttr(el, kAXValueAttribute as String) { v = "\(raw)" }
    let label = !t.isEmpty ? t : (!d.isEmpty ? d : v)
    if !label.isEmpty, let r = axRect(el), r.width >= 20, r.height >= 12 {
        into.append(GridItem(x: r.origin.x, y: r.origin.y, w: r.width, h: r.height, label: label))
    }
    if let kids = axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement] {
        for k in kids { collectGridItems(k, depth + 1, maxDepth, &budget, &into) }
    }
}

/// 输出「第 M 行第 N 列是什么」。
///
/// 存在的理由:AX 树是深度优先的扁平列表,同一张卡片往往被拆成多个元素
/// ——实测 Plex 每张海报是一条 430x241 的 AXLink,它下面的标题条是另一条 430x24 的,
/// 于是同一列的 x 在一份输出里出现七八次。让模型自己对齐 (x,y) 必然错配。
func cmdGrid(_ args: [String]) {
    guard let appName = args.first else { die("usage: macs grid <app> [depth] [--size WxH]") }
    let depth = (args.count > 1 ? Int(args[1]) : nil) ?? 20
    var wantSize: String? = nil
    if let i = args.firstIndex(of: "--size"), i + 1 < args.count { wantSize = args[i + 1] }

    let (pid, label) = resolveApp(appName)
    let appEl = AXUIElementCreateApplication(pid)
    _ = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    guard let wins = axAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement], !wins.isEmpty else {
        die("no AX windows for \(label)")
    }
    var budget = 6000
    var items: [GridItem] = []
    for w in wins { collectGridItems(w, 0, depth, &budget, &items) }
    guard !items.isEmpty else {
        die("没读到带坐标和文本的元素。Electron/Chromium 应用可能还在惰性构建 AX 树,等几秒重试。")
    }

    // 同一类界面元素尺寸一致,按尺寸签名分组;每组各自聚成行,再挑一个当网格。
    // 挑法:优先二维的(列数≥2 且行数≥2)——侧边栏这类单列列表即使元素更多也不该赢,
    // 因为「第几行第几列」这种问法问的必然是二维网格。二维候选里取格子最多的。
    struct Cand { let key: String; let rows: [[GridItem]]; let cols: Int }
    var bySize: [String: [GridItem]] = [:]
    for it in items { bySize["\(Int(it.w.rounded()))x\(Int(it.h.rounded()))", default: []].append(it) }
    var cands: [Cand] = []
    for (key, group) in bySize {
        var rows: [[GridItem]] = []
        for it in group.sorted(by: { $0.y < $1.y }) {
            if let ref = rows.last?.first, abs(it.y - ref.y) < ref.h * 0.5 {
                rows[rows.count - 1].append(it)
            } else {
                rows.append([it])
            }
        }
        cands.append(Cand(key: key, rows: rows, cols: rows.map { $0.count }.max() ?? 0))
    }
    func cells(_ c: Cand) -> Int { c.rows.reduce(0) { $0 + $1.count } }

    if let ws = wantSize, !cands.contains(where: { $0.key == ws }) {
        die("没有尺寸为 \(ws) 的元素。候选:\n" + cands.sorted { cells($0) > cells($1) }
            .prefix(8).map { "  \($0.key)  \($0.rows.count)行×\($0.cols)列  \(cells($0))个" }.joined(separator: "\n"))
    }
    let chosen: Cand
    if let ws = wantSize {
        chosen = cands.first { $0.key == ws }!
    } else if let best = cands.filter({ $0.cols >= 2 && $0.rows.count >= 2 }).max(by: { cells($0) < cells($1) }) {
        chosen = best
    } else {
        chosen = cands.max { cells($0) < cells($1) }!      // 界面上根本没有二维网格时回退
    }
    let rows = chosen.rows

    note("app=\(label)  网格 \(rows.count) 行 × \(chosen.cols) 列  (尺寸 \(chosen.key),\(cells(chosen)) 个格子)")
    let others = cands.filter { $0.key != chosen.key }.sorted { cells($0) > cells($1) }.prefix(4)
    if !others.isEmpty {
        note("其他尺寸候选: " + others.map { "\($0.key)(\($0.rows.count)行×\($0.cols)列,\(cells($0))个)" }
            .joined(separator: "  ") + " —— 选错了用 --size 指定")
    }
    note("")
    for (ri, row) in rows.enumerated() {
        let cells = row.sorted { $0.x < $1.x }.enumerated().map { ci, c in
            "[\(ci + 1)] " + c.label.replacingOccurrences(of: "\n", with: " ").prefix(46)
        }.joined(separator: "  |  ")
        note("行\(ri + 1)  " + cells)
    }
    note("\n行列号由坐标聚类得出(行距容差 = 元素高度的一半,行内按 x 排序),不需要你数坐标。")

    // 矩阵是工具算出来的结论,截图是独立信源。两者一起给,结论才可被交叉验证。
    if args.contains("--shot") {
        if let win = mainWindow(of: pid) {
            let p = defaultOut("grid")
            captureWindow(win.id, p)
            note("窗口截图: \(p)")
        } else {
            note("窗口截图: 跳过(找不到 \(label) 的 layer-0 窗口)")
        }
    }
}

func captureScreen(_ out: String) {
    let (code, log) = run("/usr/sbin/screencapture", ["-x", out])
    if code != 0 { die("screencapture failed (\(code)): \(log)\n提示:屏幕录制权限是否已授予?") }
}
func captureRegion(_ r: CGRect, _ out: String) {
    let (code, log) = run("/usr/sbin/screencapture",
        ["-x", "-R", "\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))", out])
    if code != 0 { die("screencapture -R failed (\(code)): \(log)") }
}
func captureWindow(_ id: Int, _ out: String) {
    // -o 去掉窗口阴影,-x 静音
    let (code, log) = run("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(id)", out])
    if code != 0 { die("screencapture -l \(id) failed (\(code)): \(log)\n提示:窗口 id 是否过期?重新跑 macs list") }
}

// MARK: - 图像

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("cannot read image: \(path)") }
    return img
}

func savePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dst = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        die("cannot create \(path)")
    }
    CGImageDestinationAddImage(dst, img, nil)
    if !CGImageDestinationFinalize(dst) { die("cannot write \(path)") }
}

/// 裁剪 + 整数倍最近邻放大(放大为了让模型看清小字;用 nearest 保留像素边界,不做平滑)
/// 返回 (最终尺寸, 实际使用的 zoom)。
/// zoom 会被自动收敛:模型侧预览上限实测 1708x961,超出的部分会被降采样,
/// 放大再多也到不了模型眼里,所以按 1600x900 反推可用倍率。
func cropAndZoom(_ img: CGImage, _ r: CGRect, zoom requestedZoom: Int, out: String) -> (CGSize, Int) {
    let bounds = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    let clipped = r.intersection(bounds).integral
    if clipped.width < 1 || clipped.height < 1 {
        die("crop rect \(r) is outside image \(Int(bounds.width))x\(Int(bounds.height))")
    }
    guard let cropped = img.cropping(to: clipped) else { die("crop failed") }
    let maxW = 1600, maxH = 900
    let capW = max(1, maxW / max(1, cropped.width))
    let capH = max(1, maxH / max(1, cropped.height))
    let zoom = max(1, min(requestedZoom, min(capW, capH)))
    var final = cropped
    if zoom > 1 {
        let w = cropped.width * zoom, h = cropped.height * zoom
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .none
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let scaled = ctx.makeImage() { final = scaled }
        }
    }
    savePNG(final, out)
    return (CGSize(width: final.width, height: final.height), zoom)
}

// MARK: - OCR(Vision,端上,给像素坐标)

struct OcrLine {
    let text: String
    let rect: CGRect     // 图内物理像素,原点左上
    let conf: Float
}

func ocr(_ img: CGImage) -> [OcrLine] {
    let W = Double(img.width), H = Double(img.height)
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    do { try handler.perform([req]) } catch { die("ocr failed: \(error)") }
    return (req.results ?? []).compactMap { obs in
        guard let c = obs.topCandidates(1).first else { return nil }
        let bb = obs.boundingBox
        let r = CGRect(x: Double(bb.origin.x) * W,
                       y: (1.0 - Double(bb.origin.y) - Double(bb.size.height)) * H,
                       width: Double(bb.size.width) * W,
                       height: Double(bb.size.height) * H)
        return OcrLine(text: c.string, rect: r, conf: c.confidence)
    }
}

// MARK: - AX 树

func walk(_ el: AXUIElement, depth: Int, maxDepth: Int, lines: inout [String], budget: inout Int, terse: Bool) {
    if depth > maxDepth || budget <= 0 { return }
    budget -= 1
    let role = axStr(el, kAXRoleAttribute as String) ?? "?"
    let sub = axStr(el, kAXSubroleAttribute as String) ?? ""
    var line = String(repeating: "  ", count: depth) + role + (sub.isEmpty ? "" : "/\(sub)")
    if let r = axRect(el) {
        line += String(format: " @%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.width, r.height)
    }
    let acts = axActions(el)
    if !acts.isEmpty { line += " {" + acts.joined(separator: ",") + "}" }
    var hasText = false
    if let t = axStr(el, kAXTitleAttribute as String), !t.isEmpty { line += " title=\"\(t.prefix(60))\""; hasText = true }
    if let d = axStr(el, kAXDescriptionAttribute as String), !d.isEmpty { line += " desc=\"\(d.prefix(50))\""; hasText = true }
    if let v = axAttr(el, kAXValueAttribute as String) {
        let s = "\(v)".replacingOccurrences(of: "\n", with: "⏎")
        if !s.isEmpty { line += " value=\"\(s.prefix(60))\""; hasText = true }
    }
    // terse:丢掉纯容器节点,只留有内容的行。层级仍靠缩进保留。
    if !terse || hasText { lines.append(line) }
    if let kids = axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement] {
        for k in kids { walk(k, depth: depth + 1, maxDepth: maxDepth, lines: &lines, budget: &budget, terse: terse) }
    }
}

/// 深度优先找第一个 title/description/value 含 needle 且带有效矩形的元素。
/// role 非空时只接受该 AX role —— 界面里同一段文字常同时出现在按钮和输入框上,
/// 不限定 role 就会把 setvalue 打到按钮上(-25205)。
func search(_ el: AXUIElement, needle: String, roles: [String], depth: Int, maxDepth: Int, budget: inout Int) -> (AXUIElement, String)? {
    if depth > maxDepth || budget <= 0 { return nil }
    budget -= 1
    let t = axStr(el, kAXTitleAttribute as String) ?? ""
    let d = axStr(el, kAXDescriptionAttribute as String) ?? ""
    var v = ""
    if let raw = axAttr(el, kAXValueAttribute as String) { v = "\(raw)" }
    let actualRole = axStr(el, kAXRoleAttribute as String) ?? ""
    let roleOK = roles.isEmpty || roles.contains { $0.localizedCaseInsensitiveCompare(actualRole) == .orderedSame }
    let hit = roleOK && [t, d, v].contains { $0.localizedCaseInsensitiveContains(needle) }
    if hit, let r = axRect(el), r.width >= 1, r.height >= 1 {
        let label = !t.isEmpty ? t : (!d.isEmpty ? d : v)
        return (el, label)
    }
    if let kids = axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement] {
        for k in kids {
            if let found = search(k, needle: needle, roles: roles, depth: depth + 1, maxDepth: maxDepth, budget: &budget) {
                return found
            }
        }
    }
    return nil
}

// MARK: - 命令

func cmdList(_ args: [String]) {
    let ws = allWindows()
    let filter = args.first
    note("count=\(ws.count)  (id pid layer bounds[逻辑点] owner title)")
    for w in ws {
        if let f = filter, !(w.owner + " " + w.title).localizedCaseInsensitiveContains(f) { continue }
        note(String(format: "id=%d pid=%d layer=%d bounds=[%.0f,%.0f %.0fx%.0f] owner=%@ title=%@",
                    w.id, w.pid, w.layer, w.rect.origin.x, w.rect.origin.y,
                    w.rect.width, w.rect.height, w.owner, w.title))
    }
}

func cmdAx(_ args: [String]) {
    guard let appName = args.first else { die("usage: macs ax <app> [depth] [budget] [--terse]") }
    // 默认 16:Electron/Chromium 的内容在 AXWebArea 之下,实测会话列表要到第 14 层
    let depth = args.count > 1 ? (Int(args[1]) ?? 16) : 16
    var budget = args.count > 2 ? (Int(args[2]) ?? 1500) : 1500
    let terse = args.contains("--terse")
    let (pid, label) = resolveApp(appName)
    let appEl = AXUIElementCreateApplication(pid)
    // Chromium/Electron 必须先开这个属性才会构建内容层;失败无妨(-25208 表示该版本不支持)
    _ = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    guard let wins = axAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement], !wins.isEmpty else {
        die("no AX windows for \(label) (pid \(pid))")
    }
    note("app=\(label) pid=\(pid) windows=\(wins.count)")
    var sawWebArea = false
    var sawText = false
    for (i, w) in wins.enumerated() {
        let title = axStr(w, kAXTitleAttribute as String) ?? ""
        var geo = ""
        if let r = axRect(w) { geo = String(format: "@%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.width, r.height) }
        note("\n=== window[\(i)] \(title) \(geo) ===")
        var lines: [String] = []
        walk(w, depth: 0, maxDepth: depth, lines: &lines, budget: &budget, terse: terse)
        note(lines.joined(separator: "\n"))
        if lines.contains(where: { $0.contains("AXWebArea") }) { sawWebArea = true }
        if lines.contains(where: { $0.contains("value=\"") || $0.contains("title=\"") || $0.contains("desc=\"") }) { sawText = true }
        note("(nodes: \(lines.count), budget left: \(budget))")
    }
    if sawWebArea && !sawText {
        note("\n提示:出现了 AXWebArea 却没读到任何 value/title,Chromium 可能在惰性构建内容层。等几秒重跑本条命令。")
    }
}

func cmdOcr(_ args: [String]) {
    guard let path = args.first else { die("usage: macs ocr <png>") }
    let img = loadImage(path)
    let lines = ocr(img)
    note("image=\(img.width)x\(img.height) lines=\(lines.count)  (rect 为图内物理像素,原点左上)")
    for l in lines {
        note(String(format: "px[%.0f,%.0f %.0fx%.0f] conf=%.2f\t%@",
                    l.rect.origin.x, l.rect.origin.y, l.rect.width, l.rect.height, l.conf, l.text))
    }
}

func cmdShot(_ args: [String]) {
    guard let mode = args.first else { die("usage: macs shot screen|region x,y,w,h|window <id> [--out p]") }
    var out = ""
    if let i = args.firstIndex(of: "--out"), i + 1 < args.count { out = args[i + 1] }
    switch mode {
    case "screen":
        let p = out.isEmpty ? defaultOut("screen") : out
        captureScreen(p)
        let img = loadImage(p); note("\(p) \(img.width)x\(img.height)")
    case "region":
        guard args.count > 1 else { die("need x,y,w,h") }
        let nums = args[1].split(separator: ",").compactMap { Double($0) }
        guard nums.count == 4 else { die("region wants x,y,w,h") }
        let p = out.isEmpty ? defaultOut("region") : out
        captureRegion(CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]), p)
        let img = loadImage(p); note("\(p) \(img.width)x\(img.height)")
    case "window":
        guard args.count > 1, let id = Int(args[1]) else { die("window wants <id>") }
        let p = out.isEmpty ? defaultOut("win\(args[1])") : out
        captureWindow(id, p)
        let img = loadImage(p); note("\(p) \(img.width)x\(img.height)")
    default:
        die("unknown shot mode: \(mode)")
    }
}

func cmdCrop(_ args: [String]) {
    guard args.count >= 2 else { die("usage: macs crop <png> x,y,w,h [--zoom N] [--out p]") }
    let img = loadImage(args[0])
    let nums = args[1].split(separator: ",").compactMap { Double($0) }
    guard nums.count == 4 else { die("crop wants x,y,w,h (图内物理像素)") }
    var zoom = 1, out = ""
    if let i = args.firstIndex(of: "--zoom"), i + 1 < args.count { zoom = Int(args[i + 1]) ?? 1 }
    if let i = args.firstIndex(of: "--out"), i + 1 < args.count { out = args[i + 1] }
    if out.isEmpty { out = defaultOut("crop") }
    let (size, usedZoom) = cropAndZoom(img, CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]), zoom: zoom, out: out)
    note("\(out) \(Int(size.width))x\(Int(size.height)) zoom=\(usedZoom)")
}

/// 一条龙:底层定位 → 精准截图。AX 优先,Chromium/Electron 自动降级 OCR。
func cmdFocus(_ args: [String]) {
    guard args.count >= 2 else { die("usage: macs focus <app> <text> [--zoom N] [--pad N] [--out p]") }
    let appName = args[0], needle = args[1]
    var zoom = 3, pad = 12.0, out = ""
    if let i = args.firstIndex(of: "--zoom"), i + 1 < args.count { zoom = Int(args[i + 1]) ?? 3 }
    if let i = args.firstIndex(of: "--pad"), i + 1 < args.count { pad = Double(args[i + 1]) ?? 12 }
    if let i = args.firstIndex(of: "--out"), i + 1 < args.count { out = args[i + 1] }

    let (pid, label) = resolveApp(appName)
    guard let win = mainWindow(of: pid) else { die("no layer-0 window for \(label) (pid \(pid))") }
    let tmp = defaultOut("focus")
    captureWindow(win.id, tmp)
    let img = loadImage(tmp)
    let scale = Double(img.width) / win.rect.width

    // 路径 A:AX(精确、结构化)
    let appEl = AXUIElementCreateApplication(pid)
    _ = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var budget = 3000
    if let wins = axAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement] {
        for w in wins {
            if let found = search(w, needle: needle, roles: [], depth: 0, maxDepth: 40, budget: &budget) {
                let (el, text) = found
                guard let sr = axRect(el) else { continue }
                let rel = CGRect(x: (sr.origin.x - win.rect.origin.x) * scale,
                                 y: (sr.origin.y - win.rect.origin.y) * scale,
                                 width: sr.width * scale, height: sr.height * scale)
                let padded = rel.insetBy(dx: -pad * scale, dy: -pad * scale)
                let final = out.isEmpty ? defaultOut("focus") : out
                let (size, usedZoom) = cropAndZoom(img, padded, zoom: zoom, out: final)
                note("source=AX")
                note("element=\(text)")
                note("ax_screen_rect=\(Int(sr.origin.x)),\(Int(sr.origin.y)) \(Int(sr.width))x\(Int(sr.height))   (屏幕逻辑点)")
                note("image=\(final) \(Int(size.width))x\(Int(size.height)) zoom=\(usedZoom)  (窗口图 \(img.width)x\(img.height), scale=\(scale))")
                return
            }
        }
    }

    // 路径 B:OCR 降级(图内物理像素,直接就是裁剪坐标)
    let lines = ocr(img)
    let hits = lines.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    guard let best = hits.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) else {
        die("not found by AX or OCR: \"\(needle)\" in \(label)。窗口图留在 \(tmp) 供人工查看。")
    }
    let padded = best.rect.insetBy(dx: -pad * scale, dy: -pad * scale)
    let final = out.isEmpty ? defaultOut("focus") : out
    let (size, usedZoom) = cropAndZoom(img, padded, zoom: zoom, out: final)
    note("source=OCR (AX 没有该元素)")
    note("matched=\"\(best.text)\" conf=\(String(format: "%.2f", best.conf))")
    note("px_rect=\(Int(best.rect.origin.x)),\(Int(best.rect.origin.y)) \(Int(best.rect.width))x\(Int(best.rect.height))   (图内物理像素)")
    note("image=\(final) \(Int(size.width))x\(Int(size.height)) zoom=\(usedZoom)")
}

/// 语义操作:按元素、写值、聚焦。走 AX,不移动系统光标、不抢焦点。
/// 危险词默认拒绝;--dry-run 只解析不执行;执行后读回状态。
func cmdAct(_ args: [String]) {
    guard args.count >= 3 else {
        die("usage: macs act <app> \"<text>\" press|setvalue|focus [value] [--dry-run] [--force]")
    }
    let appName = args[0], needle = args[1], action = args[2]
    let dryRun = args.contains("--dry-run")
    let force = args.contains("--force")
    var roleFilter: [String] = []
    if let i = args.firstIndex(of: "--role"), i + 1 < args.count {
        roleFilter = args[i + 1].split(separator: ",").map(String.init)
    }
    // setvalue 默认只在输入框里找:同一段文字往往按钮和输入框各有一份,
    // 不限定 role 会把值写到按钮上并拿到 -25205(kAXErrorAttributeUnsupported)
    if action == "setvalue" && roleFilter.isEmpty { roleFilter = ["AXTextField", "AXTextArea"] }
    var value = ""
    if action == "setvalue" {
        guard args.count >= 4, !args[3].hasPrefix("--") else { die("setvalue 需要一个值参数") }
        value = args[3]
    }

    let (pid, label) = resolveApp(appName)
    let appEl = AXUIElementCreateApplication(pid)
    _ = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    guard let wins = axAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement], !wins.isEmpty else {
        die("no AX windows for \(label)")
    }

    // 每次都重新解析元素,不复用旧引用:界面一动,旧引用就可能指向别的东西
    var budget = 4000
    var target: AXUIElement?
    var targetLabel = ""
    for w in wins {
        if let (el, text) = search(w, needle: needle, roles: roleFilter, depth: 0, maxDepth: 40, budget: &budget) {
            target = el; targetLabel = text; break
        }
    }
    guard let el = target else { die("element not found: \"\(needle)\" in \(label)") }
    guard let rect = axRect(el) else { die("element has no geometry") }

    let danger = ["删除", "清空", "移除", "退出", "发送", "提交", "卸载", "格式化", "注销",
                  "重启", "关机", "覆盖", "重置", "抹掉", "delete", "remove", "quit", "send",
                  "submit", "uninstall", "erase", "format", "reset"]
    if !force, danger.contains(where: { targetLabel.localizedCaseInsensitiveContains($0) }) {
        die("拒绝执行:目标 \"\(targetLabel)\" 命中危险词。确认无误后加 --force。")
    }

    note("target=\"\(targetLabel)\"")
    note(String(format: "rect=%.0f,%.0f %.0fx%.0f  (屏幕逻辑点)", rect.origin.x, rect.origin.y, rect.width, rect.height))
    let acts = axActions(el)
    note("actions=\(acts.isEmpty ? "(无)" : acts.joined(separator: ","))")

    if action == "setvalue" {
        var settable = DarwinBoolean(false)
        let r = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        note("kAXValue settable=\(settable.boolValue) (api \(r.rawValue))")
        if !settable.boolValue { die("该元素的 value 不可写,换 focus + 键盘事件路线") }
    }

    if dryRun { note("[dry-run] 已解析完毕,未执行任何操作。"); return }

    var result: AXError = .failure
    switch action {
    case "press":
        guard acts.contains(kAXPressAction as String) else { die("元素不支持 AXPress;可用动作:\(acts)") }
        result = AXUIElementPerformAction(el, kAXPressAction as CFString)
    case "setvalue":
        result = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef)
    case "focus":
        result = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    default:
        die("unknown action: \(action) — 支持 press | setvalue | focus")
    }
    note("perform \(action) → AXError \(result.rawValue)\(result == .success ? " (成功)" : " (失败)")")
    usleep(400_000)
    if let v = axAttr(el, kAXValueAttribute as String), !"\(v)".isEmpty {
        note("readback value=\"\("\(v)".prefix(80))\"")
    }
}

// MARK: - 入口

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else {
    note("""
    macs — macOS 底层屏幕读取与精准截图

      macs list [filter]                 列出窗口(id / pid / layer / bounds / title)
      macs ax <app> [depth] [budget] [--terse]
                                         AX 树(role / 几何 / 动作 / 标题值);
                                         --terse 只输出有文本的节点
      macs ocr <png>                     端上 OCR,输出文字 + 图内像素矩形
      macs shot screen [--out p]         全屏截图
      macs shot region x,y,w,h [--out p] 区域截图(屏幕逻辑点)
      macs shot window <id> [--out p]    单窗口截图
      macs crop <png> x,y,w,h [--zoom N] [--out p]
                                         图上裁剪(图内物理像素)
      macs focus <app> <text> [--zoom N] [--pad N] [--out p]
                                         底层定位 + 精准截图一条龙(AX 优先,OCR 降级)
      macs act <app> <text> press|setvalue|focus [value] [--dry-run] [--force]
                                         语义操作:走 AX,不移动光标、不抢焦点。
                                         危险词默认拒绝;--dry-run 只解析不执行
      macs shots [dir]                   看默认区(和指定持久区)的占用与文件数
      macs grid <app> [depth] [--size WxH] [--shot]
                                         把界面按视觉网格输出成「第几行第几列」;
                                         --shot 同时截一张窗口图

    坐标约定:屏幕逻辑点 = CGWindowList bounds = screencapture -R 参数。
             截图物理像素 = 逻辑点 × backingScale(本机 2)。
    """)
    exit(0)
}
let rest = Array(argv.dropFirst())
switch cmd {
case "list":  cmdList(rest)
case "ax":    cmdAx(rest)
case "ocr":   cmdOcr(rest)
case "shot":  cmdShot(rest)
case "crop":  cmdCrop(rest)
case "focus": cmdFocus(rest)
case "act":   cmdAct(rest)
case "shots": cmdShots(rest)
case "grid":  cmdGrid(rest)
default:      die("unknown command: \(cmd) — 跑 macs 看用法")
}
