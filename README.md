# dsh-mac-screen

给 macOS 上的 AI agent 装一只眼睛:**读无障碍树(结构化文本 + 精确坐标)、枚举窗口、精准截图、端上 OCR**。

一个 Swift 文件编译成一个二进制,零第三方依赖、不联网、不进任何插件的依赖图。

```sh
macs list                                   # 现在有哪些窗口,标题是什么
macs ax "Safari" 16 600 --terse             # 界面上有什么文字、按钮、输入框,各在什么位置
macs focus "系统设置" "网络"                  # 底层定位 + 精准截图,产出一张裁好的图
macs ocr shot.png                           # 图里有什么文字,各在图内什么位置
```

---

## 0. 为什么有这个东西

AI agent 看屏幕这件事,市面上的实现大多败在同一个地方:**让模型看着一张图报坐标**。

这条路走不通,原因是坐标会漂,而且漂得没有规律:

- 图片在送进模型之前会被后端压缩。一张 5120×2880 的截图到模型眼里可能只剩 1708×961。
- 更麻烦的是,工具返回的元数据里写的缩放比和模型实际看到的那张图对不上。实测遇到过:元数据说 `×1.88`(那是中间副本的比例),模型实际看到的是按 `×3.0` 缩的那张。照着元数据换算,坐标错 1.6 倍。
- 这个比例由后端的投影策略决定,图片尺寸、路由配置一变就跟着变,调用方无法预知。

于是模型在图上"看见"的位置,和它换算回原图的位置,差的不是精度,是坐标系。

**这个项目的做法是把模型的角色限制在说一句话:**「我要找『网络』这两个字」。

坐标全部从像素域算:

- 无障碍树(element 的 `AXPosition` / `AXSize`)
- 或者 Vision OCR 的包围盒

两者都是确定性计算,模型对图像的解读不参与其中。后端怎么压图都影响不到它。

实测:同一目标连跑三次,坐标一字不差,产出的 PNG **字节级相同**。

```
ax_screen_rect=1325,271 64x32     md5=215947149502d2aee9ce4a3ab28e8e94
ax_screen_rect=1325,271 64x32     md5=215947149502d2aee9ce4a3ab28e8e94
ax_screen_rect=1325,271 64x32     md5=215947149502d2aee9ce4a3ab28e8e94
```

---

## 1. 安装

需要 macOS 与 Xcode Command Line Tools(`swiftc`)。没有别的依赖。

```sh
git clone https://github.com/davidekingsss/dsh-mac-screen.git
cd dsh-mac-screen
./build.sh --install
```

`--install` 会做两件事:

| 目标 | 作用 |
|---|---|
| `~/.local/bin/macs` | 可执行文件放在固定位置,技能引用它 |
| `~/.dsh/skills/mac-screen/SKILL.md` | 技能描述,让 agent 知道「这个部署能看屏幕」 |

只编译不安装就用 `./build.sh`,产物在 `bin/macs`。

**`bin/` 不进版本库。** macOS 的 TCC 授权按代码签名记录,换台机器必须重新编译才能匹配本地的授权状态,提交一个别处编出来的二进制没有意义。

**要卸载**:删掉那两个文件即可,没有别的东西留在系统里。

## 2. 用法

```
macs list [filter]                       列出窗口(id / pid / layer / bounds / title)
macs ax <app> [depth] [budget] [--terse] AX 树;--terse 只输出有文本的节点
macs ocr <png>                           端上 OCR,输出文字 + 图内像素矩形
macs shot screen|region x,y,w,h|window <id> [--out p]
macs crop <png> x,y,w,h [--zoom N] [--out p]
macs focus <app> <text> [--zoom N] [--pad N] [--out p]
macs act <app> <text> press|setvalue|focus [value] [--role R] [--dry-run] [--force]
macs shots [dir]                         看默认区(和指定持久区)的占用与文件数
macs grid <app> [depth] [--size WxH] [--shot]
                                         把界面按视觉网格输出成「第几行第几列」
```

`focus` 是最常用的那条:给 app 名和一段文字,它先走 AX 找元素,找不到自动降级到 OCR,最后交出一张**已经裁好并放大**的 PNG。

```console
$ macs focus "系统设置" "无障碍" --zoom 4
source=AX
element=无障碍
ax_screen_rect=1325,444 79x32   (屏幕逻辑点)
image=/tmp/macs-shots/focus-1791000451817.png 824x448 zoom=4
```

`ax` 用来读整块界面,`--terse` 丢掉纯容器节点只留内容:

```console
$ macs ax "DeepSeek Harness" 16 600 --terse
AXButton @14,184 252x36 {AXPress,…} desc="插件"
AXRow/AXOutlineRow @12,528 256x32 {AXPress,…} title="代码规范插件市场调研 1天"
AXStaticText @40,536 140x16 {AXShowMenu,…} value="代码规范插件市场调研"
```

