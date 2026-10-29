# Tidest

[English](README.md) · **简体中文**

macOS 菜单栏工具，用于切换窗口、快速排列窗口，以及把常用窗口放在屏幕一侧。

同一个应用的多个窗口可以分别选择，包括 Finder 打开的不同文件夹窗口。

发布流程会在 GitHub Actions 中构建安装包，完成 Developer ID 签名、Apple 公证和构建来源证明，再通过不可变发布分发。首次配置与下载文件验证方法见[发布与验证](docs/RELEASING.md)。

## 功能

- **窗口切换**：用横向预览或可滚动的平铺列表浏览窗口，支持键盘、触控板和鼠标。
- **快速布局**：把鼠标下的窗口放到半屏、四分之一屏，或铺满可用屏幕区域。
- **窗口停靠**：把常用窗口放在屏幕左侧或右侧，调整顺序，并选择哪些窗口关闭后仍可重新打开。
- **自定义**：三个功能的快捷键均可修改，界面支持英文、简体中文、繁体中文、日文和韩文。

## 开始使用

打开 Tidest，按引导开启权限。辅助功能权限用于切换和排列窗口；屏幕录制权限用于显示预览，可以按需开启。

| 功能 | 默认快捷键 |
| --- | --- |
| 窗口切换 | Option + Tab |
| 快速布局 | Option + Q |
| 拾取窗口 | Option + W |

在 **设置 → 窗口** 中修改快捷键。点击当前组合，按住 Control、Option 或 Command，再按另一个键；可同时加入 Shift。按 Esc 取消录入。快捷键冲突时保留原组合，菜单栏显示实际快捷键。

### 窗口切换

1. 按住 **Option**，再按 **Tab** 打开窗口面板。
2. 保持 Option 按住，每按一次 Tab 选择下一个；两个键一直按住时，每隔约一秒选择下一个。
3. 松开 Option 切换到选中窗口。

点击窗口预览可以直接切换。按 Esc 或点击面板外取消。

**横向预览**：在触控板或 Magic Mouse 上左扫选择下一个，右扫选择上一个。普通鼠标滚轮向下选择下一个，向上选择上一个。

**平铺预览**：鼠标移到截图上即可选中，上下滚动查看更多窗口；键盘选中屏外窗口时会自动滚入视野。

窗口按当前桌面上的前后顺序排列，选择最小化窗口时会先恢复。预览保留窗口自身比例，刷新后保留已选窗口和滚动位置。

### 快速布局

按 **Option + Q**，把鼠标移到要排列的窗口露出的部分。点击布局图或按对应数字：

| 1 · 左上角 | 2 · 上半屏 | 3 · 右上角 |
| --- | --- | --- |
| 4 · 左半屏 | 5 · 铺满屏幕 | 6 · 右半屏 |
| 7 · 左下角 | 8 · 下半屏 | 9 · 右下角 |

四角各占四分之一。布局使用鼠标所在屏幕的可用区域，保留菜单栏和 macOS Dock。

松开 Option 后面板仍保留。按 Esc 或点击面板外取消。

### 窗口停靠

窗口停靠默认开启，停靠栏初始位于屏幕右侧。

1. 按 **Option + W** 开始拾取窗口。
2. 点击高亮窗口，拿起它的预览；原窗口留在原位。
3. 将预览移到停靠栏，再点击一次放下。
4. 点击停靠项目，把对应窗口带到最前面。

按 Esc 或再次按 Option + W 取消拾取。鼠标移到任意屏幕的停靠侧边缘时展开，移开后收起。多屏共用同一个列表；鼠标移到另一块屏幕的同侧边缘，停靠栏就会移过去，无需等待原来的停靠栏收起。

- **选择左右位置**：使用顶部换边按钮，或把顶部向屏幕内侧拖动一小段距离。
- **选择显示方式**：使用顶部控件，切换缩略图或“图标＋标题”。
- **调整顺序**：在栏内拖动项目。
- **移除项目**：拖出后松开，或右键选择 **从停靠栏移除**，原窗口仍然打开。
- **关闭后保留**：点击项目的 **保留** 图钉；窗口关闭后，点击项目即可重新打开。

所有停靠项目、顺序和左右位置都会在 Tidest 重启后恢复。未开启保留的项目随原窗口关闭而移除。停靠动画遵循 macOS 的 **减少动态效果** 设置。

| 应用 | 保留后重新打开的内容 |
| --- | --- |
| Finder | 新建窗口，打开保存的文件夹或“最近使用”位置 |
| macOS 终端 | 新建窗口，进入选中标签页保存的本地目录 |
| Chrome / Safari | 新建窗口，恢复保存的标签网址、顺序和选中标签 |
| 其他应用 | 打开应用本身 |

窗口仍在运行时，保存的文件夹、目录和标签页会跟随变化；重新打开使用最后成功保存的位置。

## 设置与权限

菜单栏的 **使用说明** 提供窗口切换、快速布局和窗口停靠的动态示意，快捷键跟随当前设置。可以暂停、重播、拖动进度条或点击步骤单独查看。拖动后停在所选位置，点击“继续播放”接着看。开启 macOS 的 **减少动态效果** 后，仍可拖动进度或点击步骤查看静态示意；查看说明不需要开启权限。

**设置 → 窗口** 包含预览方式、快捷键和窗口停靠开关；**设置 → 通用** 包含语言与权限。未手动选择语言时跟随系统语言，修改后立即生效。

