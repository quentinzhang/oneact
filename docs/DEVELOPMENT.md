# OneAct 开发记录与诊断

本文保留截至 v0.39 的实现细节与历史记录。当前使用、开源协议与构建入口见 [README](../README.md)，GitHub 发布方式见 [发布指南](RELEASING.md)。下文提到的本地发布状态只描述对应历史版本。

这是一个用于验证产品可行性的原生 macOS PoC，不是可直接发布的产品版本。项目原名 QuickCanvas，自 v0.28 起更名为 OneAct（bundle id `com.oneact.poc.beta`）。

v0.39 开发记录：修复 v0.37–v0.38 的色彩转换不一致导致的成片发白／中间调抬亮。保留可选 ProRes 422、默认 H.264、FORMAT 选择记忆与录制期间锁定，以及 Lanczos、纯相机原生分辨率限制和 BT.709 标记。详细变更见 [CHANGELOG.md](../CHANGELOG.md)。该历史版本仅生成本地版本包，不更新官网发布源。

v0.28 产品更名：QuickCanvas → OneAct（独幕）——一个人、一块幕布、一次就演完。新增品牌图标：聚光灯下的录制按钮（深色圆环以负空间切出 REC 造型，光锥轮廓隐含字母 A），打包为 `AppIcon.icns` 进入 .app，主界面头部在有图标资源时显示品牌图标、开发二进制下回退为原 SF Symbol。可执行文件、Bundle ID（`com.oneact.poc.beta`）、队列名、录制文件名前缀、Application Support 目录随之更名；Bundle ID 变更后 macOS 视为新 App，首次启动需重新授予摄像头/麦克风/录屏权限；提词器脚本会自动从旧的 `Application Support/QuickCanvas/` 迁移。

v0.27 修掉提词器滚动速度被"打折"的真 bug：原实现每个 timer tick 固定累加 `速度/60`，等于假设 tick 恒为 60Hz；主线程正忙于合成 60fps 预览（外加 Vision 抠像）时 timer 会被合并到 15–30Hz，实际速度只有标称的 1/4–1/2，且越忙越慢——恰好在录制时最严重。改为按真实经过时间积分（并对超过 0.25s 的间隔做钳制），设定值即实到速度。同时滚动公式改为「整篇在 wordCount / wpm 分钟内走完」，标称值与实际一致（130 档实测 219 字/分）；上限提到 400 词当量/分（中文约 675 字/分），滑杆改用二次曲线映射，常用区间落在行程中部（50% ≈ 122、75% ≈ 238）。

v0.26 提词器语速在两种语言间统一：中文约 220 字/分、英文约 130 词/分，即约 1.7 个汉字等于 1 个英文词的发音时长，因此 CJK 字符按 1/1.7 折算成词当量，同一个滑杆位置对中英文都对应同样的说话速度。上一版按字一比一计数，单位虽然对了，但同样的 130 对英文正常、对中文却是慢速朗读。

v0.25 两层背景分别处理：预览舞台（App 界面最外层的深色底，不进录制文件）新增 Ink / Graphite / Slate / Bone 四档，鼠标移到舞台上时右侧淡入四个小圆点，移开即隐去，不占常驻界面；画布底色（会合成进录制文件）从四个固定预设改为 NSColorWell 取色器（.expanded 样式：色块 + 下拉调色板 + 系统取色面板），任意颜色，选择持久化。

v0.24 三项修正：提词器语速对中文彻底失真的 bug——原实现按空格分词，整段中文被数成一个"词"，滚动速度放大数百倍，现改为 CJK 字符逐字计数（中文语速本就按字/分钟衡量），英文仍按词；语速范围放宽到 30–300，起步加入约 2.5 秒缓起，不再瞬间全速；新增画布幕布颜色（Black / Graphite / Midnight / White），作用于 Fit 布局的留边与未选屏幕时的空画布，在 SCREEN 行以色块选择，与提词器幕布同一交互，录制中锁定。

v0.23 一批可用性修正：默认画布改为 16:9 横屏（比例选项横屏在前、竖屏在后）；原 CAMERA 长行拆成 OVERLAY（画中画样式/尺寸/位置）与 CAMERA（Zoom）两行，Zoom 行紧邻 CANVAS；录制中按钮改为红色呼吸动画、状态区显示已录时长（mm:ss）；提词器编辑时播放按钮置灰、删去与主界面开关重复的 ✕、幕布新增 Graphite / Midnight / Paper 三种预设（小色块切换，文字与控件颜色随之适配，浅色视频不再吞掉黑色幕布）。

