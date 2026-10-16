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
- 提词器「跟随语音」：本机语音识别追踪朗读位置，滚动跟着说话走，停顿即停、临场发挥原地等待；详见下文「提词器跟随语音」
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

## 上镜（Touch-up，未发布）

OneAct 没有剪辑环节，画面上的样子必须在录制时就处理好。上镜只做三件事：补光、暖色、磨皮；不改脸型，满档也保持自然。设置在 CAMERA 行的 Touch-up 弹出面板中，存于 UserDefaults 的 `touchUp.enabled/light/warmth/smooth`；Reset 回到默认值（补光 35、暖色 +20、磨皮 40），不改变开关。

- 代码：`TouchUp.swift`（设置、滤镜、`TouchUpStage`）、`FaceRegionTracker.swift`（人脸检测与平滑）、`TouchUpPanel.swift`（按钮与面板）、`TouchUpSelfTest.swift`、`TouchUpBenchmark.swift`。`main.swift` 只在相机帧进入合成前调用 `touchUp.apply(to:)`（`composedCameraLayer` 与 `makeCanvasBuffer`），并在采集回调里把相机帧交给人脸检测。
- 作用范围：只处理摄像头图像，在抠像遮罩和合成器翻转之前，因此 alpha 和人脸坐标都不受影响；屏幕画面从不经过这些滤镜。
- 滤镜：三个运行时编译的 Metal Core Image 内核（`CIKernel.kernels(withMetalString:)`，约 0.5 秒，启动时在后台预编译）。暖色是线性光下的通道增益（满档 R ×1.065、B ×0.89）；补光是 sRGB 编码值上的 `p + lift·p(1−p)²`，峰值在 1/3 处约 +0.08，黑白两端为零且单调，不会新增溢出。磨皮是单遍自引导滤波：在面部椭圆的外接矩形内求局部均值与方差（半径约为脸宽的 2.5%），方差相对阈值小的地方（肤质、噪点、瑕疵）向均值靠拢，大的地方（眼、眉、唇、发丝）保持原样；再乘以羽化的面部椭圆、基于局部均值的 CbCr 肤色范围、滑杆强度（平方根曲线，满档上限 0.7）和人脸存在度。遮罩为零的像素直接返回原始采样，面部以外逐字节不变。
- 人脸检测：`VNDetectFaceRectanglesRequest`，在独立队列上处理长边 640 的缩小副本，最多每秒 15 次，上一帧未完成时跳过；取最大的人脸。人脸框和抠像的人物框一样经过死区与指数平滑，但跟随更快（缓动 0.45、死区 0.004）；连续 4 次检测不到后存在度逐步降到零并丢弃人脸框，因此「没有人脸就不磨皮」，也不会逐帧闪烁。翻转与更换摄像头时重置。
- 关闭等价于原路径：开关关闭或三个滑杆都为零时 `apply` 原样返回同一个 `CIImage`；纯相机模式继续使用 `AVCaptureVideoPreviewLayer`。开启时纯相机模式每帧合成一次，既作为预览（收到第一帧合成画面后才切换图层），录制时也直接写入同一帧，不重复渲染。

性能（`--touch-up-bench`，Apple M3 Max，合成帧 + 等待 GPU 完成，每帧毫秒，滑杆全部满档；屏幕源为 3456×2234，抠像使用 Blur 布局）：

| 场景 | 相机输入 | 画布 | 关闭 | 开启 | 增加 |
| --- | --- | --- | --- | --- | --- |
| Camera | 1920×1080 | 1920×1080 | 0.54 | 1.28 | +0.74 |
| Camera | 3840×2160 | 2560×1440 | 0.79 | 2.32 | +1.53 |
| Screen + Camera（Cutout） | 1920×1080 | 1920×1080 | 1.26 | 2.20 | +0.94 |
| Screen + Camera（Cutout） | 1920×1080 | 2560×1440 | 1.74 | 2.75 | +1.01 |
| Screen + Camera（Cutout） | 3840×2160 | 2560×1440 | 2.38 | 4.66 | +2.28 |

人脸检测在独立队列上每次约 5.4–6.0 ms（1080p／4K 输入）。在 1440p Cutout 下以 30 fps 持续 8 秒，同时运行人物分割和人脸检测：开启前后均为 30.1 fps，0 帧超时（开启时 p95 4.9 ms）。纯相机模式未开启上镜时预览不经过合成，开启后空闲预览也需要支付上表「开启」一列的成本。