菜单栏中，**使用说明** 下方的 **使用统计** 可查看今日次数、累计次数和最近 7 天的柱状图，移到图上会突出对应日期并显示次数。右下角的说明按钮可查看计数规则：成功切换窗口、完成快速布局、添加窗口到停靠栏、从停靠栏打开窗口，各计一次；取消、失败和仅打开面板不计。次数从支持统计的版本首次启动时开始累计，无法补回此前的使用记录。

| 权限 | 用途 |
| --- | --- |
| 辅助功能 · 必需 | 切换、移动和调整窗口大小 |
| 屏幕录制 · 可选 | 在窗口切换和停靠栏中显示截图 |
| 自动化 · 按应用授权 | 保存和重新打开保留窗口的文件夹、终端目录或浏览器标签页 |

未开启屏幕录制时显示应用图标和窗口标题，窗口切换与快速布局仍可使用。点击 **暂不开启** 可以继续，勾选 **下次不再提醒** 后不再重复提示。

Tidest 在启动或重新打开时检查权限，可以点击通用页的 **前往系统设置** 管理。读取或控制支持的应用时，macOS 会另行询问自动化授权。

## 本地数据与隐私

打开 **关于 Tidest** 时，应用会自动请求 `https://tidest.app/api/update` 检查更新。有新版本时，显示版本号并询问是否下载；只有点击“下载”后，才会在默认浏览器中打开安装包下载链接，下载完成后自行安装。也可以点击“检查更新”重新检查。查看“关于”和检查更新均不需要辅助功能权限。检查更新不会发送设置或窗口记录。

Tidest 将设置、窗口记录和使用次数保存在这台 Mac 上，没有统计上传服务。

- **窗口切换预览**：只缓存在内存，退出 Tidest 后清除。
- **停靠窗口**：保存应用、窗口标题、身份、尺寸、顺序和最后一张预览，供重启后恢复。
- **已保留窗口**：支持时额外保存 Finder 文件夹、终端目录或浏览器标签网址。
- **设置与窗口记录**：使用 macOS 的 `UserDefaults`，即系统提供的本地设置存储。
- **使用次数**：仅保存每天的次数和统计开始日期，不保存操作明细，不上传。
- **停靠预览**：以 PNG 保存到 `~/Library/Application Support/com.mixbayes.tidest/PinnedPreviews/`，移除项目时删除对应图片。

保存的预览可能包含窗口中的内容，浏览器网址也可能包含查询参数。分享截图、设置或诊断资料时，请留意这些内容。

## 从源码构建

当前工程要求 **macOS 14.0 或更高版本**，以 `tidest.xcodeproj` 中的配置为准，并需要支持工程所用 macOS 接口的 Xcode。无需安装第三方依赖包。

用 Xcode 打开 `tidest.xcodeproj`，选择 `tidest` scheme；需要签名时选择自己的开发者团队，然后运行。

也可以使用临时签名构建本地开发版本：

```sh
xcodebuild -project tidest.xcodeproj -scheme tidest -configuration Debug \
  -derivedDataPath /tmp/tidest-build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

应用位于 `/tmp/tidest-build/Build/Products/Debug/tidest.app`。

工程使用 SwiftUI 和 AppKit，通过辅助功能接口控制窗口，通过 ScreenCaptureKit 获取预览。为支持操作其他应用的窗口，关闭了 App Sandbox（应用沙盒），仍启用 Hardened Runtime（运行时保护）。正式分发需要 Developer ID 签名和公证。

### 测试与界面预览

运行测试：

```sh
xcodebuild -project tidest.xcodeproj -scheme tidest -configuration Debug \
  -derivedDataPath /tmp/tidest-build -destination 'platform=macOS' \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= test
```

测试包含窗口选择、滚动、快捷键、设置与权限、停靠保存与重开、预览存储和窗口布局。

Debug 构建提供开发用界面预览参数。预览使用示例窗口和独立设置，不申请权限，也不改变真实窗口。

| 预览 | 参数 |
| --- | --- |
| 权限引导 | `--ui-preview-accessibility` 或 `--ui-preview-screen` |
| 设置／关于 | `--ui-preview-settings` 或 `--ui-preview-about` |
| 使用说明 | `--ui-preview-usage`，可附加 `--ui-preview-usage-static` 查看静态步骤 |
| 更新状态 | `--ui-preview-about --ui-preview-update=<state>`，state 可选 `checking`、`up-to-date`、`available`、`failed` 或 `download-failed`；使用示例响应，不会打开浏览器 |
| 窗口切换 | `--ui-preview-switcher`，可附加 `--ui-preview-tiled`、`--ui-preview-count=150`、`--ui-preview-thumbnails` 或 `--ui-preview-refresh` |
| 快速布局 | `--ui-preview-layout`，可附加 `--ui-preview-layout-constrained` |
| 窗口停靠 | `--ui-preview-pinned`，可附加 `--ui-preview-count=20` |
| 预览语言 | `--ui-preview-language=<code>`，code 可选 `en`、`zh-Hans`、`zh-Hant`、`ja` 或 `ko` |
| 设置预览中的已开启权限 | `--ui-preview-granted-accessibility` 和 `--ui-preview-granted-screen` |

## 许可证

除另有说明外，本仓库中的源代码、文档和资源采用 **Apache License 2.0**。完整条款见 [LICENSE](LICENSE)，版权和授权声明见 [NOTICE](NOTICE)。