v0.22 把提词器语速控制从「加减号 + wpm 数字」换成乌龟→兔子滑杆：语速是一种感觉，不该要求用户理解 wpm 是什么单位。内部仍按 60–220 wpm 映射滚动速度，与说话节奏对应的机制不变。

v0.21 重做提词器交互：不再是独立浮动面板 + 模态编辑弹窗，而是贴合预览舞台顶部的半透明融合浮层，随主窗口移动/缩放自动跟随。点击文字就地进入编辑（无 Save/Cancel 按钮），Esc 或点击浮层外自动保存。旧设计的模态 sheet 挂在主窗口上会被 .floating 层级的提词面板遮住，且重复点击会让 sheet 排队、点 Cancel 关掉一个又弹下一个——就地编辑从根上消除了这两个问题。镜像模式随独立面板一并移除（浮层在主窗口内，镜像无意义）。

v0.20 补上缺失的 Edit 菜单：AppKit 的 ⌘X/⌘C/⌘V/⌘Z 由主菜单分发，之前没有这个菜单，所以 App 里任何输入框都粘贴不了。同时让编辑脚本变得明显：提词条上点任意位置即可打开编辑器、首次打开且没有脚本时直接弹编辑器、录制按钮的下拉菜单里加了"Edit Teleprompter Script…"，占位文案也从"在这里粘贴"改成"点此处编辑"（面板本身是只读的）。

v0.19 新增提词器：一块悬浮在所有 App（含全屏应用）之上的脚本条，默认贴在屏幕顶端菜单栏下方——越靠近镜头，视线偏离越小。面板用 `NSWindow.sharingType = .none` 标记，不会被任何屏幕录制捕获（包括本 App 自己的录制），观众看不到稿子。滚动速度用「每分钟词数」表达而不是像素/秒，与说话节奏对应；当前行保持明亮、上下渐暗，防止丢行；支持镜像模式配合分光提词器支架。提词器打开时点录制会先走 3-2-1 倒计时，倒计时结束的同时开始录制并开始滚动。

v0.18 整理 CAMERA 行：控件按"是否会隐藏"从弱到强排列（Zoom 常驻在前，Frame 随模式，Size 与 Pip 随画中画是否可见），折叠时只从行尾消失，不再把刚点过的控件推走；新增 SIZE 滑杆调节画中画在画布上的尺寸（0.6×–1.6×，与调节人物大小的 Zoom 相互独立）；Recenter 换成图标按钮省出横向空间。

v0.17 围绕 Screen + Camera 模式补齐几件事：还没选屏幕内容时，摄像头画中画就已经显示在画布里（背景为深色空画布），可以先摆好位置；屏幕源选定后旁边出现 Stop 按钮，可随时停止分享而不退出模式；画中画新增 Hidden 样式（只录屏幕）；Cutout 抠像高度改成与 Circle 一致，三种样式里人物大小统一；预览区支持直接拖动摆放画中画，Fill 布局下拖动空白处可以平移屏幕取景。

v0.16 把软件缩放改回 1×–3×：aspect-fill 在 1× 时已经用满了传感器画面的一个方向，低于 1× 只能把画面缩小并补边，得不到更广的取景，矩形/圆形画中画还会在描边内侧露出空隙。

v0.15 把界面进一步收紧：录制模式切换移到预览舞台正上方；摄像头与麦克风选择改为录制按钮旁的下拉菜单（QuickTime 那种做法），控制面板不再有设备行；Camera 模式下与屏幕相关的整块选项全部隐藏，只剩 Camera（Zoom）和 Canvas 两行。

v0.14 在 Screen + Camera 模式下新增摄像头画中画样式：Rectangle（圆角矩形 + 白色描边）、Circle（圆形 + 白色描边）、Cutout（Vision 人物分割抠像，背景透明，人物直接叠在屏幕画面上）。v0.12 重做了主界面：原来 Inputs、Composition、Output 三张卡片合并为一张紧凑的控制面板，按 Mode / Input / Screen / Camera / Canvas 五行左侧标签对齐；操作区高度从约 600pt 降到约 180–210pt，预览舞台改为随窗口自适应放大。Camera 模式下与屏幕相关的行（Screen Layout、裁切位置、画中画位置、屏幕源选择）整行折叠而不是灰显，Fill 以外的布局也不再显示裁切位置。

## 已实现