验证：

```bash
.build/arm64-apple-macosx/release/OneAct --self-test /tmp/oneact-self-test.mov
.build/arm64-apple-macosx/release/OneAct --self-test /tmp/oneact-prores.mov --prores
.build/arm64-apple-macosx/release/OneAct --layout-report /tmp/oneact-layout.png --touch-up
.build/arm64-apple-macosx/release/OneAct --touch-up-bench
.build/arm64-apple-macosx/release/OneAct --touch-up-still <照片> /tmp/oneact-touchup.png [--max]
```

`--self-test` 的 `touch_up=[…]` 段覆盖：关闭或滑杆为零时与原路径逐字节一致；合成噪点人脸在给定人脸框下面部噪点下降（默认约 −32%，满档约 −60%）、椭圆外像素零变化、虹膜与眉毛对比度保持 ≥92%；暖色使灰色 R 升 B 降（冷色相反）且幅度在几个色阶内；补光抬亮阴影、高光几乎不动、单调且不新增溢出；矩形画中画与抠像下摄像头范围以外的屏幕像素不变；人脸框死区、缓动与渐隐；设置持久化。`--layout-report --touch-up` 另外写出 `.touchup.png` 面板截图，并打印 `TOUCH_UP` 行（按钮与面板控件在录制中锁定、暂停时可用）。`--touch-up-still` 对一张照片做人脸检测并输出前后对比图，用于在没有摄像头时检查真实人脸上的效果。

仍需真实摄像头确认：真实皮肤与不同肤色、光线下的磨皮观感和肤色遮罩覆盖；侧脸、低头、戴眼镜、多人入镜时的检测与跟随；快速转头时遮罩是否明显滞后；纯相机模式开关上镜时预览图层切换是否无闪烁；较低端 Apple Silicon 机型上的实际帧率。

## 提词器跟随语音

提词器控制栏的波形按钮开启「跟随语音」（Follow voice，默认关闭，选择会记住）。开启后语速滑杆换成状态，滚动不再按设定语速积分，而是跟着你读到的位置走。