`act` 是语义操作,走 AX,不移动系统光标、不抢前台。目标文本命中「删除/清空/退出/发送/提交」一类词时默认拒绝。

```console
$ macs act "系统设置" "网络" press --dry-run
target="网络"
rect=1325,271 64x32  (屏幕逻辑点)
actions=AXPress
[dry-run] 已解析完毕,未执行任何操作。
```

产物默认落在 `/tmp/macs-shots/`。

## 3. 坐标约定(改代码前必读)

三套坐标系,混一个就截到别的地方:

| 坐标系 | 谁产出 | 单位 |
|---|---|---|
| **屏幕逻辑点** | `CGWindowList` 的 bounds、AX 的 position/size、`screencapture -R` 的参数 | pt |
| **截图像素** | `screencapture` 写出的 PNG | px = pt × backingScale |
| **图内像素** | Vision OCR 的包围盒 | px,原点在图的左上 |

两条换算:

- **AX → 窗口图内**:`(axX - winX) × scale`,其中 `scale = png.width / win.bounds.width`
- **OCR → 图内**:直接用,OCR 给的就是图内像素

`shot region` 收的是**屏幕逻辑点**,`crop` 收的是**图内像素**。

**窗口被遮挡怎么办**:AX 给的是屏幕坐标,而 `screencapture -R` 截的是屏幕合成结果——被别的窗口盖住时,`-R` 截到的是遮挡物。`focus` 因此一律走 `screencapture -l <windowid>` 截窗口自身,再在图内按相对坐标裁剪。

这么做的底气和 OBS 的窗口采集是同一条:macOS 的 `screencapture` 链接了 `ScreenCaptureKit`,窗口有自己的图层缓冲,WindowServer 能单独渲染它,不参与合成,遮挡与它无关。

## 4. 能力边界

| 目标类型 | AX 读取 | 说明 |
|---|---|---|
| 原生 macOS app | 完整 | 控件 role / 精确几何 / 可用动作 / 标题值 |
| Electron · Chromium | 完整 | 有三个前提,见下 |
| 纯图形(canvas、视频画面、游戏) | 无 | 走截图 + OCR |

**Electron / Chromium 的三个前提**,少一个就会误判成「读不到」:

1. 先对 app 元素设 `AXManualAccessibility = true`(`AXEnhancedUserInterface` 在新系统上返回 `-25208`,不支持)
2. 内容层是**惰性构建**的,设完立刻读可能是空树,等几秒重读
3. **depth 要够**。实测 DSH 自己的会话列表在第 14 层,用 depth 5~7 看到的是空 `AXGroup`

第 3 条是这个项目里踩得最深的坑:我前后两次据此错误地断言「Electron 不暴露 AX」,直到把 depth 提到 16 才看到完整内容。

`macs ax` 默认 depth 16,并且在检测到「有 `AXWebArea` 但没有任何文本」时会提示重试。

**模型侧的预览上限**:图片送进模型前会被压到长边 ≤1708、总像素约 1.64M。裁剪时 zoom 会自动收敛到最终尺寸 ≤1600×900——放得再大也到不了模型眼里。请求 `--zoom 6` 而元素宽 750 pt 时,实际会用 `zoom=1`,输出里会写明用了多少。

## 5. 踩过的坑

1. **窗口 bounds 会过期。** 拿几秒前枚举的坐标去裁,可能截到完全不同的内容。用之前重新 `list`。
2. **解析窗口 id 别被 `pid=` 骗。** `sed 's/.*id=\([0-9]*\).*/\1/'` 会贪婪匹配到 `pid=` 里的 `id=`,拿 pid 去喂 `-l` 会得到 `could not create image from window`。用行首锚定。
3. **放大过的图不要再跑 OCR。** 放大会用最近邻插值,文字边缘变成方块,Vision 的识别率会掉。实测同一块内容,在原始截图里能读出,在 4× 放大的裁剪图里是 0 行。验证裁剪对不对,用眼睛看(把图交给模型的图片读取工具),不要用 OCR 反查。
4. **同一段文字常常出现多次。** `search` 取深度优先的第一个,未必是你要的。`focus` 会回显实际匹配到的完整文本(`element=` 那行),看到不对就换一个更独特的字符串。
5. **同名元素会打错目标。** 界面上「搜索」两个字可能同时属于一个按钮和一个输入框。不限定 role 就会把值写到按钮上,拿到 `-25205`(`kAXErrorAttributeUnsupported`)。
6. **输入框的 role 不统一。** DSH 的输入框是 `AXTextArea`,系统设置的是 `AXTextField`。`setvalue` 因此默认在 `AXTextField` 和 `AXTextArea` 里一起找。
7. **元素引用会失效。** 界面一动,之前拿到的 `AXUIElement` 可能指向别的对象。每次操作前重新解析。
8. **别让模型在 AX 输出里数行列。** 这条是被一次真实错误逼出来的:问「Plex 界面第 2 行第 3 列是什么」,模型在 `macs ax` 的 185 行输出里把行判断对了(第一行 y=238、第二行 y=565),落到标题时却抄了 y=238 那条,答成了第一行第三列。原因是同一张海报被拆成两个元素——海报本身是一条 `430x241` 的 AXLink,它下方的标题条是另一条 `430x24` 的——于是 `x=1228` 在一份输出里出现 7 次,靠肉眼对齐 (x,y) 必然错配。这和「看着压缩图估坐标」是同一类错误:**几何推理必须留在工具里**。`macs grid` 就是为此而加。