- AVFoundation 枚举 Mac 摄像头、外接摄像头和 Continuity Camera
- 启动时立即显示摄像头和麦克风列表，不再等待授权完成后才填充
- 明确显示授权、预览启动和失败恢复状态；首次启动由用户点击 Allow Camera 再触发系统授权弹窗，并支持刷新设备及打开隐私设置
- 独立选择摄像头和麦克风；不修改 macOS 的系统默认输入设备
- 启动时先显示 Camera / Microphone 独立授权页；两项未全部允许时不会创建采集会话或进入主界面
- 录制前强制检查麦克风授权和输入设备，不再把“无音轨”的文件显示为正常成功
- 使用采集输出推荐的 AAC 参数写入音轨，并在保存后明确显示是否真的写入过音频样本
- 1.0×–3.0× App 内软件缩放与一键 Recenter；缩放采用居中裁切，同时作用于实时预览和最终录制文件，不改变系统摄像头设置
- 重新设计的原生 macOS 界面：预览舞台占据主要空间并随窗口缩放，单张紧凑控制面板、红色录制按钮和底部状态反馈
- Camera / Screen + Camera 两种录制模式；屏幕源由 ScreenCaptureKit 系统选择器授权和选择
- Screen + Camera 实时合成预览；摄像头画中画支持左上、右上、左下、右下四个位置
- 摄像头画中画采用圆角、白色描边和 App 内软件缩放
- 画中画样式可选 Rectangle / Circle / Cutout / Hidden；Circle 把摄像头居中裁成正方形再套圆形遮罩，直径取画布短边的 30%；Cutout 以同样高度的 3:4 区域作为「瞄准区」但不裁切画面，因此三种可见样式里人物的显示比例一致；Hidden 只录屏幕，同时隐藏画中画位置控件
- 画中画尺寸由 SIZE 滑杆控制（框状样式 0.6×–1.6×，基于各样式的默认尺寸缩放）；Zoom 决定画中画里看到多少摄像头画面（人物大小），SIZE 决定画中画本身在画布上占多大，两者互不影响
- Cutout 没有框可填，Zoom 与 SIZE 都只会缩放人物，因此选中 Cutout 时 CAMERA 行里的 ZOOM 一组折叠隐藏，SIZE 独自承担「人物多大」并放宽到 0.6×–3.0×；切回框状样式时该值钳回 1.6×
- CAMERA 行的 FLIP 按钮左右翻转摄像头，同时作用于预览与录制（这个 App 的预览就是成片，只翻预览会让「指着屏幕说这里」在成片里左右相反）。翻转只在 Screen + Camera 模式出现：一段纯人像翻过来只会把字变反、不解决任何问题，只有人物与屏幕内容并排时「朝哪边、站哪侧」才是真实的构图决策——同样的道理，QuickTime 的录制界面没有翻转，`Flip Horizontal` 在它的 Edit 菜单里，是录完之后对文件做的。OneAct 用不了这条退路：成片是已经烤好的合成画面，事后翻会把屏幕内容一起翻了
- 翻转实现在采集连接的 `isVideoMirrored` 上，即上游翻一次，分割遮罩、合成、录制自动一致，没有坐标要换算；虚拟摄像头等不支持连接翻转的设备回退到合成器里翻，此时人物包围盒同步做镜像。录制中锁定；切换时重置人物跟踪器，避免平滑过程把人从旧的一侧拖过去。Camera 模式下强制关闭（保留偏好），不会留下一个看不见却在生效的设置
- 画中画可在预览区直接拖动摆放，拖动后仍可点四角按钮回到吸附位置；Fill 布局下拖动画中画以外的区域可平移屏幕取景（Fit / Blur 已完整显示屏幕，无处可平移）
- Screen + Camera 模式下未选屏幕内容时，预览用深色空画布叠加摄像头画中画，先摆位置再选屏幕；选定后可用 Stop 停止分享
- Cutout 使用 Vision `VNGeneratePersonSegmentationRequest`（balanced 档，512 × 384 遮罩）逐帧抠出人物、背景透明、无描边
- Cutout 的版面由人物遮罩的包围盒决定，而不是由一个固定的框决定：摄像头画面整幅带 alpha 参与合成、横向不做任何裁切，只按「瞄准区」的高度缩放，再整体平移到人物水平居中于瞄准区、底边站在瞄准区下沿；唯一还能裁到人的只剩画布边界，且左右与头顶都会被推回画布内（下沿不推——身体从底边出画本来就是抠像该有的样子）。此前的做法是先把 16:9 的摄像头 aspect-fill 进 3:4 的框再抠像，那个框在抠像下不可见，唯一作用就是把人切掉
- 包围盒在分割队列上直接扫描遮罩得出（按行列计数取阈值，少量噪点撑不开边界），再经死区 + 指数平滑跟随，因此人物不会逐帧抖动，而是像一台反应很慢的云台；某帧拿不到遮罩时沿用上一次的位置
- 人物分割在独立队列上运行，不阻塞采集与合成；上一帧还在处理时跳过当前帧而不是排队，尚未拿到遮罩时不绘制画中画；分割失败会在状态栏提示
- Screen Layout 平铺选项：Fit 保留完整画面、Fill 填满 Canvas、Blur Background 以模糊背景消除黑边但保留完整前景
- 采集保留 ScreenCaptureKit 的 alpha，窗口圆角在画面中透明并露出其后的画布底色或模糊背景；`screenCanvas` 各布局均先压到不透明底色，避免透明像素漏出复用缓冲区
- 画布底色由 SCREEN 行的取色器（NSColorWell，色块 + 下拉调色板 + 系统取色面板）设定，作用于 Fit 布局的留边和未选屏幕源时的空画布，会合成进录制文件，选择持久化
- 预览舞台底色（App 界面外层，不进录制）提供 Ink / Graphite / Slate / Bone 四档，鼠标悬停舞台时右侧淡入小圆点选择，移开自动隐去
- Fill 模式提供 Top / Center / Bottom 平铺裁切位置，适配比 9:16 更长的 iPhone Mirroring 画面
- 录制模式切换（Camera / Screen + Camera）位于预览舞台上方；控制面板按 Source / Screen / Overlay / Camera / Canvas 五行分组，左侧标签对齐；录制中按钮呈红色呼吸动画，状态区显示已录时长
- Camera 模式下 Source、Screen 两行以及画中画位置、画中画样式整体隐藏，面板只剩 Camera 与 Canvas 两行
- 摄像头、麦克风、Refresh Devices、Privacy Settings 收进录制按钮右侧的下拉菜单，带勾选状态；录制中菜单项禁用
- Canvas Ratio 与 Resolution 独立：比例提供 16:9、4:3、1:1、9:16、4:5、3:4（默认 16:9 横屏），分辨率提供 720p、1080p、1440p；界面同时显示最终输出像素尺寸
- iPhone Mirroring 窄窗口按原始比例配置 ScreenCaptureKit 输出，不再独立放大宽度制造空白；单窗口采集同时忽略系统窗口阴影
- 将采集帧裁切/缩放到精确画布像素尺寸后，以 H.264 或 ProRes 422 `.mov` 写入（FORMAT 行选择）
- 点击录制直接开始，不弹保存面板：录像写入录像文件夹，默认 `~/Movies/OneAct`（沙盒内经 `com.apple.security.assets.movies.read-write` 访问，首次录制时创建），文件名 `OneAct-<yyyyMMdd-HHmmss>.mov`，同一秒内重名时追加 `-2`、`-3`。录制下拉菜单的 Save To 组与 File 菜单可改用其他文件夹：所选文件夹存为安全作用域书签（`com.apple.security.files.bookmarks.app-scope`），重启后重新打开；打不开时（硬盘未接、网络卷未挂载，解析时不挂载、不弹界面）本次录像回退到默认文件夹并在状态栏说明一次，所选文件夹本身保留。实现见 `RecordingsFolder.swift`
- 停止录制后，预览舞台底部出现非模态卡片（`RecordingCard.swift`）：Play 用 Quick Look 就地回看（App delegate 作为 QLPreviewPanel 控制器）；Rename 就地改名，Return 确认、Esc 取消，自动保留 `.mov`，拒绝含 `/`、`:` 或以 `.` 开头的名字，不覆盖已有文件；Show in Finder；拖动缩略图（首帧）即以复制方式把文件拖进 Finder 或其他 App；Discard & Retake 把文件移到废纸篓（可放回原处，失败时不会退而直接删除）并回到待录状态。× 或 Esc 关闭卡片、开始下一段录制都保留文件；卡片持有所在文件夹的访问权，录制后换文件夹也不影响这张卡片的操作。录制结束不再自动打开 Finder
- `--device-report` 输出设备与系统效果支持状态
- `--self-test <path> [--prores]` 生成并验证 1080 × 1920 的合成视频写入链路，包含三种画中画样式（含抠像遮罩缩放）、缩放钳制与透明源圆角压底的像素校验；抠像另有一组专门的校验：用手工填的单通道遮罩摆一个偏右且比瞄准区更宽的人，断言包围盒提取的数值（含行方向翻转）、人物被居中到瞄准区、左右两边都完整落在画布内、周围仍是屏幕画面；再把画面与包围盒一起镜像，断言人物落在同一个矩形里——因为版面锚在人身上，两个翻转同步时位置不变，不同步则会差出半幅画面
- 标准 Edit 菜单（Undo/Redo/Cut/Copy/Paste/Select All），⌘V 等快捷键在脚本编辑器、卡片改名框和系统文件夹选择面板里均可用
- 脚本就地编辑：点击浮层文字直接进入编辑态（边框变高亮色提示），Esc 或点击浮层外自动保存，无模态弹窗；首次打开且无已存脚本时自动进入编辑态；录制下拉菜单保留 Edit Teleprompter Script… 入口；录制中脚本锁定
- 启动时若已有同 bundle id 的实例在运行，激活该实例并退出自己，避免两个副本共用同一份偏好与提词稿互相覆盖
- 提词稿仅在用户实际写入时落盘；占位说明文字与离屏诊断都不会写入 Application Support
- 提词器为预览舞台顶部的融合浮层：实现为主窗口的无边框子窗口（贴合顶部、随移动/缩放同步），因此可携带 `sharingType = .none`——脚本不会出现在任何屏幕录制里（本 App 自己的合成录制、第三方会议共享均不可见）；字号 22–60pt、语速为乌龟→兔子滑杆（60–700 词当量/分，以自然语速为中点的两段线性映射；CJK 按 1.7 字 = 1 词当量折算，中英文同一档位语速一致；按真实经过时间积分，不受主线程负载影响），开始滚动有约 2.5 秒缓起、列宽上限 620pt、文字上下渐隐；幕布提供 Graphite / Midnight / Paper 三种预设，文字与控件颜色随幕布适配；脚本存在 Application Support/OneAct/script.txt
- 提词器打开时录制前插入 3-2-1 倒计时（预览区居中显示），倒计时结束后开始录制并同步开始滚动；停止录制时停止滚动
- `--layout-report <path.png> [--screen-mode] [--min-size] [--prompter] [--cutout]` 离屏渲染主界面并输出 PNG，无需摄像头/麦克风授权即可检查布局，并打印录制菜单内容与 `OVERLAY_DECK`（当前画中画样式、ZOOM 与 FLIP 是否折叠、SIZE 区间）；带 `--prompter` 时另外渲染提词浮层、打印其 sharingType / 子窗口关系，并走一遍就地编辑的 begin/commit 状态循环；`--cutout` 与 `--screen-mode` 同用可检查抠像下折叠掉 Zoom 行后的版面；`--saved-card [--renaming]` 渲染录制后的卡片（示例文件不存在，不触碰磁盘），打印 `SAVED_CARD`（位置是否在舞台内、布局是否有歧义、各按钮是否被压缩）
- `--save-flow-check` 无摄像头、无点击地走一遍录像落盘路径：默认文件夹创建与 AVAssetWriter 写入、同秒重名、首帧回读、书签选择后模拟重启重新打开、改名与非法名、移到废纸篓。需在已签名的 App 内运行（`build/OneAct.app/Contents/MacOS/OneAct --save-flow-check`）才带有沙盒与权限；书签写入独立的偏好域，不改动用户的文件夹选择。会在废纸篓留下一个 `OneAct save-flow check.mov`
- Camera 行显示当前实际生效的 macOS 视频效果，点击可打开系统效果面板。纯相机输出按实际输入、比例裁切和软件缩放限制尺寸，发生限制时显示 `camera limit`，悬停可查看输入/输出尺寸；分辨率选项是期望上限。录制开始后文件尺寸保持固定，屏幕合成模式不受相机分辨率限制。系统效果在 OneAct 收到画面之前处理，应用不能从已虚化的帧中恢复原始细节。
- `Camera → Capture Quality Check (8 seconds)` 在当前 Camera 会话中录制本地诊断片段，于约 2、4、6 秒保存配对的摄像头输入 PNG、编码前 PNG，以及包含真实帧尺寸、系统效果状态、写入器时间戳的 `frames.json`。保存在应用支持目录的 `OneAct/Diagnostics`；普通录制不保存诊断帧。输入 PNG 是 AVFoundation 交付的未编码帧，仍可能包含系统效果，并非传感器 RAW。
- `--camera-diagnostic <directory> [--legacy-camera] [--portrait] [--zoom <1…3>] [--prores]` 用同一 Recorder 做无界面诊断；prores 选项验证 ProRes 422 写入；legacy 选项仅用于比较默认格式策略，portrait 请求 1440×2560 画布以实测竖屏采集和输出限制，zoom 用于检验缩放后的输出上限。命令行直接启动和正常窗口启动可能获得不同的系统效果状态，因此对用户所见效果的排查应优先使用窗口内菜单。
- 自测的成片校验改用 `loadTracks(withMediaType:)` 异步加载：原来的同步 `tracks(withMediaType:)` 每跑几次就会死锁挂住