- 识别：`OnDeviceTranscriber.swift` 封装 Speech 框架，始终 `requiresOnDeviceRecognition = true`；没有本机模型的语言直接报告「未安装」，不会回退到服务器。语言就是稿件的语言（汉字按 1.7 字折合一个词，与语速换算一致；汉字多则 zh-CN，否则 en-US），没有语言选项：照稿朗读时稿件语言就是说话的语言，中文稿里夹的英文名词由中文模型一并识别；手动指定也帮不了中英段落交替的稿子，因为一次只能跑一种语言。状态的悬停提示写明正在听的语言。稿件中的专有名词和长词（`NLTokenizer` 分词，最多 100 条）作为 `contextualStrings` 传入。识别任务在约 45 秒音频后于停顿处轮换、58 秒强制轮换；识别器自行结束任务时自动接续，15 秒内连续失败 5 次才停止并提示。接口刻意很小（按语言启动、送入音频样本、收到带时间戳的临时／最终结果、停止），与对齐逻辑分开。
- 音频：不另开采集会话。预览运行期间 `Recorder` 的麦克风输出一直有样本（不只是录制时），新增的 `setMicrophoneSampleHandler` 把每个样本同时交给跟随语音；只有提词器在滚动时才真正送进识别器。样本统一转为 16 kHz 单声道 float，多声道先混音：单声道麦克风常以立体声的一侧出现，只取第一声道会变成静音。
- 权限与沙盒：只在用户打开开关时请求「语音识别」权限，Info.plist 新增 `NSSpeechRecognitionUsageDescription`。沙盒不需要额外 entitlement：签名后的沙盒包内可以创建识别器，本机中英文都支持本地识别（`--speech-report` 实测）；麦克风沿用已有的 `device.audio-input`。权限被拒、未选麦克风、预览未运行或没有本机模型时，状态显示 Unavailable，主窗口状态栏写明原因，稿子改按设定语速滚动，不会停在原地不动。
- 对齐（`ScriptAligner.swift`，纯 Swift，可离线测试）：稿件与转写用同一套归一化——大小写、全半角、去变音符号和撇号、去标点；中文逐字、英文逐词，并记下每个词在原文中的 UTF-16 位置，用于滚动和淡化。维护「已读到第几个词」这一个位置；每次结果到来，取转写最近的 12 个英文词／18 个汉字，与「当前位置前方三句（30–130 词／60–240 字）、后方 20 词／32 字」的窗口做 Smith–Waterman 局部对齐：相同计满分，同音字（无声调拼音）0.8，平翘舌／前后鼻音 0.6，英文近似拼写与词形 0.6–0.7。只采纳结尾落在最新几个词上的匹配。移动规则：从当前位置连续读下去只需 3 词／4 字的证据；从前方起头的匹配（跳读）只计前方的新匹配，越远要求越高，最多 5 词／7 字且须密集；回退必须远于修订容差、有跳读级别的证据，并在下一次结果中再次出现（识别器撤回最后几个词时，单看一次和重读一模一样）；其余情况原地不动。每次都重新对齐整段尾部，识别器修改临时结果只是替换，不需要撤销。重复短句：越远的匹配扣分越多，前文语境也只能支持近的那一处，所以不会跳到后一处。
- 滚动：`PrompterFollowScroller` 用临界阻尼弹簧把「下一个要说的字」送到阅读线（可视高度 42% 处，下方多留待读内容），并在行内按字插值，所以是逐词平滑滑动而不是逐行跳；弹簧不越过目标，停止说话就停住。已读部分用 TextKit 2 的渲染属性淡化，不改动文本和排版。手动拖动或滚动稿子后，从阅读线上那一行重新开始跟随。暂停录制即停止聆听，继续录制从原位置接着跟随；倒计时、录制期间锁定编辑、`sharingType = .none` 的子窗口均保持不变。
- 验证：`OneAct --aligner-test` 离线运行中英文各 8 个场景 × 3 个随机种子（照读、插话、跳过一句、重复短句、同音字替换与漏字、临时结果修改与撤回、念窗口外的句子、重读一句），断言位置单调前进（容差 2 词／3 字）、句末落后不超过 3 词／4 字、插话期间不漂移、不跳到重复短句的后一处、不越出窗口、最终到达稿尾；另外检查三种麦克风格式的转换（时长、电平、混音）。`ALIGNER_SEEDS=150` 可扫更多种子，`ALIGNER_DEBUG=1` 打印每次对齐。`--layout-report <png> --prompter` 额外输出 `*.prompter-follow.png` 与 `PROMPTER_FOLLOW*` 行，其中包括一段无音频的朗读模拟（滚动不回退、停下后静止、拖动后重新定位）。`open -W --stdout /dev/stdout build/OneAct.app --args --speech-report` 报告权限和本机识别可用性；`--voice-follow-probe [--request-permission]` 用系统合成语音朗读测试稿，经同一条样本缓冲路径送进真实识别器并报告对齐终点，需要语音识别权限。
- 仍需真机验证：真实麦克风下的识别延迟与准确率、权限弹窗流程、数分钟以上录制中的任务轮换、嘈杂环境与口音下的跟随表现。

## 空格暂停

录制期间按空格暂停／继续（`SpacePause.swift`），与全局快捷键 ⌥⌘P 走同一个 `togglePause`。

- 范围：只在一段录制进行中（含已暂停）、事件来自主窗口或其子窗口（提词器）时处理；其他 App 在前台时空格属于那个 App，⌥⌘P 才是到处可用的那个。可编辑的文本视图是第一响应者时（录制外改稿、改名）照常输入；带修饰键的空格放行。
- 拦截位置：`NSEvent.addLocalMonitorForEvents` 在窗口分发之前拿到按键，因此恰好有键盘焦点的按钮（尤其是会停止录制的录制按钮）不会被空格「按下」。按住产生的自动重复只吞掉、不切换。空格永远不会开始或停止录制。
- 暂停提示：`PausedBadge` 居中压在预览上，「Paused · Not recording · Space or ⌥⌘P to resume」，不接收点击、不进入成片。说话人看着镜头时，小小的暂停图标容易漏看，暂停期间说的话又不会被录下。
- 验证：`--layout-report --recording [--paused]` 打印 `PAUSED_BADGE`（是否显示、是否在舞台内、布局是否有歧义）和 `SPACE_PAUSE`（主窗口空格切换、按住吞掉、⌘空格／其他键／其他窗口／未录制／正在输入均放行）。真实按键与焦点行为仍需在 App 中手动确认。