## 6. 权限(两项,互相独立)

| 权限 | 用途 | 缺了会怎样 |
|---|---|---|
| **屏幕录制** | 截图、`CGWindowList` 拿窗口标题 | `could not create image from display` |
| **辅助功能** | AX 读写 | `AXIsProcessTrusted()` 为 false,所有调用返回 `-25211` |

macOS 26/27 上第二项在 **系统设置 → 隐私与安全性 → 设备控制和数据访问**(旧版本叫「辅助功能」)。

**加哪个条目**:加**启动 agent 的那个 App**。实测在 DSH 上,授权给 `DeepSeek Harness.app` 一个条目就够了,它的所有子进程(包括裸 CLI)直接继承,不需要给二进制单独授权。

这一步只能人工完成——TCC 数据库受 SIP 保护,`tccutil` 只能重置不能授予。macOS 也不会为没有 App 身份的进程弹窗。

## 7. 截图的去处与生命周期

截图有两类,生命周期相反,混在一起管必定出事:

| | 占比 | 去处 | 生命周期 |
|---|---|---|---|
| **过程性**——为让模型看一眼而截 | 绝大多数 | `/tmp/macs-shots/`(默认) | 看完即废 |
| **证据性**——留在回答里给人看 | 极少 | `--out` 指定 | 需要长期保留 |

**默认区自动滚动。** `macs` 在写新图之前先把默认区压到上限内,默认保留最新 40 张。这不需要任何人记得做什么——没有它,单机一年能堆出十几 GB(实测:一个下午 1.5 小时产生 14 个文件 17 MB,最大单张 5.4 MB)。

清理的边界写死在代码里:

- 只处理默认区的**直接子项**,不递归
- 只删文件名匹配 `focus-` / `shot-` / `screen-` / `region-` / `crop-` / `win` 前缀的 `.png`,别的一律不碰
- 上限由 `MACS_KEEP` 控制,设 `0` 关掉清理

**证据性截图显式落盘。** 只用 `--out` 时才写到别处。这类图**不**自动清理——它是给人看的,不该被静默回收。

查占用:

```console
$ macs shots ~/Pictures/macs
[默认区] /tmp/macs-shots
           6 个 / 15.2 MB   最老 10-03 12:55  最新 10-03 13:43
[持久区] /Users/me/Pictures/macs
           23 个 / 48.7 MB   最老 09-28 10:02  最新 10-03 11:20

默认区上限 40 张(MACS_KEEP 控制,0 = 关掉清理),只收自己生成的文件名;持久区不自动清理。
```

**第三份副本不归这里管。** `read_image` 读过的图会被 DSH 存进 `~/.dsh/attachments/`(实测已 665 个对象 / 112 MB)。同一张图因此在磁盘上可能有两份,那份的清理策略由 DSH 决定,`macs` 不碰。

## 8. 实测数据

测试环境:macOS 27.0.1,单屏 5120×2880(逻辑 2560×1440,backingScale 2),Apple Silicon。

| 操作 | 耗时 |
|---|---|
| 区域截图(`-R`) | 89 ms |
| 窗口截图(`-l`) | 0.13 s |
| 全屏截图 | ~0.2 s |
| 全屏 OCR(5120×2880) | 0.64 s,出 69 行 |

编译:`swiftc -O`,`src/macs.swift` 约 540 行,2.6 秒编完。

## 9. 设计原则

1. **坐标由像素域算,不由模型估。** 模型只说目标叫什么。
2. **能用语义操作就不用指针事件。** 按元素对象操作是精确的、不受遮挡影响、不动用户的光标;按坐标点击要处理缩放、时序、焦点,而且会移动真实鼠标。
3. **读操作自由,写操作分级。** 读错了重读一次就行,点错了可能不可逆。
4. **临时产物自己回收,证据产物交给人。** 过程性截图无人值守自动滚动,证据性截图不静默删除。
5. **文本是定位,图是交付。** 只要回答关于界面,就同时给结论和截图。图是独立信源——`grid` 第一版就把侧边栏认成了网格,文本结论不能自证;四个几乎同名的标题也只有图能说清区别。`grid --shot` 让这一步不需要额外命令。

## 10. 许可证

MIT