## 构建

```bash
swift build -c release
```

要以 App 形式运行，需要将 release 二进制放入 `.app/Contents/MacOS/`，将 `AppIcon.icns` 放入 `.app/Contents/Resources/`，并使用 `Entitlements.plist` 签名。图标源文件在 `Design/oneact-icon-b-spotlight.svg`（品牌备选幕布版为 `oneact-icon-a-curtain.svg`）。首次启动时，在系统设置中允许 Camera 和 Microphone；首次选择屏幕内容时按 macOS 提示授权。Continuity Camera 还需要 iPhone 与 Mac 满足 Apple 的连续互通条件。

## 验证

```bash
.build/arm64-apple-macosx/release/OneAct --device-report
.build/arm64-apple-macosx/release/OneAct --self-test /tmp/oneact-self-test.mov
build/OneAct.app/Contents/MacOS/OneAct --save-flow-check
.build/arm64-apple-macosx/release/OneAct --layout-report /tmp/oneact-layout.png --screen-mode
```

真实录制验收时：选择 Camera 或 Screen + Camera 模式，分别选择 Canvas Ratio 与 Resolution，按需设置 Screen Layout、Camera Zoom、画中画位置和画中画样式，录制后用 `ffprobe` 或 QuickTime 检查文件尺寸、所选 H.264／ProRes 视频轨、BT.709 标记和 AAC 麦克风音轨。

摄像头格式改动还需在硬件上分别跑 `--camera-diagnostic <目录>` 和 `--camera-diagnostic <另一目录> --portrait`，核对 `frames.json` 的 `source_width/height` 与 `active_format_width/height`，不能只看选中格式的返回值。v0.36 实测曾发现配置提交后将竖屏格式重置回横屏；修复后应在支持该格式的相机上交付 1080×1920 竖屏帧。v0.37 中，对应纯相机成片也应限制为 1080×1920。随后在窗口中切换横竖比例，核对实际输入和输出尺寸；用 `ffprobe` 确认成片的 color_primaries、color_transfer、color_space 均为 bt709。

当前 Screen + Camera 模式录制屏幕画面、摄像头画中画和所选麦克风；System Audio 选项通过音频进程采集混入电脑声音，麦克风可选择 None。系统 Video Effects 可从 OneAct 的效果按钮或菜单栏绿色摄像头面板调整，AVFoundation 收到的摄像头帧会直接进入画中画合成。

## 录制格式

FORMAT 行提供 H.264 与 ProRes 422；首次使用和无效历史偏好均回到 H.264，选择后会保存。Camera 与 Screen + Camera 共用该选择。同一个文件开始录制后，格式在暂停期间也不能改变。

- H.264：原有 High Profile 与按像素吞吐量分配的码率，文件较小，适合日常录制和分享。
- ProRes 422：逐帧高质量编码，适合保留纹理和后期剪辑，文件明显更大。选择 Standard 422，与本机 QuickTime 最高质量实测的档位一致，不额外套用 H.264 的码率和 profile 参数。

两种模式均输出 `.mov` 与 AAC 音频，并沿用 SDR BT.709 的渲染和标记。ProRes 成片使用 10-bit 4:2:2 编码，但当前合成像素缓冲区仍为 8-bit BGRA；这不是 HDR／RAW 采集，也不会增加摄像头原始细节。

ProRes 验证可运行：

```bash
.build/arm64-apple-macosx/release/OneAct --self-test /tmp/oneact-prores.mov --prores
.build/arm64-apple-macosx/release/OneAct --camera-diagnostic /tmp/oneact-prores-camera --prores
```

色彩验收还需进行渲染 → 编码 → 解码 → sRGB 的完整往返检查。只检查 BT.709 文件标签，或源图与编码前图相同，不能证明最终播放颜色正确。当前输出色彩空间由 BT.709 Core Video 附件生成，以保持渲染与视频解码一致；自测包含灰阶、肤色和饱和彩色块的往返误差断言。
